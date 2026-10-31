import 'dart:typed_data';

import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/sync_track_store.dart';
import 'package:sqflite/sqflite.dart';

import 'portable_sync_codec.dart';
import 'sync_mutation_journal.dart';
import 'sync_object_cache.dart';
import 'sync_replica_engine.dart';
import 'sync_replica_store.dart';
import 'sync_revision.dart';

enum SyncCaptureFailure { unavailable, invalidSource, unlockRequired }

class SyncAppliedChange {
  SyncAppliedChange({
    required this.revision,
    required this.localId,
    required this.event,
    Map<String, Object?>? row,
  }) : row = row == null ? null : Map.unmodifiable(row);
  final SyncRevision revision;
  final String localId;
  final String event;
  final Map<String, Object?>? row;
}

/// Connects provider-independent revisions to the existing local library.
/// Network/filesystem preparation never holds the domain transaction open.
class LibraryReplicaContent
    implements SyncReplicaContent, PreparingSyncReplicaContent {
  LibraryReplicaContent({
    required this.store,
    required this.objects,
    required this.codec,
    required this.isCurrent,
    this.onApplied,
  });
  final SyncReplicaStore store;
  final SyncObjectCache objects;
  final PortableSyncCodec codec;
  final bool Function() isCurrent;
  final Future<void> Function(SyncAppliedChange change)? onApplied;
  final _capture = AsyncKeyedSerializer<String>();
  final Map<String, SyncCaptureFailure> captureFailures = {};
  int get notesRequiringUnlock => captureFailures.values
      .where((failure) => failure == SyncCaptureFailure.unlockRequired)
      .length;

  @override
  Future<Uint8List?> read(String objectId) async {
    _guard();
    final bytes = await objects.read(objectId);
    _guard();
    return bytes;
  }

  @override
  Future<void> cache(String objectId, Uint8List bytes) async {
    _guard();
    await objects.write(objectId, bytes);
    _guard();
  }

  void _guard() {
    if (!isCurrent()) throw const SyncReplicaCancelled();
  }

  @override
  Future<SyncVersion?> localVersion(
    SyncEntityKind kind,
    String entityId,
  ) async {
    _guard();
    final version = await SyncMutationJournal.current(
      store.database,
      kind,
      entityId,
    );
    _guard();
    return version;
  }

  @override
  Future<void> captureLocalChanges() => _capture.run('library', () async {
    (String, String)? after;
    while (true) {
      _guard();
      final pending = await SyncMutationJournal.pending(
        store.database,
        store.scope,
        limit: 100,
        after: after,
      );
      if (pending.isEmpty) break;
      // Each row is attempted once per sweep, including blocked media.
      after = (pending.last.kind.name, pending.last.entityId);
      for (final version in pending) {
        _guard();
        final key = '${version.kind.name}:${version.entityId}';
        try {
          final snapshot = await store.database.transaction((txn) async {
            final current = await SyncMutationJournal.current(
              txn,
              version.kind,
              version.entityId,
            );
            if (current?.revisionId != version.revisionId) return null;
            if (version.deleted) return (<String, Object?>{}, <String>[]);
            final table = _table(version.kind);
            final identity = version.kind == SyncEntityKind.order
                ? 'context_key'
                : 'sync_id';
            final rows = await txn.query(
              table,
              where: '$identity = ?',
              whereArgs: [version.entityId],
            );
            if (rows.isEmpty) {
              throw StateError('Local entity disappeared without a tombstone');
            }
            final positions = version.kind == SyncEntityKind.order
                ? await txn.query(
                    'note_sort_position',
                    where: 'context_key = ?',
                    whereArgs: [version.entityId],
                    orderBy: 'position',
                  )
                : const <Map<String, Object?>>[];
            return (
              rows.single,
              positions.map((row) => row['note_sync_id'] as String).toList(),
            );
          });
          if (snapshot == null) continue;
          final revision = await codec.encode(
            version,
            snapshot.$1,
            orderedIds: snapshot.$2,
          );
          _guard();
          await store.database.transaction((txn) async {
            _guard();
            final current = await SyncMutationJournal.current(
              txn,
              version.kind,
              version.entityId,
            );
            if (current?.revisionId == version.revisionId) {
              await store.accept(txn, revision);
            }
            _guard();
          });
          captureFailures.remove(key);
        } on SyncReplicaCancelled {
          rethrow;
        } catch (error) {
          _guard();
          final current = await SyncMutationJournal.current(
            store.database,
            version.kind,
            version.entityId,
          );
          _guard();
          if (current?.revisionId != version.revisionId) {
            // Another provider may have replaced the source while this read was
            // in flight. Its successful application must not inherit our error.
            captureFailures.remove(key);
            continue;
          }
          captureFailures[key] = error is SyncSourceRequiresUnlock
              ? SyncCaptureFailure.unlockRequired
              : error is FormatException
              ? SyncCaptureFailure.invalidSource
              : SyncCaptureFailure.unavailable;
        }
      }
    }
  });

  @override
  Future<PreparedSyncApplication> prepare(SyncRevision revision) async {
    _guard();
    final prepared = await codec.decode(revision);
    _guard();
    SyncAppliedChange? committed;
    return PreparedSyncApplication(
      apply: (txn) async {
        _guard();
        final local = await SyncMutationJournal.current(
          txn,
          revision.kind,
          revision.entityId,
        );
        if (local != null && local.compareTo(revision) > 0) {
          throw const SyncLocalMutationPending();
        }
        final table = _table(revision.kind);
        final identity = revision.kind == SyncEntityKind.order
            ? 'context_key'
            : 'sync_id';
        final existing = await txn.query(
          table,
          where: '$identity = ?',
          whereArgs: [revision.entityId],
        );
        final localId = revision.kind == SyncEntityKind.order
            ? revision.entityId
            : existing.isNotEmpty
            ? existing.single['id'].toString()
            : await _allocateId(txn, table, local);
        await SyncMutationJournal.withoutCapture(txn, () async {
          if (revision.deleted) {
            if (revision.kind == SyncEntityKind.order) {
              await txn.delete(
                'note_sort_position',
                where: 'context_key = ?',
                whereArgs: [revision.entityId],
              );
              await txn.delete(
                'note_sort_operation',
                where: 'context_key = ?',
                whereArgs: [revision.entityId],
              );
            }
            await txn.delete(
              table,
              where: '$identity = ?',
              whereArgs: [revision.entityId],
            );
          } else if (revision.kind == SyncEntityKind.order) {
            final row = Map<String, Object?>.from(prepared)
              ..remove('ordered_ids');
            if (existing.isEmpty) {
              await txn.insert(table, row);
            } else {
              await txn.update(
                table,
                row,
                where: 'context_key = ?',
                whereArgs: [revision.entityId],
              );
            }
            await txn.delete(
              'note_sort_position',
              where: 'context_key = ?',
              whereArgs: [revision.entityId],
            );
            await txn.delete(
              'note_sort_operation',
              where: 'context_key = ?',
              whereArgs: [revision.entityId],
            );
            for (final entry
                in (prepared['ordered_ids'] as List<String>).indexed) {
              await txn.insert('note_sort_position', {
                'context_key': revision.entityId,
                'note_sync_id': entry.$2,
                'position': entry.$1,
              });
            }
          } else {
            final row = {...prepared, 'id': int.parse(localId)};
            if (existing.isEmpty) {
              await txn.insert(table, row);
            } else {
              await txn.update(
                table,
                row,
                where: 'id = ?',
                whereArgs: [int.parse(localId)],
              );
            }
          }
          await SyncMutationJournal.received(txn, revision, localId);
          if (revision.kind != SyncEntityKind.order) {
            await _queueFirebase(txn, revision, int.parse(localId));
          }
        });
        _guard();
        committed = SyncAppliedChange(
          revision: revision,
          localId: localId,
          event: revision.deleted
              ? 'deleted'
              : existing.isEmpty
              ? 'created'
              : 'updated',
          row: revision.deleted
              ? existing.firstOrNull
              : {
                  ...prepared,
                  if (revision.kind != SyncEntityKind.order)
                    'id': int.parse(localId),
                },
        );
      },
      didCommit: () async {
        _guard();
        if (committed != null) {
          captureFailures.remove('${revision.kind.name}:${revision.entityId}');
          await onApplied?.call(committed!);
        }
      },
    );
  }

  @override
  Future<void> apply(Transaction txn, SyncRevision revision) async {
    // The replica engine always uses prepare() for this implementation.
    throw StateError(
      'Library changes must be prepared before their transaction',
    );
  }

  static String _table(SyncEntityKind kind) => switch (kind) {
    SyncEntityKind.note => 'note',
    SyncEntityKind.label => 'label',
    SyncEntityKind.order => 'note_sort_context',
  };
  static String _track(SyncEntityKind kind) =>
      kind == SyncEntityKind.note ? 'sync_track' : 'label_sync_track';

  Future<String> _allocateId(
    Transaction txn,
    String table,
    SyncLocalVersion? local,
  ) async {
    final track = table == 'note' ? 'sync_track' : 'label_sync_track';
    if (local != null && int.tryParse(local.localId) != null) {
      final used = await txn.query(
        table,
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [int.parse(local.localId)],
      );
      if (used.isEmpty) return local.localId;
    }
    final result = await txn.rawQuery(
      '''SELECT MAX(value) AS highest FROM (
      SELECT MAX(id) AS value FROM $table UNION ALL SELECT MAX(local_id) AS value FROM $track)''',
    );
    final maximum = result.single['highest'] as int? ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (maximum >= now ? maximum + 1 : now).toString();
  }

  Future<void> _queueFirebase(
    Transaction txn,
    SyncRevision revision,
    int id,
  ) async {
    final table = _track(revision.kind);
    await SyncTrackStore.queueInTransaction(
      transaction: txn,
      table: table,
      localId: id,
      action: revision.deleted ? 'delete' : 'upload',
    );
    await txn.update(
      table,
      {'action': revision.deleted ? 'delete' : 'upload'},
      where: 'local_id = ?',
      whereArgs: [id],
    );
    await txn.update(
      table,
      {'remote_id': revision.entityId},
      where: 'local_id = ? AND remote_id IS NULL',
      whereArgs: [id],
    );
  }
}
