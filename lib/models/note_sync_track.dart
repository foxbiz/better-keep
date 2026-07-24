import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/services/sync_track_store.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

enum SyncAction { upload, delete }

enum SyncStatus { pending, syncing, synced, failed }

class NoteSyncTrack extends BaseModel<NoteSyncTrack> {
  static final ModelSchema<NoteSyncTrack> _schema = _createSchema();
  static const String model = "sync_track";

  int localId;
  String? remoteId;
  SyncAction action;
  SyncStatus status;
  DateTime? createdAt;
  DateTime? updatedAt;

  NoteSyncTrack({
    super.id,
    this.remoteId,
    this.createdAt,
    this.updatedAt,
    required this.action,
    required this.localId,
    this.status = SyncStatus.pending,
  });

  factory NoteSyncTrack.fromJson(Map<String, dynamic> obj) {
    return NoteSyncTrack(
      id: obj['id'],
      localId: obj['local_id'],
      remoteId: obj['remote_id'],
      createdAt: obj['created_at'] == null
          ? null
          : DateTime.tryParse(obj['created_at'].toString()),
      updatedAt: obj['updated_at'] == null
          ? null
          : DateTime.tryParse(obj['updated_at'].toString()),
      action: SyncAction.values.byName(obj['action']),
      status: SyncStatus.values.byName(obj['status']),
    );
  }

  static Future<void> createTable(Database db) {
    return _schema.createTable(db);
  }

  static Future<void> upgradeTable(
    Database db,
    int oldVersion,
    int newVersion,
  ) {
    return _schema.upgradeTable(db, oldVersion, newVersion);
  }

  static Future<int> count({
    bool? pending,
    SyncAction? action,
    SyncStatus? status,
  }) {
    final clauses = <String>[];
    final args = <Object>[];

    if (action != null) {
      clauses.add("action = ?");
      args.add(action.name);
    }

    if (pending == true) {
      clauses.add("(status = ? OR status = ?)");
      args.add('pending');
      args.add('failed');
    } else if (status != null) {
      clauses.add("status = ?");
      args.add(status.name);
    }

    return AppState.db
        .rawQuery(
          'SELECT COUNT(*) FROM $model'
          '${clauses.isNotEmpty ? " WHERE ${clauses.join(" AND ")}" : ""}',
          args,
        )
        .then((rows) => Sqflite.firstIntValue(rows) ?? 0);
  }

  static Future<List<NoteSyncTrack>> get({
    int? limit,
    int? offset,
    int? localId,
    bool? pending,
    String? remoteId,
    SyncAction? action,
    SyncStatus? status,
  }) async {
    final clauses = <String>[];
    final args = <Object>[];

    if (localId != null) {
      clauses.add("local_id = ?");
      args.add(localId);
    }

    if (remoteId != null) {
      clauses.add("remote_id = ?");
      args.add(remoteId);
    }

    if (action != null) {
      clauses.add("action = ?");
      args.add(action.name);
    }

    if (pending == true) {
      clauses.add("(status = ? OR status = ?)");
      args.add('pending');
      args.add('failed');
    } else if (status != null) {
      clauses.add("status = ?");
      args.add(status.name);
    }

    final rows = await AppState.db.query(
      model,
      where: clauses.isNotEmpty ? clauses.join(" AND ") : null,
      whereArgs: args.isNotEmpty ? args : null,
      limit: limit,
      offset: offset,
    );

    return rows.map((e) => NoteSyncTrack.fromJson(e)).toList();
  }

  static Future<NoteSyncTrack?> getByLocalId(int localId) async {
    final rows = await get(localId: localId, limit: 1);
    if (rows.isEmpty) {
      return null;
    }
    return rows.first;
  }

  static Future<NoteSyncTrack?> getByRemoteId(String remoteId) async {
    final rows = await get(remoteId: remoteId, limit: 1);
    if (rows.isEmpty) {
      return null;
    }
    return rows.first;
  }

  Future<int> save() async {
    final canonical = await SyncTrackStore.save(
      database: AppState.db,
      table: model,
      incoming: _toStoreRow(),
    );
    _applyStoreRow(canonical);
    return id!;
  }

  Future<void> delete() async {
    AppLogger.log(
      "[NOTE_SYNC] Deleting sync track for note $localId, action $action",
    );
    if (id == null) {
      return;
    }
    await AppState.db.delete(model, where: "id = ?", whereArgs: [id]);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'local_id': localId,
      'remote_id': remoteId,
      'action': action.name,
      'status': status.name,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  /// Marks the sync as complete, but only if the sync track hasn't been modified
  /// since [syncStartTime]. If modified, the note was changed during sync and
  /// needs to be synced again, so returns false.
  Future<bool> markSyncedIfUnchanged(
    DateTime syncStartTime, [
    String? newRemoteId,
  ]) async {
    final transition = await SyncTrackStore.markSyncedIfUnchanged(
      database: AppState.db,
      table: model,
      localId: localId,
      syncStartTime: syncStartTime,
      expectedUpdatedAt: updatedAt,
      newRemoteId: newRemoteId,
    );
    _applyStoreRow(transition.row);
    return transition.applied;
  }

  Future<void> markSynced([String? newRemoteId]) async {
    await markSyncedIfUnchanged(updatedAt ?? DateTime.now(), newRemoteId);
  }

  Future<void> markFailed() async {
    final canonical = await SyncTrackStore.markStatusIfUnchanged(
      database: AppState.db,
      table: model,
      localId: localId,
      expectedUpdatedAt: updatedAt,
      status: SyncStatus.failed.name,
    );
    if (canonical != null) _applyStoreRow(canonical);
  }

  Future<void> setAction(SyncAction newAction) async {
    final canonical = await SyncTrackStore.setAction(
      database: AppState.db,
      table: model,
      incoming: _toStoreRow(),
      action: newAction.name,
    );
    _applyStoreRow(canonical);
  }

  Future<void> claimRemoteId(String newRemoteId) async {
    final canonical = await SyncTrackStore.claimRemoteId(
      database: AppState.db,
      table: model,
      incoming: _toStoreRow(),
      expectedRemoteId: remoteId,
      remoteId: newRemoteId,
    );
    _applyStoreRow(canonical);
  }

  SyncTrackRow _toStoreRow() {
    return SyncTrackRow(
      id: id,
      localId: localId,
      remoteId: remoteId,
      action: action.name,
      status: status.name,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  void _applyStoreRow(SyncTrackRow? row) {
    if (row == null) {
      id = null;
      return;
    }
    id = row.id;
    remoteId = row.remoteId;
    action = SyncAction.values.byName(row.action);
    status = SyncStatus.values.byName(row.status);
    createdAt = row.createdAt;
    updatedAt = row.updatedAt;
  }
}

class _SyncTrackSchema implements ModelSchema<NoteSyncTrack> {
  @override
  Future<void> createTable(Database db) async {
    await db.execute("""
      CREATE TABLE IF NOT EXISTS sync_track (
        id INTEGER PRIMARY KEY,
        remote_id TEXT,
        action TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        status TEXT DEFAULT 'pending',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """);
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_track_local_id '
      'ON sync_track(local_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_track_remote_id '
      'ON sync_track(remote_id) WHERE remote_id IS NOT NULL',
    );
  }

  @override
  Future<void> upgradeTable(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {}

  @override
  Future<List<NoteSyncTrack>> get(List<dynamic> args) async {
    return [];
  }

  @override
  Future<int> count(List<dynamic> args) async {
    return 0;
  }
}

ModelSchema<NoteSyncTrack> _createSchema() {
  final schema = _SyncTrackSchema();
  BaseModel.registerSchema<NoteSyncTrack>(schema);
  return schema;
}
