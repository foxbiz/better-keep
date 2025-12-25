import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/all_day_reminder_notification_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

typedef NoteEvent = ModelEvent<Note>;
typedef NoteListener = ModelListener<Note>;

/// Exception thrown when a note cannot be unlocked
class NoteUnlockException implements Exception {
  final String message;
  const NoteUnlockException(this.message);

  @override
  String toString() => message;
}

extension NoteEventData on NoteEvent {
  Note get note => payload;
}

enum NoteType { all, archived, trashed, pinned, locked, reminder }

class Note extends BaseModel<Note> {
  static final ModelSchema<Note> _schema = _createSchema();
  static const model = "note";

  bool locked;
  bool pinned;
  Color color;
  bool trashed;
  bool archived;
  bool readOnly;
  String? title;
  bool completed;
  String? labels;
  String? content;
  String? password;
  String? plainText;
  Reminder? reminder;
  DateTime? createdAt;
  DateTime? updatedAt;
  List<NoteAttachment> attachments;

  bool unlocked = false;

  // Cached checkbox count to avoid repeated JSON parsing
  ({int total, int checked})? _cachedCheckboxCount;
  String? _lastContentForCheckbox;

  /// Returns the count of all checkboxes and checked checkboxes in the note content
  ({int total, int checked}) get checkboxCount {
    if (content == null || content!.isEmpty) {
      return (total: 0, checked: 0);
    }

    // Return cached result if content hasn't changed
    if (_cachedCheckboxCount != null && _lastContentForCheckbox == content) {
      return _cachedCheckboxCount!;
    }

    try {
      final parsed = json.decode(content!) as List;
      int total = 0;
      int checked = 0;

      for (final item in parsed) {
        if (item is Map<String, dynamic>) {
          final attributes = item['attributes'];
          if (attributes is Map<String, dynamic>) {
            // Check for unchecked checkbox (list: "unchecked")
            if (attributes['list'] == 'unchecked') {
              total++;
            }
            // Check for checked checkbox (list: "checked")
            else if (attributes['list'] == 'checked') {
              total++;
              checked++;
            }
          }
        }
      }

      _cachedCheckboxCount = (total: total, checked: checked);
      _lastContentForCheckbox = content;
      return _cachedCheckboxCount!;
    } catch (e) {
      return (total: 0, checked: 0);
    }
  }

  /// Returns true if the note has any checkboxes
  bool get hasCheckboxes => checkboxCount.total > 0;

  /// Returns the progress of checked checkboxes (0.0 to 1.0)
  double get checkboxProgress {
    final count = checkboxCount;
    if (count.total == 0) return 0.0;
    return count.checked / count.total;
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

  static Future<List<Note>> get(
    NoteType type, [
    List<String>? filterLabels,
    String? searchQuery,
  ]) {
    return _schema.get([type, filterLabels, searchQuery]);
  }

  String get body {
    if (locked) {
      return 'Locked note reminder';
    } else if (content != null) {
      var plainText = document?.toPlainText() ?? '';
      if (plainText.length > 240) {
        plainText = '${plainText.substring(0, 240)}...';
      }
      return plainText;
    } else {
      return 'Better Keep Notes reminder';
    }
  }

  bool get hasReminder {
    return reminder != null;
  }

  bool get hasReminderExpired {
    if (reminder == null) {
      return false;
    }

    // For "All Day" reminders, consider expired only after the day ends (next day)
    if (reminder!.isAllDay) {
      final now = DateTime.now();
      final reminderDate = reminder!.dateTime;
      // Compare dates only - expired if reminder date is before today
      final today = DateTime(now.year, now.month, now.day);
      final reminderDay = DateTime(
        reminderDate.year,
        reminderDate.month,
        reminderDate.day,
      );
      return reminderDay.isBefore(today);
    }

    return reminder!.dateTime.isBefore(DateTime.now());
  }

  /// Check if this note has an active "All Day" reminder for today
  bool get isAllDayReminderActive {
    if (reminder == null || !reminder!.isAllDay || completed) {
      return false;
    }
    final now = DateTime.now();
    final reminderDate = reminder!.dateTime;
    return reminderDate.year == now.year &&
        reminderDate.month == now.month &&
        reminderDate.day == now.day;
  }

  Document? get document {
    if (content == null || content!.isEmpty) {
      return null;
    }

    // Skip if content is locally encrypted (shouldn't happen but handle defensively)
    if (content!.startsWith('ENC:')) {
      AppLogger.log(
        'Warning: Note $id has encrypted content in document getter',
      );
      return null;
    }

    try {
      var parsed = json.decode(content!) as List;
      if (parsed.length >= 2 && parsed[1]["attributes"]?["header"] == 1) {
        parsed = parsed.sublist(2);
      }

      if (parsed.isEmpty) {
        return null;
      }

      return Document.fromJson(parsed);
    } catch (e) {
      // Log parse errors to help debug corrupted content
      AppLogger.error('Warning: Failed to parse note document (id=$id)', e);
      return null;
    }
  }

  bool get isEmpty {
    final hasTitle = title != null && title!.trim().isNotEmpty;
    final hasContent = plainText != null && plainText!.trim().isNotEmpty;
    return !hasTitle && !hasContent && attachments.isEmpty;
  }

  List<NoteImage> get images {
    return List.unmodifiable(
      attachments
          .where((attachment) => attachment.type == AttachmentType.image)
          .map((attachment) => attachment.image!),
    );
  }

  List<SketchData> get sketches {
    return List.unmodifiable(
      attachments
          .where((attachment) => attachment.type == AttachmentType.sketch)
          .map((attachment) => attachment.sketch!),
    );
  }

  /// Returns audio recordings attached to this note
  List<NoteRecording> get recordings {
    return List.unmodifiable(
      attachments
          .where((attachment) => attachment.type == AttachmentType.audio)
          .map((attachment) => attachment.recording!),
    );
  }

  Future<NoteSyncTrack?> get syncTrack async {
    if (id == null) {
      return null;
    }

    return await NoteSyncTrack.getByLocalId(id!) ??
        NoteSyncTrack(localId: id!, action: SyncAction.upload);
  }

  Note({
    super.id,
    this.title,
    this.labels,
    this.content,
    this.reminder,
    this.plainText,
    this.createdAt,
    this.updatedAt,
    this.locked = false,
    this.pinned = false,
    this.trashed = false,
    this.archived = false,
    this.readOnly = false,
    this.completed = false,
    this.color = Colors.transparent,
    List<NoteAttachment>? attachments,
  }) : attachments = attachments ?? [];

  factory Note.fromJson(Map<String, dynamic> obj) {
    final locked = (obj['locked'] == 1 || obj['locked'] == true) ? true : false;

    int colorValue =
        0; // Default to transparent/black (0) or some other default
    if (obj['color'] != null) {
      if (obj['color'] is int) {
        colorValue = obj['color'];
      } else {
        colorValue = int.tryParse(obj['color'].toString()) ?? 0;
      }
    }

    return Note(
      locked: locked,
      id: obj['id'] ?? -1,
      title: obj['title'] ?? '',
      labels: obj['labels'] ?? '',
      content: obj['content'] ?? '',
      plainText: obj['plain_text'] ?? '',
      attachments: obj['attachments'] != null
          ? (json.decode(obj['attachments']) as List)
                .map((e) => NoteAttachment.fromJson(e))
                .toList()
          : [],
      completed: (obj['completed'] == 1 || obj['completed'] == true)
          ? true
          : false,
      reminder: obj['reminder'] != null
          ? (obj['reminder'] is String
                ? Reminder.fromJson(json.decode(obj['reminder']))
                : null)
          : null,
      createdAt: obj['created_at'] is Timestamp
          ? (obj['created_at'] as Timestamp).toDate()
          : DateTime.tryParse(
                  obj['created_at']?.toString() ??
                      DateTime.now().toIso8601String(),
                ) ??
                DateTime.now(),
      updatedAt: obj['updated_at'] is Timestamp
          ? (obj['updated_at'] as Timestamp).toDate()
          : DateTime.tryParse(
                  obj['updated_at']?.toString() ??
                      DateTime.now().toIso8601String(),
                ) ??
                DateTime.now(),
      archived: (obj['archived'] == 1 || obj['archived'] == true)
          ? true
          : false,
      trashed: (obj['trashed'] == 1 || obj['trashed'] == true) ? true : false,
      readOnly: (obj['read_only'] == 1 || obj['read_only'] == true)
          ? true
          : false,
      pinned: (obj['pinned'] == 1 || obj['pinned'] == true) ? true : false,
      color: Color(colorValue),
    );
  }

  /// Creates a Note from JSON with decryption of locally encrypted fields.
  /// Use this when loading notes from the local database.
  static Future<Note> fromJsonAsync(Map<String, dynamic> obj) async {
    final note = Note.fromJson(obj);
    await note.decryptFields();
    return note;
  }

  /// Decrypts locally encrypted fields (content).
  /// Title and plainText are not encrypted to preserve search functionality.
  /// Called automatically when loading notes from the database.
  Future<void> decryptFields() async {
    final localEncryption = LocalDataEncryption.instance;

    // Decrypt content only
    if (content != null && content!.isNotEmpty) {
      content = await localEncryption.decryptString(content!);
    }
  }

  @override
  void notify(String event, [bool trackSync = true]) async {
    super.notify(event);

    if (!trackSync) return;

    if (id == null) {
      AppLogger.log(
        "Cannot create SyncTrack for note without ID while notifying $event",
      );
      return;
    }

    final action = switch (event) {
      "created" => SyncAction.upload,
      "updated" => SyncAction.upload,
      "deleted" => SyncAction.delete,
      _ => null,
    };

    if (action == null) {
      return;
    }

    final track =
        await syncTrack ?? NoteSyncTrack(localId: id!, action: action);
    await track.setAction(action);
    NoteSyncService().sync();
  }

  Future<void> unlock() async {
    if (!locked || unlocked) {
      return;
    }

    if (password == null || password!.isEmpty) {
      throw const NoteUnlockException(
        'Cannot unlock a locked note without a PIN',
      );
    }

    try {
      final decryptedContent = await decrypt(content ?? '', password!);
      if (decryptedContent.isEmpty && content != null && content!.isNotEmpty) {
        throw const NoteUnlockException('Decryption produced empty content');
      }

      unlocked = true;
      content = decryptedContent;
    } on FormatException {
      throw const NoteUnlockException('Incorrect PIN or corrupted note data');
    } catch (e) {
      throw NoteUnlockException('Failed to unlock note: $e');
    }
  }

  void addImage(NoteImage image) async {
    if (hasImage(image)) {
      return;
    }

    attachments.add(NoteAttachment.image(image));
    await save();
  }

  /// Add an image directly without saving (for batch operations)
  void addImageDirectly(NoteImage image) {
    if (hasImage(image)) {
      return;
    }
    attachments.add(NoteAttachment.image(image));
  }

  /// Add an attachment directly without saving (for batch operations)
  void addAttachmentDirectly(NoteAttachment attachment) {
    attachments.add(attachment);
  }

  bool hasImage(NoteImage image) {
    return attachments.any(
      (attachment) =>
          attachment.type == AttachmentType.image && attachment.image == image,
    );
  }

  Future<NoteAttachment> removeImage(NoteImage image) async {
    if (!hasImage(image)) {
      throw Exception("Image not found in note attachments");
    }

    final removed = attachments.firstWhere(
      (attachment) =>
          attachment.type == AttachmentType.image && attachment.image == image,
    );
    attachments.remove(removed);
    await save();
    return removed;
  }

  void addSketch(SketchData sketch) async {
    if (hasSketch(sketch)) {
      return;
    }

    String previewImageSrc = sketch.previewImage ?? '';

    if (previewImageSrc.isEmpty) {
      snackbar("Error saving sketch, no preview available", Colors.red);
      AppLogger.error('Error adding sketch to note: no preview image');
      return;
    }

    attachments.add(NoteAttachment.sketch(sketch));
    await save();
  }

  bool hasSketch(SketchData sketch) {
    return attachments.any(
      (attachment) =>
          attachment.type == AttachmentType.sketch &&
          attachment.sketch == sketch,
    );
  }

  Future<NoteAttachment> removeSketch(SketchData sketch) async {
    if (!hasSketch(sketch)) {
      throw Exception("Sketch not found in note attachments");
    }

    final removed = attachments.firstWhere(
      (attachment) =>
          attachment.type == AttachmentType.sketch &&
          attachment.sketch == sketch,
    );
    attachments.remove(removed);
    await save();
    return removed;
  }

  void addRecording(NoteRecording recording) async {
    if (hasRecording(recording.src)) {
      return;
    }

    attachments.add(NoteAttachment.audio(recording));
    await save();
  }

  Future<void> updateRecording(NoteRecording recording) async {
    final index = attachments.indexWhere(
      (attachment) =>
          attachment.type == AttachmentType.audio &&
          attachment.recording!.src == recording.src,
    );
    if (index != -1) {
      attachments[index].recording = recording;
      await save();
    }
  }

  bool hasRecording(String src) {
    return attachments.any(
      (attachment) =>
          attachment.type == AttachmentType.audio &&
          attachment.recording!.src == src,
    );
  }

  Future<NoteAttachment> removeRecording(String src) async {
    if (!hasRecording(src)) {
      throw Exception("Audio recording not found in note attachments");
    }

    final removed = attachments.firstWhere(
      (attachment) =>
          attachment.type == AttachmentType.audio &&
          attachment.recording!.src == src,
    );
    attachments.remove(removed);
    await save();
    return removed;
  }

  Future<int> done() async {
    if (id != null && isAlarmSupported) {
      final alarmId = await AlarmIdService.getAlarmId(id!);
      await Alarm.stop(alarmId);
      await AllDayReminderNotificationService().cancelNotification(id!);
    }

    // Check if this is a repeating reminder
    if (reminder != null && reminder!.isRepeating) {
      // Schedule the next occurrence
      final nextReminder = reminder!.getNextOccurrence();
      if (nextReminder != null) {
        reminder = nextReminder;
        completed = false; // Keep it active for repeating reminders
        final rowId = await save();
        await setAlarm(); // Schedule the next alarm
        return rowId;
      }
    }

    // Non-repeating reminder: mark as completed
    completed = true;
    return await save();
  }

  /// Delete the reminder from this note entirely
  Future<int> deleteReminder() async {
    // Cancel alarm/notification in background - don't block UI
    if (id != null && isAlarmSupported) {
      final noteId = id!;
      unawaited(
        Future(() async {
          try {
            final alarmId = await AlarmIdService.getAlarmId(noteId);
            await Alarm.stop(alarmId);
            await AllDayReminderNotificationService().cancelNotification(
              noteId,
            );
          } catch (e) {
            AppLogger.log("Error cancelling alarm/notification: $e");
          }
        }),
      );
    }

    reminder = null;
    completed = false;
    return save();
  }

  Future<int> setContent(String newContent, String newPlainText) {
    content = newContent;
    plainText = newPlainText;
    unlocked = true;
    return save();
  }

  Future<int> setReminder(Reminder newReminder) async {
    // Cancel any existing all-day notification before updating
    if (id != null) {
      await AllDayReminderNotificationService().cancelNotification(id!);
    }

    reminder = newReminder;
    completed = false;
    final rowId = await save();
    unawaited(_scheduleReminderAlarm());
    return rowId;
  }

  Future<void> _scheduleReminderAlarm() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return;
    }
    try {
      await setAlarm();
      // Show persistent notification for all-day reminders that are active today
      if (reminder != null && reminder!.isAllDay && isAllDayReminderActive) {
        await AllDayReminderNotificationService().showAllDayNotification(this);
      }
      snackbar("Reminder set", Colors.green[400]);
    } catch (e) {
      snackbar(e.toString(), Colors.red);
    }
  }

  Future<void> setAlarm() async {
    if (!isAlarmSupported) {
      return;
    }

    if (id == null || reminder == null) {
      return;
    }

    // Skip alarm for "All Day" reminders - they use visual highlight instead
    if (reminder!.isAllDay) {
      return;
    }

    final alarmId = await AlarmIdService.getAlarmId(id!);

    await Alarm.stop(alarmId);
    await Alarm.set(
      alarmSettings: AlarmSettings(
        id: alarmId,
        dateTime: reminder!.dateTime,
        assetAudioPath: AppState.alarmSound,
        loopAudio: true,
        vibrate: true,
        androidFullScreenIntent: true,
        volumeSettings: VolumeSettings.fade(
          volume: 1,
          fadeDuration: Duration(seconds: 3),
        ),
        notificationSettings: NotificationSettings(
          title: title ?? 'Note reminder',
          body: body,
          iconColor: color,
          stopButton: 'Mark as done',
        ),
        payload: id?.toString(),
      ),
    );
  }

  Future<int> save([bool trackSync = true]) async {
    if (isEmpty) {
      return Future.value(-1);
    }

    // Only update timestamp for local changes, not when syncing from remote
    if (trackSync) {
      updatedAt = DateTime.now();
    }

    var jsonObj = await toJsonAsync();

    if (id != null) {
      // Check if record exists
      final count = Sqflite.firstIntValue(
        await AppState.db.rawQuery('SELECT COUNT(*) FROM note WHERE id = ?', [
          id,
        ]),
      );

      if (count != null && count > 0) {
        try {
          await AppState.db.update(
            model,
            jsonObj,
            where: "id = ?",
            whereArgs: [id],
          );
          notify("updated", trackSync);
          return id!;
        } catch (e) {
          AppLogger.log("Error updating note: $e");
          snackbar("Failed to save the note", Colors.red);
          return -1;
        }
      }
      // If not exists, fall through to insert with the existing ID
    } else {
      id = DateTime.now().millisecondsSinceEpoch;
    }

    jsonObj['id'] = id;
    if (jsonObj['created_at'] == null) {
      jsonObj['created_at'] = DateTime.now().toIso8601String();
    }

    try {
      await AppState.db.insert(model, jsonObj);
      notify("created", trackSync);
      return id!;
    } catch (e) {
      snackbar("Failed to save the note", Colors.red);
      AppLogger.log("Error saving note: $e");
      id = null;
      return -1;
    }
  }

  Future<void> moveToTrash() async {
    trashed = true;
    archived = false;
    pinned = false;
    readOnly = true;
    await save();
  }

  Future<void> restoreFromTrash() async {
    trashed = false;
    readOnly = false;
    await save();
  }

  Future<void> _deleteLocalFiles() async {
    try {
      final fs = await fileSystem();
      for (final attachment in attachments) {
        final List<String> files = [];

        switch (attachment.type) {
          case AttachmentType.image:
            files.add(attachment.image!.src);
            break;
          case AttachmentType.sketch:
            if (attachment.sketch!.backgroundImage != null) {
              files.add(attachment.sketch!.backgroundImage!);
            }
            if (attachment.sketch!.previewImage != null) {
              files.add(attachment.sketch!.previewImage!);
            }
            break;
          case AttachmentType.audio:
            files.add(attachment.recording!.src);
            break;
        }

        for (final file in files) {
          if (await fs.exists(file)) {
            await fs.delete(file);
          }
        }
      }
    } catch (e) {
      AppLogger.log("Error deleting local files: $e");
    }
  }

  Future<int> delete() async {
    // If id is null, the note was never saved - nothing to delete
    if (id == null) {
      return 0;
    }

    if (isAlarmSupported) {
      final alarmId = await AlarmIdService.getAlarmId(id!);
      await Alarm.stop(alarmId);
      await AlarmIdService.removeAlarmId(id!);
    }

    int result = await AppState.db.delete(
      model,
      where: "id = ?",
      whereArgs: [id],
    );
    await _deleteLocalFiles();
    notify("deleted");
    return result;
  }

  /// Prepares and returns JSON for saving to database.
  /// Handles encryption of locked notes asynchronously.
  Future<Map<String, dynamic>> toJsonAsync() async {
    // Prepare content for saving
    String? contentToSave = content;
    String? plainTextToSave = plainText;

    // Encrypt content if note is locked and was unlocked for editing
    if (locked && unlocked) {
      if (password == null || password!.isEmpty) {
        // Reset unlocked state if no password - prevents data loss
        unlocked = false;
        AppLogger.log(
          'Warning: Locked note without password, keeping existing content',
        );
      } else {
        try {
          contentToSave = await encrypt(content ?? '', password!);
          unlocked = false;
          content = contentToSave; // Update instance state
        } catch (e) {
          AppLogger.log('Error encrypting note content: $e');
          // Keep existing content rather than losing data
          unlocked = false;
        }
      }
    }

    if (!locked) {
      try {
        plainTextToSave = document?.toPlainText() ?? '';
        plainText = plainTextToSave;
      } catch (e) {
        plainTextToSave = '';
      }
    } else {
      plainTextToSave = '';
    }

    // Apply local data encryption to content only
    // Title and plainText are kept unencrypted for search functionality
    final localEncryption = LocalDataEncryption.instance;
    final contentEncrypted = await localEncryption.encryptString(
      contentToSave ?? '',
    );

    return {
      'id': id,
      'title': title,
      'labels': labels,
      'content': contentEncrypted,
      'plain_text': plainTextToSave,
      'locked': locked ? 1 : 0,
      'pinned': pinned ? 1 : 0,
      'trashed': trashed ? 1 : 0,
      'archived': archived ? 1 : 0,
      'read_only': readOnly ? 1 : 0,
      'completed': completed ? 1 : 0,
      'color': color.toARGB32().toString(),
      'updated_at': updatedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'attachments': json.encode(attachments.map((a) => a.toJson()).toList()),
      'reminder': reminder != null ? json.encode(reminder!.toJson()) : null,
    };
  }

  /// Returns JSON representation of the note for display/serialization.
  /// NOTE: This does not encrypt locked notes. Use [toJsonAsync] for saving.
  Map<String, dynamic> toJson() {
    final plainTextValue = locked ? '' : (document?.toPlainText() ?? '');

    return {
      'id': id,
      'title': title,
      'labels': labels,
      'content': content,
      'plain_text': plainTextValue,
      'locked': locked ? 1 : 0,
      'pinned': pinned ? 1 : 0,
      'trashed': trashed ? 1 : 0,
      'archived': archived ? 1 : 0,
      'read_only': readOnly ? 1 : 0,
      'completed': completed ? 1 : 0,
      'color': color.toARGB32().toString(),
      'updated_at': updatedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'attachments': json.encode(attachments.map((a) => a.toJson()).toList()),
      'reminder': reminder != null ? json.encode(reminder!.toJson()) : null,
    };
  }

  static void on(String event, NoteListener callback) {
    BaseModel.on<Note>(event, callback);
  }

  static void off(String event, NoteListener callback) {
    BaseModel.off<Note>(event, callback);
  }

  static void once(String event, NoteListener callback) {
    BaseModel.once<Note>(event, callback);
  }

  static Future<Note?> findById(int noteId) async {
    final rows = await AppState.db.query(
      model,
      where: "id = ?",
      whereArgs: [noteId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return Note.fromJsonAsync(rows.first);
  }
}

ModelSchema<Note> _createSchema() {
  final schema = _NoteSchema();
  BaseModel.registerSchema<Note>(schema);
  return schema;
}

class _NoteSchema implements ModelSchema<Note> {
  @override
  Future<void> createTable(Database db) {
    return db.execute("""
      CREATE TABLE IF NOT EXISTS note (
        id INTEGER PRIMARY KEY,
        title TEXT,
        color TEXT,
        content TEXT,
        reminder TEXT,
        remote_id TEXT,
        labels TEXT DEFAULT "",
        locked INTEGER DEFAULT 0,
        pinned INTEGER DEFAULT 0,
        trashed INTEGER DEFAULT 0,
        plain_text TEXT DEFAULT "",
        archived INTEGER DEFAULT 0,
        read_only INTEGER DEFAULT 0,
        completed INTEGER DEFAULT 0,
        attachments TEXT DEFAULT '[]',
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
  Future<List<Note>> get(List<dynamic> args) async {
    NoteType filter = args.isNotEmpty ? args[0] as NoteType : NoteType.all;
    List<String>? filterLabels = args.length > 1
        ? args[1] as List<String>?
        : null;
    String? searchQuery = args.length > 2 ? args[2] as String? : null;

    List<String> whereClauses = [
      switch (filter) {
        NoteType.archived => "archived = 1",
        NoteType.locked => "locked = 1",
        NoteType.pinned => "pinned = 1",
        NoteType.trashed => "trashed = 1",
        NoteType.reminder =>
          // Show all reminders including completed repeating ones (Daily, Weekly, Monthly, Yearly)
          "reminder IS NOT NULL AND trashed = 0 AND (completed = 0 OR reminder LIKE '%Daily%' OR reminder LIKE '%Weekly%' OR reminder LIKE '%Monthly%' OR reminder LIKE '%Yearly%')",
        _ => "trashed = 0 AND archived = 0",
      },
    ];

    List<String> searchArgs = [];
    if (searchQuery != null && searchQuery.isNotEmpty) {
      // Escape special characters and use parameterized query to prevent SQL injection
      final sanitizedQuery = searchQuery
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      whereClauses.add(
        "(title LIKE ? ESCAPE '\\' OR plain_text LIKE ? ESCAPE '\\')",
      );
      searchArgs.add('%$sanitizedQuery%');
      searchArgs.add('%$sanitizedQuery%');
    }

    if (filterLabels == null || filterLabels.isEmpty) {
      final rows = await AppState.db.query(
        Note.model,
        orderBy: "pinned DESC, updated_at DESC",
        where: whereClauses.join(" AND "),
        whereArgs: searchArgs.isNotEmpty ? searchArgs : null,
      );
      final notes = await Future.wait(rows.map(Note.fromJsonAsync));
      return notes;
    }

    final placeholders = List.filled(filterLabels.length, '?').join(', ');
    final sql =
        '''
WITH RECURSIVE splitter(id, part, rest) AS (
  SELECT
    id,
    TRIM(SUBSTR(
      labels,
      1,
      CASE INSTR(labels, ',')
        WHEN 0 THEN LENGTH(labels)
        ELSE INSTR(labels, ',') - 1
      END
    )) AS part,
    TRIM(CASE INSTR(labels, ',')
      WHEN 0 THEN ''
      ELSE SUBSTR(labels, INSTR(labels, ',') + 1)
    END) AS rest
  FROM note
  WHERE labels IS NOT NULL AND labels <> ''
  UNION ALL
  SELECT
    id,
    TRIM(SUBSTR(
      rest,
      1,
      CASE INSTR(rest, ',')
        WHEN 0 THEN LENGTH(rest)
        ELSE INSTR(rest, ',') - 1
      END
    )) AS part,
    TRIM(CASE INSTR(rest, ',')
      WHEN 0 THEN ''
      ELSE SUBSTR(rest, INSTR(rest, ',') + 1)
    END) AS rest
  FROM splitter
  WHERE rest <> ''
)
SELECT DISTINCT n.*
FROM note n
JOIN splitter s ON s.id = n.id
WHERE ${whereClauses.join(" AND ")}
  AND s.part IN ($placeholders)
ORDER BY n.pinned DESC, n.updated_at DESC;
''';
    final rows = await AppState.db.rawQuery(sql, [
      ...searchArgs,
      ...filterLabels,
    ]);
    final notes = await Future.wait(rows.map(Note.fromJsonAsync));
    return notes;
  }
}
