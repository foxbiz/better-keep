import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/services/sync_track_store.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

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
  static const List<String> systemLabelNames = [
    sharedTextLabelName,
    sharedFileLabelName,
  ];

  String name;
  String? syncId;
  bool isSystem;
  int? notesCount;
  DateTime? createdAt;
  DateTime? updatedAt;

  String displayName(AppLocalizations l10n) {
    if (!isSystem) return name;
    return switch (name) {
      sharedTextLabelName => l10n.sharedText,
      sharedFileLabelName => l10n.sharedFile,
      _ => name,
    };
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
    final result = await db.query(
      model,
      where: "name = ?",
      whereArgs: [name],
      orderBy: 'sync_id, id',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Label.fromJson(result.first);
  }

  static Future<Label?> findBySyncId(String syncId) async {
    final result = await AppState.db.query(
      model,
      where: "sync_id = ?",
      whereArgs: [syncId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Label.fromJson(result.first);
  }

  /// Add missing labels and remove duplicates.
  static Future<void> fixLabels() async {
    final db = AppState.db;
    final existingLabels = await Label.get();
    final existingNames = existingLabels.map((l) => l.name).toSet();

    for (final labelName in systemLabelNames) {
      if (!existingNames.contains(labelName)) {
        final label = Label(name: labelName, isSystem: true);
        await label.save(sync: false);
        existingLabels.add(label);
      }
    }

    // Stable replica labels are independent entities. Legacy name repair must
    // not recreate tombstones or delete distinct remote identities by name.
    if (await SyncMutationJournal.isInstalled(db)) return;
    final allLabels = await db.rawQuery("SELECT labels from note");

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
    this.syncId,
    this.isSystem = false,
    this.createdAt,
    this.updatedAt,
  });

  factory Label.fromJson(Map<String, Object?> json) {
    return Label(
      id: json["id"] as int?,
      syncId: json["sync_id"] as String?,
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
      "sync_id": syncId,
      "name": name,
      "is_system": isSystem ? 1 : 0,
      "created_at": createdAt?.toIso8601String(),
      "updated_at": updatedAt?.toIso8601String(),
    };
  }

  Future<int> save({
    bool sync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  }) async {
    final db = AppState.db;
    syncId ??= const Uuid().v4();
    final now = DateTime.now();
    if (origin != ModelChangeOrigin.remoteSync) updatedAt = now;
    final wasNew = id == null;
    createdAt ??= now;
    final renamedAliases = <Label>[];
    final changedNotes = <int>[];
    final savedId = await db.transaction((transaction) async {
      requireCloudOperation();
      if (!wasNew && origin == ModelChangeOrigin.local) {
        final previous = await transaction.query(
          model,
          where: 'id = ?',
          whereArgs: [id],
        );
        if (previous.isNotEmpty && previous.single['name'] != name) {
          changedNotes.addAll(
            await _changeMemberships(
              transaction,
              previous.single['name'] as String,
              name,
              sync: sync,
            ),
          );
          final aliases = await transaction.query(
            model,
            where: 'name = ? AND id != ?',
            whereArgs: [previous.single['name'], id],
          );
          for (final row in aliases) {
            final alias = Label.fromJson(row)
              ..name = name
              ..updatedAt = updatedAt;
            await transaction.update(
              model,
              {'name': name, 'updated_at': updatedAt?.toIso8601String()},
              where: 'id = ?',
              whereArgs: [alias.id],
            );
            if (sync) {
              await SyncTrackStore.queueInTransaction(
                transaction: transaction,
                table: LabelSyncTrack.model,
                localId: alias.id!,
                action: LabelSyncAction.upload.name,
              );
            }
            renamedAliases.add(alias);
          }
        }
      }
      final rowId = wasNew
          ? await transaction.insert(
              model,
              toJson(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            )
          : id!;
      if (!wasNew) {
        await transaction.update(
          model,
          toJson(),
          where: 'id = ?',
          whereArgs: [rowId],
        );
      }
      if (sync) {
        await SyncTrackStore.queueInTransaction(
          transaction: transaction,
          table: LabelSyncTrack.model,
          localId: rowId,
          action: LabelSyncAction.upload.name,
        );
      }
      requireCloudOperation();
      return rowId;
    });
    requireCloudOperation();
    id = savedId;
    notifyWithOrigin(wasNew ? 'created' : 'updated', origin);
    for (final alias in renamedAliases) {
      alias.notifyWithOrigin('updated', origin);
    }
    if (sync) LabelSyncService().sync();
    await _notifyMembershipChanges(changedNotes, sync: sync, origin: origin);
    return savedId;
  }

  Future<int> delete({
    bool sync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  }) async {
    if (id == null) {
      throw ArgumentError('Cannot delete label: ID is null');
    }

    final labelId = id!;
    final changedNotes = <int>[];
    final deletedAliases = <Label>[];
    final rowsDeleted = await AppState.db.transaction((transaction) async {
      requireCloudOperation();
      final target = await transaction.query(
        model,
        where: 'id = ?',
        whereArgs: [labelId],
      );
      if (target.isEmpty) return 0;
      final currentName = target.single['name'] as String;
      final aliases = await transaction.query(
        model,
        where: origin == ModelChangeOrigin.local ? 'name = ?' : 'id = ?',
        whereArgs: [origin == ModelChangeOrigin.local ? currentName : labelId],
      );
      var count = 0;
      for (final row in aliases) {
        final alias = Label.fromJson(row);
        count += await transaction.delete(
          model,
          where: 'id = ?',
          whereArgs: [alias.id],
        );
        if (sync) {
          await SyncTrackStore.queueInTransaction(
            transaction: transaction,
            table: LabelSyncTrack.model,
            localId: alias.id!,
            action: LabelSyncAction.delete.name,
          );
        }
        deletedAliases.add(alias);
      }
      changedNotes.addAll(
        await _changeMemberships(transaction, currentName, null, sync: sync),
      );
      requireCloudOperation();
      return count;
    });
    requireCloudOperation();
    for (final alias in deletedAliases) {
      alias.notifyWithOrigin('deleted', origin);
    }
    if (sync) LabelSyncService().sync();

    await _notifyMembershipChanges(changedNotes, sync: sync, origin: origin);
    return rowsDeleted;
  }

  /// Only the originating device authors membership edits. Remote label
  /// application leaves notes to reconcile through their own revisions.
  static Future<List<int>> _changeMemberships(
    Transaction txn,
    String oldName,
    String? newName, {
    required bool sync,
  }) async {
    final changed = <int>[];
    final notes = await txn.query(Note.model, columns: ['id', 'labels']);
    final changedAt = DateTime.now().toUtc().toIso8601String();
    for (final row in notes) {
      final previous = row['labels'] as String? ?? '';
      final labels = previous.split(',');
      if (!labels.any((label) => label.trim() == oldName)) continue;
      final next = labels
          .map((label) => label.trim() == oldName ? newName : label)
          .whereType<String>()
          .toSet()
          .join(',');
      if (next == previous) continue;
      final noteId = row['id'] as int;
      await txn.update(
        Note.model,
        {'labels': next, 'updated_at': changedAt},
        where: 'id = ?',
        whereArgs: [noteId],
      );
      if (sync) {
        await SyncTrackStore.queueInTransaction(
          transaction: txn,
          table: NoteSyncTrack.model,
          localId: noteId,
          action: SyncAction.upload.name,
        );
      }
      changed.add(noteId);
    }
    return changed;
  }

  static Future<void> _notifyMembershipChanges(
    List<int> ids, {
    required bool sync,
    required ModelChangeOrigin origin,
  }) async {
    for (final noteId in ids) {
      final note = await Note.findById(noteId);
      requireCloudOperation();
      note?.notifyWithOrigin('updated', origin);
    }
    if (sync && ids.isNotEmpty) NoteSyncService().sync();
  }

  Label clone() {
    return Label(
      name: name,
      id: id,
      syncId: syncId,
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
  Future<void> createTable(Database db) async {
    await db.execute("""
      CREATE TABLE IF NOT EXISTS label (
        id INTEGER PRIMARY KEY,
        sync_id TEXT,
        name TEXT NOT NULL,
        is_system INTEGER DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """);
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_label_sync_id '
      'ON label(sync_id) WHERE sync_id IS NOT NULL',
    );
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
    if (oldVersion < 8 && newVersion >= 8) {
      final columns = await db.rawQuery('PRAGMA table_info(label)');
      if (!columns.any((column) => column['name'] == 'sync_id')) {
        await db.execute('ALTER TABLE label ADD COLUMN sync_id TEXT');
      }
    }
  }

  @override
  Future<List<Label>> get(List<dynamic> args) async {
    bool countNotes = args.isNotEmpty && args[0] == true;
    final db = AppState.db;
    // Separate stable IDs can share a user-facing name after offline creation.
    // Keep both replicas, while presenting one deterministic folder identity.
    final result = await db.query(Label.model, orderBy: 'id');
    final byName = <String, Label>{};
    for (final row in result) {
      final label = Label.fromJson(row);
      final existing = byName[label.name];
      if (existing == null ||
          (label.syncId ?? '').compareTo(existing.syncId ?? '') < 0) {
        byName[label.name] = label;
      }
    }
    final labels = byName.values.toList();
    for (final label in labels) {
      if (countNotes) {
        label.notesCount = await Note.countByLabels([label.name]);
      }
    }
    return labels;
  }

  @override
  Future<int> count(List<dynamic> args) async {
    final db = AppState.db;
    final result = await db.rawQuery(
      "SELECT COUNT(DISTINCT name) as count FROM ${Label.model}",
    );
    if (result.isNotEmpty) {
      return result.first['count'] as int;
    }
    return 0;
  }
}
