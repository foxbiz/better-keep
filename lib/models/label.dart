import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:sqflite/sqflite.dart';

typedef LabelEvent = ModelEvent<Label>;
typedef LabelListener = ModelListener<Label>;

extension LabelEventData on LabelEvent {
  Label get label => payload;
}

class Label extends BaseModel<Label> {
  static final ModelSchema<Label> _schema = _createSchema();
  static const model = "label";

  String name;
  DateTime? createdAt;
  DateTime? updatedAt;

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

  static Future<List<Label>> get() {
    return _schema.get([]);
  }

  static Future<Label?> findById(int id) async {
    final db = AppState.db;
    final result = await db.query(model, where: "id = ?", whereArgs: [id]);
    if (result.isEmpty) return null;
    return Label.fromJson(result.first);
  }

  Label({super.id, required this.name, this.createdAt, this.updatedAt});

  factory Label.fromJson(Map<String, Object?> json) {
    return Label(
      id: json["id"] as int?,
      name: json["name"] as String,
      createdAt: json["created_at"] != null
          ? DateTime.parse(json["created_at"] as String)
          : null,
      updatedAt: json["updated_at"] != null
          ? DateTime.parse(json["updated_at"] as String)
          : null,
    );
  }

  Map<String, Object?> toJson() {
    return {
      "id": id,
      "name": name,
      "created_at": createdAt?.toIso8601String(),
      "updated_at": updatedAt?.toIso8601String(),
    };
  }

  Future<int> save({bool sync = true}) async {
    final db = AppState.db;
    updatedAt = DateTime.now();

    if (id == null) {
      createdAt = DateTime.now();
      final rowId = await db.insert(
        model,
        toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      id = rowId;
      notify("created");
      if (sync) {
        LabelSyncService().queueSync(this);
      }
      return rowId;
    }

    await db.update(model, toJson(), where: "id = ?", whereArgs: [id]);
    notify("updated");
    if (sync) {
      LabelSyncService().queueSync(this);
    }
    return id!;
  }

  Future<int> delete({bool sync = true}) async {
    if (id == null) {
      throw ArgumentError('Cannot delete label: ID is null');
    }

    final labelId = id!;
    final rowsDeleted = await AppState.db.delete(
      model,
      where: "id = ?",
      whereArgs: [id],
    );
    notify("deleted");
    if (sync) {
      LabelSyncService().queueDelete(labelId);
    }
    return rowsDeleted;
  }

  Label clone() {
    return Label(
      name: name,
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static void on(String event, LabelListener callback) {
    BaseModel.on<Label>(event, callback);
  }

  static void off(String event, LabelListener callback) {
    BaseModel.off<Label>(event, callback);
  }

  static void once(String event, LabelListener callback) {
    BaseModel.once<Label>(event, callback);
  }
}

ModelSchema<Label> _createSchema() {
  final schema = _LabelSchema();
  BaseModel.registerSchema<Label>(schema);
  return schema;
}

class _LabelSchema implements ModelSchema<Label> {
  @override
  Future<void> createTable(Database db) {
    return db.execute("""
      CREATE TABLE IF NOT EXISTS label (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """);
  }

  @override
  Future<void> upgradeTable(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add created_at and updated_at columns
      await db.execute(
        "ALTER TABLE label ADD COLUMN created_at DATETIME DEFAULT CURRENT_TIMESTAMP",
      );
      await db.execute(
        "ALTER TABLE label ADD COLUMN updated_at DATETIME DEFAULT CURRENT_TIMESTAMP",
      );
    }
  }

  @override
  Future<List<Label>> get(List<dynamic> args) async {
    final db = AppState.db;
    final result = await db.query(Label.model);
    return result.map(Label.fromJson).toList();
  }
}
