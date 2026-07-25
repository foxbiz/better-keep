import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Repairs the one-to-one relationship between local entities, their stable
/// sync IDs, and sync-track rows before uniqueness constraints are enabled.
class SyncIdentityMigration {
  const SyncIdentityMigration._();

  static const _uuid = Uuid();

  static Future<void> migrate(DatabaseExecutor db) async {
    await _reconcile(
      db,
      entityTable: 'note',
      trackTable: 'sync_track',
      entityIndex: 'idx_note_sync_id',
      trackLocalIndex: 'idx_sync_track_local_id',
      trackRemoteIndex: 'idx_sync_track_remote_id',
      repairNoteSortReferences: true,
    );
    await _reconcile(
      db,
      entityTable: 'label',
      trackTable: 'label_sync_track',
      entityIndex: 'idx_label_sync_id',
      trackLocalIndex: 'idx_label_sync_track_local_id',
      trackRemoteIndex: 'idx_label_sync_track_remote_id',
      repairNoteSortReferences: false,
    );
  }

  static Future<void> _reconcile(
    DatabaseExecutor db, {
    required String entityTable,
    required String trackTable,
    required String entityIndex,
    required String trackLocalIndex,
    required String trackRemoteIndex,
    required bool repairNoteSortReferences,
  }) async {
    if (!await _tableExists(db, entityTable) ||
        !await _tableExists(db, trackTable)) {
      return;
    }

    final entityColumns = await db.rawQuery('PRAGMA table_info($entityTable)');
    if (!entityColumns.any((column) => column['name'] == 'sync_id')) {
      await db.execute('ALTER TABLE $entityTable ADD COLUMN sync_id TEXT');
    }

    // A prerelease v8 database may already have this index. Drop it while the
    // repair assigns canonical IDs, then recreate it at the end.
    await db.execute('DROP INDEX IF EXISTS $entityIndex');
    await db.execute('DROP INDEX IF EXISTS $trackLocalIndex');
    await db.execute('DROP INDEX IF EXISTS $trackRemoteIndex');

    final entities = await db.query(entityTable, orderBy: 'id ASC');
    final entityById = <int, Map<String, Object?>>{
      for (final entity in entities)
        if (entity['id'] is int) entity['id'] as int: entity,
    };
    final tracks = await db.query(trackTable, orderBy: 'id ASC');
    final tracksByLocalId = <int, List<Map<String, Object?>>>{};
    for (final track in tracks) {
      final localId = track['local_id'];
      if (localId is int) {
        tracksByLocalId.putIfAbsent(localId, () => []).add(track);
      }
    }

    final canonicalTracks = <int, _CanonicalTrack>{};
    for (final entry in tracksByLocalId.entries) {
      final canonical = _mergeTracks(
        entry.value,
        entityById[entry.key]?['sync_id'],
      );
      canonicalTracks[entry.key] = canonical;
      await db.update(
        trackTable,
        canonical.toDatabaseJson(),
        where: 'id = ?',
        whereArgs: [canonical.id],
      );
      final duplicateIds = entry.value
          .map((track) => track['id'])
          .whereType<int>()
          .where((id) => id != canonical.id)
          .toList();
      if (duplicateIds.isNotEmpty) {
        await db.delete(
          trackTable,
          where: 'id IN (${List.filled(duplicateIds.length, '?').join(',')})',
          whereArgs: duplicateIds,
        );
      }
    }

    final remoteOwners = <String, List<_CanonicalTrack>>{};
    for (final track in canonicalTracks.values) {
      final remoteId = _nonEmpty(track.remoteId);
      if (remoteId != null) {
        remoteOwners.putIfAbsent(remoteId, () => []).add(track);
      }
    }

    final ownerByRemoteId = <String, int>{};
    for (final entry in remoteOwners.entries) {
      final candidates = entry.value;
      candidates.sort((a, b) {
        final aMatches = entityById[a.localId]?['sync_id'] == entry.key ? 0 : 1;
        final bMatches = entityById[b.localId]?['sync_id'] == entry.key ? 0 : 1;
        final matchComparison = aMatches.compareTo(bMatches);
        return matchComparison != 0 ? matchComparison : a.id.compareTo(b.id);
      });
      final owner = candidates.first;
      ownerByRemoteId[entry.key] = owner.localId;
      for (final duplicate in candidates.skip(1)) {
        if (!entityById.containsKey(duplicate.localId)) {
          await db.delete(
            trackTable,
            where: 'id = ?',
            whereArgs: [duplicate.id],
          );
          canonicalTracks.remove(duplicate.localId);
          continue;
        }
        duplicate.remoteId = null;
        duplicate.action = 'upload';
        duplicate.status = 'pending';
        await db.update(
          trackTable,
          duplicate.toDatabaseJson(),
          where: 'id = ?',
          whereArgs: [duplicate.id],
        );
      }
    }

    final reservedRemoteIds = ownerByRemoteId.keys.toSet();
    final assignedIds = <String>{};
    final replacements = <String, String>{};
    for (final entity in entities) {
      final localId = entity['id'];
      if (localId is! int) continue;
      final track = canonicalTracks[localId];
      final remoteId = _nonEmpty(track?.remoteId);
      final existing = _nonEmpty(entity['sync_id']);
      String? stableId;
      if (remoteId != null && ownerByRemoteId[remoteId] == localId) {
        stableId = remoteId;
      } else if (existing != null &&
          !assignedIds.contains(existing) &&
          !reservedRemoteIds.contains(existing)) {
        stableId = existing;
      }
      stableId ??= _newUniqueId(assignedIds, reservedRemoteIds);
      assignedIds.add(stableId);
      await db.update(
        entityTable,
        {'sync_id': stableId},
        where: 'id = ?',
        whereArgs: [localId],
      );
      if (repairNoteSortReferences &&
          existing != null &&
          existing != stableId) {
        replacements[existing] = stableId;
      }
    }

    if (repairNoteSortReferences && replacements.isNotEmpty) {
      await _repairNoteSortReferences(db, replacements);
    }

    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $entityIndex '
      'ON $entityTable(sync_id) WHERE sync_id IS NOT NULL',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $trackLocalIndex '
      'ON $trackTable(local_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS $trackRemoteIndex '
      'ON $trackTable(remote_id) WHERE remote_id IS NOT NULL',
    );
  }

  static _CanonicalTrack _mergeTracks(
    List<Map<String, Object?>> tracks,
    Object? existingSyncId,
  ) {
    final ordered = [...tracks]
      ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    var winner = ordered.first;
    final existing = _nonEmpty(existingSyncId);
    if (existing != null) {
      winner = ordered.firstWhere(
        (track) => _nonEmpty(track['remote_id']) == existing,
        orElse: () => winner,
      );
    } else {
      winner = ordered.firstWhere(
        (track) => _nonEmpty(track['remote_id']) != null,
        orElse: () => winner,
      );
    }

    final deleteWins = ordered.any((track) => track['action'] == 'delete');
    final statuses = ordered.map((track) => track['status'] as String?).toSet();
    final status = statuses.contains('pending')
        ? 'pending'
        : statuses.contains('failed')
        ? 'failed'
        : statuses.contains('syncing')
        ? 'syncing'
        : 'synced';
    final createdValues =
        ordered.map((track) => track['created_at']).whereType<String>().toList()
          ..sort();
    final updatedValues =
        ordered.map((track) => track['updated_at']).whereType<String>().toList()
          ..sort();
    return _CanonicalTrack(
      id: winner['id'] as int,
      localId: winner['local_id'] as int,
      remoteId: _nonEmpty(winner['remote_id']),
      action: deleteWins ? 'delete' : 'upload',
      status: status,
      createdAt: createdValues.firstOrNull,
      updatedAt: updatedValues.lastOrNull,
    );
  }

  static String _newUniqueId(Set<String> assigned, Set<String> reserved) {
    var value = _uuid.v4();
    while (assigned.contains(value) || reserved.contains(value)) {
      value = _uuid.v4();
    }
    return value;
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<void> _repairNoteSortReferences(
    DatabaseExecutor db,
    Map<String, String> replacements,
  ) async {
    if (await _tableExists(db, 'note_sort_position')) {
      final contexts = await db.rawQuery(
        'SELECT DISTINCT context_key FROM note_sort_position',
      );
      for (final contextRow in contexts) {
        final contextKey = contextRow['context_key'];
        if (contextKey is! String) continue;
        final positions = await db.query(
          'note_sort_position',
          columns: ['note_sync_id'],
          where: 'context_key = ?',
          whereArgs: [contextKey],
          orderBy: 'position ASC',
        );
        final repaired = <String>[];
        final seen = <String>{};
        for (final position in positions) {
          final oldId = position['note_sync_id'];
          if (oldId is! String) continue;
          final newId = replacements[oldId] ?? oldId;
          if (seen.add(newId)) repaired.add(newId);
        }
        await db.delete(
          'note_sort_position',
          where: 'context_key = ?',
          whereArgs: [contextKey],
        );
        for (final entry in repaired.indexed) {
          await db.insert('note_sort_position', {
            'context_key': contextKey,
            'note_sync_id': entry.$2,
            'position': entry.$1,
          });
        }
      }
    }

    if (!await _tableExists(db, 'note_sort_operation')) return;
    final operations = await db.query(
      'note_sort_operation',
      columns: ['id', 'payload'],
    );
    for (final operation in operations) {
      final id = operation['id'];
      final payload = operation['payload'];
      if (id is! String || payload is! String) continue;
      try {
        final decoded = Map<String, dynamic>.from(jsonDecode(payload) as Map);
        var changed = false;
        for (final key in const ['note_id', 'before_id', 'after_id']) {
          final oldId = decoded[key];
          final newId = oldId is String ? replacements[oldId] : null;
          if (newId != null && newId != oldId) {
            decoded[key] = newId;
            changed = true;
          }
        }
        if (changed) {
          await db.update(
            'note_sort_operation',
            {'payload': jsonEncode(decoded)},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      } catch (_) {
        // Invalid operations are ignored by the normal operation decoder.
      }
    }
  }

  static Future<bool> _tableExists(
    DatabaseExecutor db,
    String tableName,
  ) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [tableName],
    );
    return rows.isNotEmpty;
  }
}

class SyncTrackIdentityConflict implements Exception {
  const SyncTrackIdentityConflict({
    required this.remoteId,
    required this.existingLocalId,
    required this.requestedLocalId,
  });

  final String remoteId;
  final int existingLocalId;
  final int requestedLocalId;

  @override
  String toString() =>
      'Remote sync ID $remoteId belongs to local entity $existingLocalId, '
      'not $requestedLocalId';
}

class _CanonicalTrack {
  _CanonicalTrack({
    required this.id,
    required this.localId,
    required this.remoteId,
    required this.action,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final int localId;
  String? remoteId;
  String action;
  String status;
  final String? createdAt;
  final String? updatedAt;

  Map<String, Object?> toDatabaseJson() => {
    'local_id': localId,
    'remote_id': remoteId,
    'action': action,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}
