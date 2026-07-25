import 'package:better_keep/services/sync_identity_migration.dart';
import 'package:sqflite/sqflite.dart';

/// Canonical, model-agnostic representation of a note or label sync row.
class SyncTrackRow {
  const SyncTrackRow({
    required this.id,
    required this.localId,
    required this.remoteId,
    required this.action,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SyncTrackRow.fromDatabaseJson(Map<String, Object?> row) {
    return SyncTrackRow(
      id: row['id'] as int?,
      localId: row['local_id'] as int,
      remoteId: _normalizeRemoteId(row['remote_id']),
      action: row['action'] as String,
      status: row['status'] as String,
      createdAt: _parseDate(row['created_at']),
      updatedAt: _parseDate(row['updated_at']),
    );
  }

  final int? id;
  final int localId;
  final String? remoteId;
  final String action;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

class SyncTrackTransition {
  const SyncTrackTransition({required this.applied, required this.row});

  final bool applied;
  final SyncTrackRow? row;
}

/// Raised when a caller tries to replace an identity without first proving it
/// is still operating on the canonical remote ID.
class SyncTrackRemoteIdConflict implements Exception {
  const SyncTrackRemoteIdConflict({
    required this.localId,
    required this.expectedRemoteId,
    required this.actualRemoteId,
    required this.requestedRemoteId,
  });

  final int localId;
  final String? expectedRemoteId;
  final String? actualRemoteId;
  final String? requestedRemoteId;

  @override
  String toString() =>
      'Sync identity for local entity $localId changed from '
      '$expectedRemoteId to $actualRemoteId before $requestedRemoteId '
      'could be assigned';
}

/// Shared transactional persistence for note and label sync tracks.
///
/// Generic saves merge conservatively so stale objects cannot erase a remote
/// identity or downgrade queued work. Intent-specific transitions are used for
/// identity claims and successful sync completion.
class SyncTrackStore {
  const SyncTrackStore._();

  static const _statusPriority = <String, int>{
    'pending': 0,
    'failed': 1,
    'syncing': 2,
    'synced': 3,
  };

  static Future<SyncTrackRow> save({
    required Database database,
    required String table,
    required SyncTrackRow incoming,
  }) {
    return database.transaction(
      (transaction) => _saveInTransaction(
        transaction: transaction,
        table: table,
        incoming: incoming,
      ),
    );
  }

  static Future<SyncTrackRow> setAction({
    required Database database,
    required String table,
    required SyncTrackRow incoming,
    required String action,
  }) {
    return database.transaction((transaction) async {
      final current = await _findByLocalId(
        transaction,
        table,
        incoming.localId,
      );
      final mergedAction = current?.action == 'delete' && action == 'upload'
          ? 'delete'
          : action;
      return _saveInTransaction(
        transaction: transaction,
        table: table,
        incoming: SyncTrackRow(
          id: current?.id ?? incoming.id,
          localId: incoming.localId,
          remoteId: current?.remoteId ?? incoming.remoteId,
          action: mergedAction,
          status: 'pending',
          createdAt: current?.createdAt ?? incoming.createdAt,
          updatedAt: current?.updatedAt ?? incoming.updatedAt,
        ),
        forceStatus: 'pending',
      );
    });
  }

  /// Atomically claims or replaces a remote ID if [expectedRemoteId] still
  /// matches the canonical row. Identity metadata does not advance
  /// `updated_at`, which is reserved for detecting local work queued mid-sync.
  static Future<SyncTrackRow> claimRemoteId({
    required Database database,
    required String table,
    required SyncTrackRow incoming,
    required String? expectedRemoteId,
    required String remoteId,
  }) {
    return database.transaction((transaction) async {
      final current = await _findByLocalId(
        transaction,
        table,
        incoming.localId,
      );
      final expected = _normalizeRemoteId(expectedRemoteId);
      final actual = current?.remoteId;
      final requested = _normalizeRemoteId(remoteId);
      if (requested == null) {
        throw ArgumentError.value(remoteId, 'remoteId', 'must not be empty');
      }
      if (actual != expected) {
        throw SyncTrackRemoteIdConflict(
          localId: incoming.localId,
          expectedRemoteId: expected,
          actualRemoteId: actual,
          requestedRemoteId: requested,
        );
      }
      await _ensureRemoteOwner(transaction, table, incoming.localId, requested);

      final now = DateTime.now();
      if (current == null) {
        final values = <String, Object?>{
          'local_id': incoming.localId,
          'remote_id': requested,
          'action': incoming.action,
          'status': incoming.status,
          'created_at': (incoming.createdAt ?? now).toIso8601String(),
          'updated_at': (incoming.updatedAt ?? now).toIso8601String(),
        };
        final id = await transaction.insert(table, values);
        return SyncTrackRow(
          id: id,
          localId: incoming.localId,
          remoteId: requested,
          action: incoming.action,
          status: incoming.status,
          createdAt: incoming.createdAt ?? now,
          updatedAt: incoming.updatedAt ?? now,
        );
      }

      await transaction.update(
        table,
        {'remote_id': requested},
        where: 'id = ?',
        whereArgs: [current.id],
      );
      return SyncTrackRow(
        id: current.id,
        localId: current.localId,
        remoteId: requested,
        action: current.action,
        status: current.status,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
      );
    });
  }

  static Future<SyncTrackTransition> markSyncedIfUnchanged({
    required Database database,
    required String table,
    required int localId,
    required DateTime syncStartTime,
    DateTime? expectedUpdatedAt,
    String? newRemoteId,
  }) {
    return database.transaction((transaction) async {
      final current = await _findByLocalId(transaction, table, localId);
      if (current == null) {
        return const SyncTrackTransition(applied: true, row: null);
      }
      final changed = expectedUpdatedAt != null
          ? current.updatedAt != expectedUpdatedAt
          : current.updatedAt?.isAfter(syncStartTime) ?? false;
      if (changed) {
        return SyncTrackTransition(applied: false, row: current);
      }

      final requested = _normalizeRemoteId(newRemoteId);
      final remoteId = requested ?? current.remoteId;
      if (requested != null &&
          current.remoteId != null &&
          current.remoteId != requested) {
        throw SyncTrackRemoteIdConflict(
          localId: localId,
          expectedRemoteId: current.remoteId,
          actualRemoteId: current.remoteId,
          requestedRemoteId: requested,
        );
      }
      if (remoteId != null) {
        await _ensureRemoteOwner(transaction, table, localId, remoteId);
      }

      if (current.action == 'delete') {
        await transaction.delete(
          table,
          where: 'id = ?',
          whereArgs: [current.id],
        );
        return const SyncTrackTransition(applied: true, row: null);
      }

      final now = DateTime.now();
      await transaction.update(
        table,
        {
          'remote_id': remoteId,
          'status': 'synced',
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [current.id],
      );
      return SyncTrackTransition(
        applied: true,
        row: SyncTrackRow(
          id: current.id,
          localId: current.localId,
          remoteId: remoteId,
          action: current.action,
          status: 'synced',
          createdAt: current.createdAt,
          updatedAt: now,
        ),
      );
    });
  }

  static Future<SyncTrackRow?> markStatusIfUnchanged({
    required Database database,
    required String table,
    required int localId,
    required DateTime? expectedUpdatedAt,
    required String status,
  }) {
    return database.transaction((transaction) async {
      final current = await _findByLocalId(transaction, table, localId);
      if (current == null) return null;
      if (expectedUpdatedAt != null && current.updatedAt != expectedUpdatedAt) {
        return current;
      }
      final now = DateTime.now();
      await transaction.update(
        table,
        {'status': status, 'updated_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: [current.id],
      );
      return SyncTrackRow(
        id: current.id,
        localId: current.localId,
        remoteId: current.remoteId,
        action: current.action,
        status: status,
        createdAt: current.createdAt,
        updatedAt: now,
      );
    });
  }

  static Future<SyncTrackRow> _saveInTransaction({
    required Transaction transaction,
    required String table,
    required SyncTrackRow incoming,
    String? forceStatus,
  }) async {
    final current = await _findByLocalId(transaction, table, incoming.localId);
    final incomingRemoteId = _normalizeRemoteId(incoming.remoteId);
    if (current?.remoteId != null &&
        incomingRemoteId != null &&
        current!.remoteId != incomingRemoteId) {
      throw SyncTrackRemoteIdConflict(
        localId: incoming.localId,
        expectedRemoteId: incomingRemoteId,
        actualRemoteId: current.remoteId,
        requestedRemoteId: incomingRemoteId,
      );
    }
    final remoteId = incomingRemoteId ?? current?.remoteId;
    if (remoteId != null) {
      await _ensureRemoteOwner(transaction, table, incoming.localId, remoteId);
    }

    final action = current?.action == 'delete' && incoming.action == 'upload'
        ? 'delete'
        : incoming.action;
    final status =
        forceStatus ?? _dominantStatus(current?.status, incoming.status);
    final now = DateTime.now();
    final createdAt = current?.createdAt ?? incoming.createdAt ?? now;
    final row = SyncTrackRow(
      id: current?.id,
      localId: incoming.localId,
      remoteId: remoteId,
      action: action,
      status: status,
      createdAt: createdAt,
      updatedAt: now,
    );
    final values = <String, Object?>{
      'local_id': row.localId,
      'remote_id': row.remoteId,
      'action': row.action,
      'status': row.status,
      'created_at': row.createdAt?.toIso8601String(),
      'updated_at': row.updatedAt?.toIso8601String(),
    };
    if (row.id == null) {
      final id = await transaction.insert(table, values);
      return SyncTrackRow(
        id: id,
        localId: row.localId,
        remoteId: row.remoteId,
        action: row.action,
        status: row.status,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
    }
    await transaction.update(
      table,
      values,
      where: 'id = ?',
      whereArgs: [row.id],
    );
    return row;
  }

  static Future<SyncTrackRow?> _findByLocalId(
    DatabaseExecutor database,
    String table,
    int localId,
  ) async {
    final rows = await database.query(
      table,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncTrackRow.fromDatabaseJson(rows.first);
  }

  static Future<void> _ensureRemoteOwner(
    DatabaseExecutor database,
    String table,
    int localId,
    String remoteId,
  ) async {
    final owners = await database.query(
      table,
      columns: ['local_id'],
      where: 'remote_id = ? AND local_id != ?',
      whereArgs: [remoteId, localId],
      limit: 1,
    );
    if (owners.isNotEmpty) {
      throw SyncTrackIdentityConflict(
        remoteId: remoteId,
        existingLocalId: owners.first['local_id'] as int,
        requestedLocalId: localId,
      );
    }
  }

  static String _dominantStatus(String? existing, String incoming) {
    if (existing == null) return incoming;
    final existingPriority = _statusPriority[existing] ?? 0;
    final incomingPriority = _statusPriority[incoming] ?? 0;
    return existingPriority <= incomingPriority ? existing : incoming;
  }
}

DateTime? _parseDate(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

String? _normalizeRemoteId(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
