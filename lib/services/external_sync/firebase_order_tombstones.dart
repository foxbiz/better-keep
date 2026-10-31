import 'package:sqflite/sqflite.dart';

import 'sync_mutation_journal.dart';
import 'sync_replica_store.dart';
import 'sync_revision.dart';

/// Firebase ordering has no row to mark clean after a context is deleted.
/// Reuse the replica acknowledgement table without mixing provider libraries.
class FirebaseOrderTombstones {
  static String scope(String uid) => 'firebase-order:$uid';
  static const connectionId = 'firebase';

  static Future<List<SyncLocalVersion>> pending(
    DatabaseExecutor db,
    String uid, {
    int limit = 100,
    Set<String> exclude = const {},
  }) async {
    if (!await SyncMutationJournal.isInstalled(db)) return [];
    final rows = await db.rawQuery(
      '''
      SELECT v.* FROM ${SyncMutationJournal.table} v
      WHERE v.kind = 'order' AND v.deleted = 1
        ${exclude.isEmpty ? '' : 'AND v.entity_id NOT IN (${List.filled(exclude.length, '?').join(',')})'}
        AND NOT EXISTS (SELECT 1 FROM replica_acknowledgements a
          WHERE a.scope = ? AND a.connection_id = ? AND a.kind = v.kind
            AND a.entity_id = v.entity_id AND a.revision_id = v.revision_id)
      ORDER BY v.entity_id LIMIT ?
    ''',
      [...exclude, scope(uid), connectionId, limit],
    );
    return rows.map(SyncLocalVersion.fromRow).toList();
  }

  /// Called inside the receiver/publication acknowledgement transaction. The
  /// captured source version, never a newer local deletion, is acknowledged.
  static Future<void> acknowledge(
    Database database,
    Transaction txn,
    String uid,
    SyncVersion version,
  ) {
    if (version.kind != SyncEntityKind.order || !version.deleted) {
      throw const FormatException('Expected an ordering tombstone');
    }
    return SyncReplicaStore(database, scope: scope(uid)).acknowledge(
      txn,
      connectionId,
      SyncRevision(
        kind: version.kind,
        entityId: version.entityId,
        revisionId: version.revisionId,
        modifiedAtMicros: version.modifiedAtMicros,
        deleted: true,
        payloadObjectId: null,
      ),
    );
  }
}
