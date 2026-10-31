import 'package:sqflite/sqflite.dart';

import 'sync_provider_adapter.dart';
import 'sync_revision.dart';
import 'sync_object_cache.dart';

/// Durable replica bookkeeping. [scope] binds an account and encryption-library
/// generation. Environment separation is provided by the existing database.
/// No plaintext note bodies or credentials belong in these tables.
class SyncReplicaStore {
  const SyncReplicaStore(this.database, {required this.scope});

  final Database database;
  final String scope;

  static Future<void> createTables(DatabaseExecutor db) async {
    await SyncObjectCache.createTable(db);
    await db.execute('''CREATE TABLE IF NOT EXISTS replica_signal_outbox (
      scope TEXT NOT NULL, connection_id TEXT NOT NULL, token TEXT NOT NULL,
      PRIMARY KEY(scope, connection_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS replica_entities (
      scope TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      revision_id TEXT NOT NULL, revision TEXT NOT NULL,
      PRIMARY KEY(scope, kind, entity_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS replica_acknowledgements (
      scope TEXT NOT NULL, connection_id TEXT NOT NULL, kind TEXT NOT NULL,
      entity_id TEXT NOT NULL, revision_id TEXT NOT NULL, revision TEXT NOT NULL,
      PRIMARY KEY(scope, connection_id, kind, entity_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS replica_inbox (
      scope TEXT NOT NULL, connection_id TEXT NOT NULL, kind TEXT NOT NULL,
      entity_id TEXT NOT NULL, revision_id TEXT NOT NULL, revision TEXT NOT NULL,
      PRIMARY KEY(scope, connection_id, kind, entity_id, revision_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS replica_cursors (
      scope TEXT NOT NULL, connection_id TEXT NOT NULL, cursor TEXT,
      PRIMARY KEY(scope, connection_id))''');
  }

  /// Queued atomically with an acknowledgement after a remote commit. A crash
  /// or temporary Firebase failure cannot lose the notification obligation.
  Future<void> queueSignal(
    Transaction txn,
    String connectionId,
    String token,
  ) => txn
      .insert('replica_signal_outbox', {
        'scope': scope,
        'connection_id': connectionId,
        'token': token,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<String?> pendingSignal(String connectionId) async {
    final rows = await database.query(
      'replica_signal_outbox',
      where: 'scope = ? AND connection_id = ?',
      whereArgs: [scope, connectionId],
    );
    return rows.isEmpty ? null : rows.single['token'] as String;
  }

  Future<void> acknowledgeSignal(String connectionId, String token) async {
    await database.delete(
      'replica_signal_outbox',
      where: 'scope = ? AND connection_id = ? AND token = ?',
      whereArgs: [scope, connectionId, token],
    );
  }

  Future<SyncRevision?> current(
    DatabaseExecutor db,
    SyncEntityKind kind,
    String entityId,
  ) async {
    final rows = await db.query(
      'replica_entities',
      where: 'scope = ? AND kind = ? AND entity_id = ?',
      whereArgs: [scope, kind.name, entityId],
    );
    return rows.isEmpty
        ? null
        : SyncRevision.decode(rows.single['revision'] as String);
  }

  /// Call within the same transaction that changes the domain model.
  /// Remote application must compare here before modifying domain content.
  Future<bool> accept(Transaction txn, SyncRevision incoming) async {
    final existing = await current(txn, incoming.kind, incoming.entityId);
    if (existing != null) {
      _checkIdentity(existing, incoming);
      if (incoming.compareTo(existing) <= 0) return false;
    }
    await txn.insert('replica_entities', {
      'scope': scope,
      'kind': incoming.kind.name,
      'entity_id': incoming.entityId,
      'revision_id': incoming.revisionId,
      'revision': incoming.encode(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  Future<List<SyncRevision>> pending(
    String connectionId, {
    int limit = 100,
    (String, String)? after,
  }) async {
    final rows = await database.rawQuery(
      '''
      SELECT e.revision FROM replica_entities e
      LEFT JOIN replica_acknowledgements a ON a.scope = e.scope
        AND a.kind = e.kind AND a.entity_id = e.entity_id
        AND a.connection_id = ?
      WHERE e.scope = ? AND (a.revision_id IS NULL OR a.revision_id != e.revision_id)
      AND (? IS NULL OR e.kind > ? OR (e.kind = ? AND e.entity_id > ?))
      ORDER BY e.kind, e.entity_id LIMIT ?
    ''',
      [connectionId, scope, after?.$1, after?.$1, after?.$1, after?.$2, limit],
    );
    return rows
        .map((row) => SyncRevision.decode(row['revision'] as String))
        .toList();
  }

  /// Acknowledge the captured revision, never whatever is current after upload.
  /// An older in-flight upload cannot replace a newer acknowledgement.
  Future<void> acknowledge(
    Transaction txn,
    String connectionId,
    SyncRevision revision,
  ) async {
    final rows = await txn.query(
      'replica_acknowledgements',
      where: 'scope = ? AND connection_id = ? AND kind = ? AND entity_id = ?',
      whereArgs: [scope, connectionId, revision.kind.name, revision.entityId],
    );
    if (rows.isNotEmpty) {
      final previous = SyncRevision.decode(rows.single['revision'] as String);
      _checkIdentity(previous, revision);
      if (previous.compareTo(revision) >= 0) return;
    }
    await txn.insert('replica_acknowledgements', {
      'scope': scope,
      'connection_id': connectionId,
      'kind': revision.kind.name,
      'entity_id': revision.entityId,
      'revision_id': revision.revisionId,
      'revision': revision.encode(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> cursor(String connectionId) async {
    final rows = await database.query(
      'replica_cursors',
      where: 'scope = ? AND connection_id = ?',
      whereArgs: [scope, connectionId],
    );
    return rows.isEmpty ? null : rows.single['cursor'] as String?;
  }

  /// The cursor and every discovered record commit together. A restart after
  /// this point resumes from the inbox, even if content has not downloaded yet.
  Future<void> stagePage(
    String connectionId,
    SyncChangePage page, {
    void Function()? ensureCurrent,
  }) => database.transaction((txn) async {
    ensureCurrent?.call();
    for (final revision in page.revisions) {
      final rows = await txn.query(
        'replica_inbox',
        where: 'scope = ? AND connection_id = ? AND kind = ? AND entity_id = ? AND revision_id = ?',
        whereArgs: [
          scope,
          connectionId,
          revision.kind.name,
          revision.entityId,
          revision.revisionId,
        ],
      );
      if (rows.isNotEmpty) {
        _checkIdentity(
          SyncRevision.decode(rows.single['revision'] as String),
          revision,
        );
      } else {
        await txn.insert('replica_inbox', {
          'scope': scope,
          'connection_id': connectionId,
          'kind': revision.kind.name,
          'entity_id': revision.entityId,
          'revision_id': revision.revisionId,
          'revision': revision.encode(),
        });
      }
    }
    await txn.insert('replica_cursors', {
      'scope': scope,
      'connection_id': connectionId,
      'cursor': page.cursor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    ensureCurrent?.call();
  });

  Future<List<SyncRevision>> inbox(
    String connectionId, {
    int limit = 100,
    (String, String, String)? after,
  }) async {
    final rows = await database.rawQuery(
      '''SELECT revision FROM replica_inbox
      WHERE scope = ? AND connection_id = ? AND
      (? IS NULL OR kind > ? OR (kind = ? AND entity_id > ?) OR
        (kind = ? AND entity_id = ? AND revision_id > ?))
      ORDER BY kind, entity_id, revision_id LIMIT ?''',
      [
        scope,
        connectionId,
        after?.$1,
        after?.$1,
        after?.$1,
        after?.$2,
        after?.$1,
        after?.$2,
        after?.$3,
        limit,
      ],
    );
    return rows
        .map((row) => SyncRevision.decode(row['revision'] as String))
        .toList();
  }

  /// Execute with domain application and source acknowledgement in one txn.
  Future<void> removeIncoming(
    Transaction txn,
    String connectionId,
    SyncRevision revision,
  ) async {
    await txn.delete(
      'replica_inbox',
      where: 'scope = ? AND connection_id = ? AND kind = ? AND entity_id = ? AND revision_id = ?',
      whereArgs: [
        scope,
        connectionId,
        revision.kind.name,
        revision.entityId,
        revision.revisionId,
      ],
    );
  }

  static void _checkIdentity(SyncRevision a, SyncRevision b) {
    if (a.revisionId == b.revisionId && !a.sameContent(b)) {
      throw const SyncRevisionIdentityConflict();
    }
  }
}

/// A revision ID must never describe two different contents.
class SyncRevisionIdentityConflict extends FormatException {
  const SyncRevisionIdentityConflict()
    : super('Sync revision identity reused with different content');
}
