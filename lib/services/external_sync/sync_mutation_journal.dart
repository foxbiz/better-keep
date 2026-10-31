import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'sync_revision.dart';

/// Local revisions are captured by SQLite triggers, including writes from
/// imports, notification actions, lock/repair transactions and permanent deletes.
/// Content encryption happens later; the local version guards that preparation.
class SyncMutationJournal {
  static const table = 'replica_local_versions';
  static const guardTable = 'replica_write_guard';
  // Content/attachment byte changes without updated_at are local encryption,
  // hydration or derived-preview maintenance. User edits, locks and protected
  // source repairs advance updated_at; those are the semantic revision boundary.
  static const _sources = {
    SyncEntityKind.note: (
      'note',
      'sync_id',
      'id',
      [
        'title',
        'labels',
        'locked',
        'pinned',
        'trashed',
        'archived',
        'read_only',
        'completed',
        'color',
        'updated_at',
        'reminder',
      ],
    ),
    SyncEntityKind.label: (
      'label',
      'sync_id',
      'id',
      ['name', 'is_system', 'updated_at'],
    ),
    SyncEntityKind.order: (
      'note_sort_context',
      'context_key',
      'context_key',
      ['revision', 'sort_mode', 'updated_at'],
    ),
  };

  static Future<void> install(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS $table (
      kind TEXT NOT NULL, entity_id TEXT NOT NULL, local_id TEXT NOT NULL,
      revision_id TEXT NOT NULL, modified_at_micros INTEGER NOT NULL,
      deleted INTEGER NOT NULL, PRIMARY KEY(kind, entity_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS $guardTable (
      id INTEGER PRIMARY KEY CHECK(id = 1), depth INTEGER NOT NULL)''');
    for (final entry in _sources.entries) {
      final (source, identity, localId, fields) = entry.value;
      // Individual model tests and older schemas may not have every domain table.
      if (!await _hasTable(db, source)) continue;
      final kind = entry.key.name;
      for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
        final ref = operation == 'DELETE' ? 'OLD' : 'NEW';
        final changes = operation == 'UPDATE'
            ? 'AND (OLD.$identity IS NOT NEW.$identity OR ${fields.map((f) => 'OLD.$f IS NOT NEW.$f').join(' OR ')})'
            : '';
        await db.execute(
          '''CREATE TRIGGER IF NOT EXISTS replica_${kind}_${operation.toLowerCase()}
          AFTER $operation ON $source
          WHEN $ref.$identity IS NOT NULL AND $ref.$identity != ''
            AND NOT EXISTS(SELECT 1 FROM $guardTable WHERE id = 1) $changes
          BEGIN
            ${_writeSql(kind, '$ref.$identity', '$ref.$localId', operation == 'DELETE')}
          END''',
        );
      }
      // Identity corrections must not leave the previous identity live remotely.
      await db.execute('''CREATE TRIGGER IF NOT EXISTS replica_${kind}_identity
        AFTER UPDATE ON $source
        WHEN OLD.$identity IS NOT NULL AND OLD.$identity != ''
          AND OLD.$identity IS NOT NEW.$identity
          AND NOT EXISTS(SELECT 1 FROM $guardTable WHERE id = 1)
        BEGIN ${_writeSql(kind, 'OLD.$identity', 'OLD.$localId', true)} END''');
      await _bootstrap(db, entry.key, source, identity, localId);
    }
  }

  static String _writeSql(
    String kind,
    String id,
    String localId,
    bool deleted,
  ) {
    // UTC milliseconds from SQLite's clock, made strictly monotonic per entity.
    // A previous received revision can be ahead of this device's clock.
    const clock =
        "CAST(strftime('%s','now') AS INTEGER) * 1000000 + CAST(substr(strftime('%f','now'),4,3) AS INTEGER) * 1000";
    return '''INSERT OR REPLACE INTO $table
      (kind, entity_id, local_id, revision_id, modified_at_micros, deleted)
      VALUES ('$kind', $id, CAST($localId AS TEXT), lower(hex(randomblob(16))),
        MAX($clock, COALESCE((SELECT modified_at_micros + 1 FROM $table
          WHERE kind = '$kind' AND entity_id = $id), 0)), ${deleted ? 1 : 0});''';
  }

  static Future<void> _bootstrap(
    DatabaseExecutor db,
    SyncEntityKind kind,
    String source,
    String identity,
    String localId,
  ) async {
    String after = '';
    while (true) {
      final rows = await db.rawQuery(
        '''SELECT s.$identity AS entity_id,
        s.$localId AS local_id, s.updated_at,
        ${kind == SyncEntityKind.order ? 's.revision' : 'NULL'} AS source_revision
        FROM $source s
        LEFT JOIN $table v ON v.kind = ? AND v.entity_id = s.$identity
        WHERE s.$identity > ? AND v.entity_id IS NULL
        ORDER BY s.$identity LIMIT 100''',
        [kind.name, after],
      );
      if (rows.isEmpty) return;
      for (final row in rows) {
        final timestamp =
            DateTime.tryParse(row['updated_at']?.toString() ?? '')
                ?.toUtc()
                .microsecondsSinceEpoch ??
            0;
        await db.insert(table, {
          'kind': kind.name,
          'entity_id': row['entity_id'],
          'local_id': row['local_id'].toString(),
          'revision_id': row['source_revision'] ?? const Uuid().v4(),
          'modified_at_micros': timestamp < 0 ? 0 : timestamp,
          'deleted': 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      after = rows.last['entity_id'] as String;
    }
  }

  static Future<SyncLocalVersion?> current(
    DatabaseExecutor db,
    SyncEntityKind kind,
    String entityId,
  ) async {
    if (!await isInstalled(db)) return null;
    final rows = await db.query(
      table,
      where: 'kind = ? AND entity_id = ?',
      whereArgs: [kind.name, entityId],
    );
    return rows.isEmpty ? null : SyncLocalVersion.fromRow(rows.single);
  }

  static Future<List<SyncLocalVersion>> pending(
    DatabaseExecutor db,
    String scope, {
    int limit = 50,
    (String, String)? after,
  }) async {
    final rows = await db.rawQuery(
      '''SELECT v.* FROM $table v
      LEFT JOIN replica_entities e ON e.scope = ? AND e.kind = v.kind AND e.entity_id = v.entity_id
      WHERE (e.revision_id IS NULL OR e.revision_id != v.revision_id)
      AND (? IS NULL OR v.kind > ? OR (v.kind = ? AND v.entity_id > ?))
      ORDER BY v.kind, v.entity_id LIMIT ?''',
      [scope, after?.$1, after?.$1, after?.$1, after?.$2, limit],
    );
    return rows.map(SyncLocalVersion.fromRow).toList();
  }

  static Future<void> received(
    Transaction txn,
    SyncVersion revision,
    String localId,
  ) async {
    if (!await isInstalled(txn)) return;
    await txn.insert(table, {
      'kind': revision.kind.name,
      'entity_id': revision.entityId,
      'local_id': localId,
      'revision_id': revision.revisionId,
      'modified_at_micros': revision.modifiedAtMicros,
      'deleted': revision.deleted ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<bool> isInstalled(DatabaseExecutor db) => _hasTable(db, table);

  /// Use inside the same transaction as the remote domain write and [received].
  /// Nested suppression is safe; rollback restores both the guard and content.
  static Future<T> withoutCapture<T>(
    Transaction txn,
    Future<T> Function() action,
  ) async {
    if (!await _hasTable(txn, guardTable)) return action();
    await txn.rawInsert('''INSERT INTO $guardTable (id, depth) VALUES (1, 1)
      ON CONFLICT(id) DO UPDATE SET depth = depth + 1''');
    try {
      return await action();
    } finally {
      await txn.rawUpdate(
        'UPDATE $guardTable SET depth = depth - 1 WHERE id = 1',
      );
      await txn.delete(guardTable, where: 'depth = 0');
    }
  }

  static Future<bool> _hasTable(DatabaseExecutor db, String name) async =>
      (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [name],
      )).isNotEmpty;
}

class SyncLocalVersion extends SyncVersion {
  SyncLocalVersion({
    required super.kind,
    required super.entityId,
    required this.localId,
    required super.revisionId,
    required super.modifiedAtMicros,
    required super.deleted,
  });
  final String localId;
  factory SyncLocalVersion.fromRow(Map<String, Object?> row) =>
      SyncLocalVersion(
        kind: SyncEntityKind.values.byName(row['kind'] as String),
        entityId: row['entity_id'] as String,
        localId: row['local_id'] as String,
        revisionId: row['revision_id'] as String,
        modifiedAtMicros: row['modified_at_micros'] as int,
        deleted: row['deleted'] == 1,
      );

  SyncRevision materialize({
    String? payloadObjectId,
    String? contentFingerprint,
    Iterable<String> legacyContentFingerprints = const [],
    Iterable<String> blobIds = const [],
  }) => SyncRevision(
    kind: kind,
    entityId: entityId,
    revisionId: revisionId,
    modifiedAtMicros: modifiedAtMicros,
    deleted: deleted,
    payloadObjectId: payloadObjectId,
    contentFingerprint: contentFingerprint,
    legacyContentFingerprints: legacyContentFingerprints,
    blobIds: blobIds,
  );
}
