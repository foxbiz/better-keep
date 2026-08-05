import 'dart:typed_data';

import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/state.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

class FileSyncTrack extends BaseModel<FileSyncTrack> {
  static final ModelSchema<FileSyncTrack> _schema = _createSchema();
  static const model = "file_sync_track";

  int noteId;
  String localPath;
  String? remotePath;
  String? contentHash;
  DateTime? createdAt;
  DateTime? updatedAt;

  FileSyncTrack({
    super.id,
    this.remotePath,
    this.contentHash,
    this.createdAt,
    this.updatedAt,
    required this.noteId,
    required this.localPath,
  });

  /// Computes a SHA-256 hash of the given bytes.
  static String computeHash(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  factory FileSyncTrack.fromJson(Map<String, dynamic> obj) {
    return FileSyncTrack(
      id: obj['id'],
      noteId: obj['note_id'],
      localPath: obj['local_path'],
      remotePath: obj['remote_path'],
      contentHash: obj['content_hash'] as String?,
      createdAt: obj['created_at'] != null
          ? DateTime.parse(obj['created_at'])
          : null,
      updatedAt: obj['updated_at'] != null
          ? DateTime.parse(obj['updated_at'])
          : null,
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

  Future<void> setRemotePath(String path) async {
    remotePath = path;
    await save();
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

  static Future<List<FileSyncTrack>> get({
    int? noteId,
    String? localPath,
    String? remotePath,
    int? limit,
    int? offset,
  }) async {
    final clauses = <String>[];
    final args = <dynamic>[];

    if (noteId != null) {
      clauses.add("note_id = ?");
      args.add(noteId);
    }

    if (localPath != null) {
      clauses.add("local_path = ?");
      args.add(localPath);
    }

    if (remotePath != null) {
      clauses.add("remote_path = ?");
      args.add(remotePath);
    }

    final rows = await AppState.db.query(
      model,
      where: clauses.isNotEmpty ? clauses.join(" AND ") : null,
      whereArgs: args.isNotEmpty ? args : null,
      limit: limit,
      offset: offset,
    );

    return rows.map((e) => FileSyncTrack.fromJson(e)).toList();
  }

  static Future<FileSyncTrack?> getByLocalPath(String localPath) async {
    final rows = await get(localPath: localPath, limit: 1);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  static Future<FileSyncTrack?> getByRemotePath(String remotePath) async {
    final rows = await get(remotePath: remotePath, limit: 1);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'note_id': noteId,
      'local_path': localPath,
      'remote_path': remotePath,
      'content_hash': contentHash,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}

class _FileSyncTrackSchema implements ModelSchema<FileSyncTrack> {
  @override
  Future<void> createTable(Database db) {
    return db.execute("""
      CREATE TABLE IF NOT EXISTS file_sync_track (
        id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        note_id INTEGER NOT NULL,
        remote_path TEXT,
        content_hash TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """);
  }

  @override
  Future<void> upgradeTable(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 4) {
      // Add content_hash column (added in DB version 4)
      final columns = await db.rawQuery("PRAGMA table_info('file_sync_track')");
      final hasContentHash = columns.any((c) => c['name'] == 'content_hash');
      if (!hasContentHash) {
        await db.execute(
          'ALTER TABLE file_sync_track ADD COLUMN content_hash TEXT',
        );
      }
    }
  }

  @override
  Future<List<FileSyncTrack>> get(List<dynamic> args) async {
    return [];
  }

  @override
  Future<int> count(List<dynamic> args) async {
    return 0;
  }
}

ModelSchema<FileSyncTrack> _createSchema() {
  final schema = _FileSyncTrackSchema();
  BaseModel.registerSchema<FileSyncTrack>(schema);
  return schema;
}
