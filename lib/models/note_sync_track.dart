import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/state.dart';
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
      createdAt: DateTime.parse(obj['created_at']),
      updatedAt: DateTime.parse(obj['updated_at']),
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
    var jsonObj = toJson();
    jsonObj['updated_at'] = DateTime.now().toIso8601String();

    if (id != null) {
      await AppState.db.update(
        model,
        jsonObj,
        where: "id = ?",
        whereArgs: [id],
      );
      return id!;
    }

    jsonObj['created_at'] = DateTime.now().toIso8601String();
    id = await AppState.db.insert(model, jsonObj);
    return id!;
  }

  Future<void> delete() async {
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
    if (action == SyncAction.delete) {
      await delete();
      return true;
    }

    // Re-fetch from database to check current state
    final current = await getByLocalId(localId);
    if (current == null) {
      // Sync track was deleted, nothing to do
      return true;
    }

    // Check if the sync track was modified after sync started
    // This means the note was changed during sync
    if (current.updatedAt != null &&
        current.updatedAt!.isAfter(syncStartTime)) {
      // Note was modified during sync, don't mark as synced
      // The new changes will be synced in the next cycle
      return false;
    }

    status = SyncStatus.synced;
    remoteId = newRemoteId ?? remoteId;
    await save();
    return true;
  }

  Future<void> markSynced([String? newRemoteId]) async {
    if (action == SyncAction.delete) {
      await delete();
      return;
    }

    status = SyncStatus.synced;
    remoteId = newRemoteId ?? remoteId;
    await save();
  }

  Future<void> markFailed() async {
    status = SyncStatus.failed;
    await save();
  }

  Future<void> setAction(SyncAction newAction) async {
    // Re-read current state from DB to handle race conditions.
    // This can happen when notes are trashed and deleted quickly - both
    // notify("updated") and notify("deleted") may run concurrently with
    // different in-memory objects.
    if (id != null) {
      final current = await getByLocalId(localId);
      if (current != null) {
        // Prevent downgrading from delete to upload.
        // Once a note is marked for deletion, it should stay that way.
        if (current.action == SyncAction.delete &&
            newAction == SyncAction.upload) {
          return;
        }
        // Update our local state to match DB (preserves remoteId etc.)
        action = current.action;
        remoteId = current.remoteId;
        status = current.status;
        createdAt = current.createdAt;
        updatedAt = current.updatedAt;
      }
    }

    action = newAction;
    status = SyncStatus.pending;
    await save();
  }
}

class _SyncTrackSchema implements ModelSchema<NoteSyncTrack> {
  @override
  Future<void> createTable(Database db) {
    return db.execute("""
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
}

ModelSchema<NoteSyncTrack> _createSchema() {
  final schema = _SyncTrackSchema();
  BaseModel.registerSchema<NoteSyncTrack>(schema);
  return schema;
}
