import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
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
  static const String sharedTextLabelName = 'Shared Text';
  static const String sharedFileLabelName = 'Shared File';
  static const String voiceNotesLabelName = 'Voice Notes';
  static const List<String> systemLabelNames = [
    sharedTextLabelName,
    sharedFileLabelName,
    voiceNotesLabelName,
  ];

  String name;
  bool isSystem;
  int? notesCount;
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

  static Future<List<Label>> get({bool countNotes = false}) {
    return _schema.get([countNotes]);
  }

  static Future<Label?> findById(int id) async {
    final db = AppState.db;
    final result = await db.query(model, where: "id = ?", whereArgs: [id]);
    if (result.isEmpty) return null;
    return Label.fromJson(result.first);
  }

  static Future<Label?> findByName(String name) async {
    final db = AppState.db;
    final result = await db.query(model, where: "name = ?", whereArgs: [name]);
    if (result.isEmpty) return null;
    return Label.fromJson(result.first);
  }

  /// Add missing labels and remove duplicates.
  static Future<void> fixLabels() async {
    final db = AppState.db;
    final allLabels = await db.rawQuery("SELECT labels from note");
    final existingLabels = await Label.get();
    final existingNames = existingLabels.map((l) => l.name).toSet();

    for (final labelName in systemLabelNames) {
      if (!existingNames.contains(labelName)) {
        final label = Label(name: labelName, isSystem: true);
        await label.save(sync: false);
        existingLabels.add(label);
      }
    }

    for (final row in allLabels) {
      final labelsString = row['labels'] as String?;
      if (labelsString != null && labelsString.isNotEmpty) {
        final labels = labelsString.split(',').map((l) => l.trim());
        for (final label in labels) {
          if (!existingNames.contains(label)) {
            final newLabel = Label(name: label);
            await newLabel.save(sync: false);
            existingLabels.add(newLabel);
            existingNames.add(label);
          }
        }
      }
    }

    final List<Label> originalLabels = [];

    for (final label in existingLabels) {
      if (label.name.isEmpty ||
          originalLabels.any((l) => l.name == label.name && l.id != label.id)) {
        await label.delete(sync: false);
      } else {
        originalLabels.add(label);
      }
    }

    return;
  }

  Label({
    super.id,
    required this.name,
    this.isSystem = false,
    this.createdAt,
    this.updatedAt,
  });

  factory Label.fromJson(Map<String, Object?> json) {
    return Label(
      id: json["id"] as int?,
      name: json["name"] as String,
      isSystem: (json["is_system"] as int?) == 1,
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
      "is_system": isSystem ? 1 : 0,
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

    final notes = await Note.filterByLabels([name]);
    for (final note in notes) {
      if (note.labels != null) {
        note.labels = note.labels!
            .split(',')
            .where((l) => l.trim() != name)
            .join(',');
      }
      note.save(false);
    }
    return rowsDeleted;
  }

  Label clone() {
    return Label(
      name: name,
      id: id,
      isSystem: isSystem,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Gets a system label by name, creating it if it doesn't exist.
  static Future<Label> getOrCreateSystemLabel(String name) async {
    final existingLabels = await Label.get();
    final existing = existingLabels.where((l) => l.name == name).firstOrNull;
    if (existing != null) {
      return existing;
    }
    final label = Label(name: name, isSystem: true);
    await label.save(sync: false);
    return label;
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
        is_system INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """);
  }

  @override
  Future<void> upgradeTable(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE label ADD COLUMN created_at DATETIME DEFAULT CURRENT_TIMESTAMP",
      );
      await db.execute(
        "ALTER TABLE label ADD COLUMN updated_at DATETIME DEFAULT CURRENT_TIMESTAMP",
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE label ADD COLUMN is_system INTEGER DEFAULT 0",
      );
    }
  }

  @override
  Future<List<Label>> get(List<dynamic> args) async {
    bool countNotes = args.isNotEmpty && args[0] == true;
    final db = AppState.db;
    final result = await db.query(Label.model);
    final labels = <Label>[];

    for (final row in result) {
      final label = Label.fromJson(row);
      if (countNotes) {
        label.notesCount = await Note.countByLabels([label.name]);
      }
      labels.add(label);
    }
    return labels;
  }

  @override
  Future<int> count(List<dynamic> args) async {
    final db = AppState.db;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as count FROM ${Label.model}",
    );
    if (result.isNotEmpty) {
      return result.first['count'] as int;
    }
    return 0;
  }
}
