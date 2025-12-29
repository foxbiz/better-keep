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
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
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

  bool _locked;
  bool pinned;
  Color color;
  bool trashed;
  bool archived;
  bool readOnly;
  String? title;
  bool completed;
  String? labels;
  String? content;
  String? _password;
  String? plainText;
  Reminder? reminder;
  DateTime? createdAt;
  DateTime? updatedAt;
  List<NoteAttachment> attachments;

  bool _unlocked = false;

  /// Raw encrypted attachments string for async decryption.
  /// Set when attachments are encrypted and need to be decrypted in decryptFields().
  String? _rawEncryptedAttachments;

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

  bool get locked => _locked;
  bool get unlocked => _unlocked;
  String? get password => _password;

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
    if (_locked) {
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
    bool locked = false,
    this.pinned = false,
    this.trashed = false,
    this.archived = false,
    this.readOnly = false,
    this.completed = false,
    this.color = Colors.transparent,
    List<NoteAttachment>? attachments,
  }) : _locked = locked,
       attachments = attachments ?? [];

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

    // Parse attachments - handle both encrypted and unencrypted formats
    // If encrypted, store raw string for async decryption later
    List<NoteAttachment> parsedAttachments = [];
    String? rawAttachmentsStr;
    if (obj['attachments'] != null) {
      final attachmentsData = obj['attachments'];
      if (attachmentsData is String) {
        // Check if it's encrypted (starts with ENC: marker)
        if (LocalDataEncryption.isEncrypted(attachmentsData)) {
          // Store raw string for async decryption in decryptFields()
          rawAttachmentsStr = attachmentsData;
        } else {
          // Try to parse as JSON
          try {
            parsedAttachments = (json.decode(attachmentsData) as List)
                .map((e) => NoteAttachment.fromJson(e))
                .toList();
          } catch (e) {
            AppLogger.error('Error parsing attachments in fromJson', e);
          }
        }
      } else if (attachmentsData is List) {
        // Already a list (from sync)
        parsedAttachments = attachmentsData
            .map((e) => NoteAttachment.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    }

    final note = Note(
      locked: locked,
      id: obj['id'] ?? -1,
      title: obj['title'] ?? '',
      labels: obj['labels'] ?? '',
      content: obj['content'] ?? '',
      plainText: obj['plain_text'] ?? '',
      attachments: parsedAttachments,
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

    // Store raw encrypted attachments string for async decryption
    if (rawAttachmentsStr != null) {
      note._rawEncryptedAttachments = rawAttachmentsStr;
    }

    return note;
  }

  Future<Note> updateFromJson(Map<String, dynamic> obj) async {
    pinned = obj['pinned'] == 1;
    _locked = obj['locked'] == 1;
    trashed = obj['trashed'] == 1;
    archived = obj['archived'] == 1;
    readOnly = obj['read_only'] == 1;
    completed = obj['completed'] == 1;
    title = obj['title'] as String?;
    labels = obj['labels'] as String?;
    final colorValue = obj['color'];
    if (colorValue != null) {
      color = Color(int.tryParse(colorValue.toString()) ?? 0xFFFFFFFF);
    }
    content = obj['content'] as String?;
    plainText = obj['plain_text'] as String?;

    if (obj['updated_at'] != null) {
      updatedAt = DateTime.parse(obj['updated_at'] as String);
    } else {
      updatedAt = DateTime.now();
    }

    if (obj['reminder'] != null) {
      final reminderData = obj['reminder'];
      if (reminderData is String) {
        reminder = Reminder.fromJson(
          jsonDecode(reminderData) as Map<String, Object?>,
        );
      } else if (reminderData is Map) {
        reminder = Reminder.fromJson(Map<String, Object?>.from(reminderData));
      }
      // Only set alarm if the reminder is not completed
      if (!completed) {
        setAlarm();
      }
    }

    // Handle attachments - can be List<NoteAttachment>, JSON string, or List<dynamic>
    if (obj['attachments'] != null) {
      final attachmentsData = obj['attachments'];
      if (attachmentsData is List<NoteAttachment>) {
        // Already parsed NoteAttachment objects (from sync service)
        attachments = attachmentsData;
      } else if (attachmentsData is String) {
        // JSON string from database
        attachments = (json.decode(attachmentsData) as List)
            .map((e) => NoteAttachment.fromJson(e as Map<String, dynamic>))
            .toList();
      } else if (attachmentsData is List) {
        // List of maps (from Firebase)
        attachments = attachmentsData
            .map((e) => NoteAttachment.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    }

    // Pass false to prevent triggering a sync back to Firebase
    // This method is called when syncing FROM remote, not for local changes
    await save(false);
    return this;
  }

  /// Creates a Note from JSON with decryption of locally encrypted fields.
  /// Use this when loading notes from the local database.
  static Future<Note> fromJsonAsync(Map<String, dynamic> obj) async {
    final note = Note.fromJson(obj);
    await note.decryptFields();
    return note;
  }

  /// Decrypts locally encrypted fields (content and attachments).
  /// Title and plainText are not encrypted to preserve search functionality.
  /// Called automatically when loading notes from the database.
  Future<void> decryptFields() async {
    final localEncryption = LocalDataEncryption.instance;

    // Decrypt content
    if (content != null && content!.isNotEmpty) {
      content = await localEncryption.decryptString(content!);
    }

    // Decrypt attachments if they were encrypted as whole blob (legacy format)
    // This handles backward compatibility - old attachments were not encrypted
    if (_rawEncryptedAttachments != null) {
      try {
        final decryptedStr = await localEncryption.decryptString(
          _rawEncryptedAttachments!,
        );
        final List attachmentList = json.decode(decryptedStr);
        attachments = attachmentList
            .map((a) => NoteAttachment.fromJson(a as Map<String, dynamic>))
            .toList();
        _rawEncryptedAttachments = null; // Clear after successful decryption
      } catch (e) {
        AppLogger.error('Error decrypting attachments', e);
      }
    }

    // Decrypt sketch metadata within attachments (files encryption toggle)
    for (final attachment in attachments) {
      if (attachment.type == AttachmentType.sketch &&
          attachment.sketch != null &&
          attachment.sketch!.hasEncryptedMetadata) {
        try {
          final decryptedMetadata = await localEncryption.decryptString(
            attachment.sketch!.encryptedMetadata!,
          );
          final metadata =
              json.decode(decryptedMetadata) as Map<String, dynamic>;

          // Restore strokes, bgColor, pagePattern from decrypted metadata
          attachment.sketch!.strokes = (metadata['strokes'] as List)
              .map((e) => SketchStroke.parse(e as String))
              .toList();
          attachment.sketch!.backgroundColor = Color(
            metadata['bgColor'] as int? ?? 0xFFFFFFFF,
          );
          attachment.sketch!.pagePattern = PagePattern.values.firstWhere(
            (e) => e.name == metadata['pagePattern'],
            orElse: () => PagePattern.blank,
          );
          attachment.sketch!.encryptedMetadata = null; // Clear after decryption
        } catch (e) {
          AppLogger.error('Error decrypting sketch metadata', e);
        }
      }
    }
  }

  /// Updates the sync track for this note.
  /// This is an awaitable version of the sync track update logic from notify().
  Future<void> _updateSyncTrack(SyncAction action) async {
    if (id == null) {
      AppLogger.log(
        "Cannot create SyncTrack for note without ID for action $action",
      );
      return;
    }

    final track =
        await syncTrack ?? NoteSyncTrack(localId: id!, action: action);
    await track.setAction(action);
    NoteSyncService().sync();
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

  Future<void> lock(String password) async {
    if (_locked) {
      return;
    }

    try {
      final encryptedContent = await encrypt(content ?? '', password);
      content = encryptedContent;
      _password = password;
      _locked = true;
      _unlocked = false;

      // Generate thumbnails for attachments that don't have them yet
      await _generateMissingThumbnails();

      // Encrypt sketch stroke data with the password
      await _encryptSketchData(password);

      // Encrypt all attachment files with the password
      await _encryptAttachments(password);

      await save();
    } catch (e) {
      AppLogger.log("Error locking note: $e");
    }
  }

  Future<void> unlock(String password) async {
    if (!_locked || _unlocked) {
      return;
    }

    try {
      jsonDecode(content ?? '');
      try {
        await _decryptAttachments(password);
        await _decryptSketchData(password);
      } catch (e) {
        AppLogger.log("Error decrypting attachments: $e");
        throw const NoteUnlockException('Incorrect PIN or corrupted note data');
      }
      _unlocked = true;
      _password = password;
      return;
    } catch (e) {
      // Continue to decryption
    }

    try {
      final decryptedContent = await decrypt(content ?? '', password);
      if (decryptedContent.isEmpty && content != null && content!.isNotEmpty) {
        throw const NoteUnlockException('Decryption produced empty content');
      }

      _unlocked = true;
      _password = password;
      content = decryptedContent;

      // Decrypt attachment files
      await _decryptAttachments(password);

      // Decrypt sketch stroke data
      await _decryptSketchData(password);
    } on FormatException {
      throw const NoteUnlockException('Incorrect PIN or corrupted note data');
    } catch (e) {
      throw NoteUnlockException('Failed to unlock note: $e');
    }
  }

  /// Permanently removes the lock from a note.
  /// This decrypts the content and attachments, then removes the lock flag.
  /// Unlike [unlock], this method permanently removes the lock and saves the note.
  Future<void> removeLock(String password) async {
    if (!_locked) {
      return;
    }

    // First unlock the note if not already unlocked
    if (!_unlocked) {
      await unlock(password);
    }

    // Now permanently remove the lock
    _locked = false;
    _unlocked = false;
    _password = null;

    await save();
  }

  /// Encrypts all attachment files with the given password.
  /// Files are encrypted in-place - the original file is replaced with encrypted version.
  Future<void> _encryptAttachments(String password) async {
    final fs = await fileSystem();

    for (final attachment in attachments) {
      // Get all paths for this attachment (sketches may have multiple files)
      final paths = _getAttachmentPaths(attachment);

      for (final path in paths) {
        try {
          if (path.isEmpty) continue;

          // Skip if file doesn't exist locally
          if (!await fs.exists(path)) continue;

          // Read the file (potentially already encrypted with local data encryption)
          final data = await readEncryptedBytes(path);

          // Skip if already password-encrypted
          if (isBytesPasswordEncrypted(data)) continue;

          // Encrypt with password
          final encrypted = await encryptBytesWithPassword(data, password);

          // Write back (with local data encryption if enabled)
          await writeEncryptedBytes(path, encrypted);

          AppLogger.log('Encrypted attachment: $path');
        } catch (e) {
          AppLogger.error('Error encrypting attachment', e);
        }
      }
    }
  }

  /// Decrypts all attachment files with the given password.
  /// Files are decrypted in-place - the encrypted file is replaced with decrypted version.
  Future<void> _decryptAttachments(String password) async {
    final fs = await fileSystem();

    for (final attachment in attachments) {
      // Get all paths for this attachment (sketches may have multiple files)
      final paths = _getAttachmentPaths(attachment);

      for (final path in paths) {
        try {
          if (path.isEmpty) continue;

          // Skip if file doesn't exist locally
          if (!await fs.exists(path)) continue;

          // Read the file (handles local data encryption automatically)
          final data = await readEncryptedBytes(path);

          // Skip if not password-encrypted
          if (!isBytesPasswordEncrypted(data)) continue;

          // Decrypt with password
          final decrypted = await decryptBytesWithPassword(data, password);

          // Write back (with local data encryption if enabled)
          await writeEncryptedBytes(path, decrypted);

          AppLogger.log('Decrypted attachment: $path');
        } catch (e) {
          AppLogger.error('Error decrypting attachment', e);
        }
      }
    }
  }

  /// Encrypts sketch stroke data with the given password.
  /// The strokes are serialized to JSON, encrypted, and stored in encryptedStrokes.
  /// This protects the actual drawing data (paths, colors, sizes) in locked notes.
  Future<void> _encryptSketchData(String password) async {
    for (final attachment in attachments) {
      if (attachment.type != AttachmentType.sketch) continue;

      final sketch = attachment.sketch;
      if (sketch == null) continue;

      // Skip if no strokes to encrypt
      if (sketch.strokes.isEmpty && !sketch.hasEncryptedStrokes) continue;

      // Skip if already encrypted
      if (sketch.hasEncryptedStrokes) continue;

      try {
        // Serialize all sensitive sketch data to JSON
        final sensitiveData = {
          'strokes': sketch.strokes.map((s) => s.toString()).toList(),
          'bgColor': sketch.backgroundColor.toARGB32(),
          'pagePattern': sketch.pagePattern.name,
        };
        final sensitiveJson = json.encode(sensitiveData);

        // Encrypt the sketch data
        final encrypted = await encrypt(sensitiveJson, password);

        // Store encrypted data and clear plaintext
        sketch.encryptedStrokes = encrypted;
        sketch.strokes = [];

        AppLogger.log('Encrypted sketch data');
      } catch (e) {
        AppLogger.error('Error encrypting sketch data', e);
      }
    }
  }

  /// Decrypts sketch stroke data with the given password.
  /// Restores the strokes list from encrypted data.
  Future<void> _decryptSketchData(String password) async {
    for (final attachment in attachments) {
      if (attachment.type != AttachmentType.sketch) continue;

      final sketch = attachment.sketch;
      if (sketch == null || !sketch.hasEncryptedStrokes) continue;

      try {
        // Decrypt the sketch data
        final decryptedJson = await decrypt(sketch.encryptedStrokes!, password);
        final data = json.decode(decryptedJson);

        // Handle both old format (just strokes array) and new format (object with strokes, bgColor, pagePattern)
        if (data is List) {
          // Old format: just strokes array
          sketch.strokes = data
              .map((e) => SketchStroke.parse(e as String))
              .toList();
        } else if (data is Map<String, dynamic>) {
          // New format: object with all sensitive data
          if (data['strokes'] != null) {
            sketch.strokes = (data['strokes'] as List)
                .map((e) => SketchStroke.parse(e as String))
                .toList();
          }
          if (data['bgColor'] != null) {
            sketch.backgroundColor = Color(data['bgColor'] as int);
          }
          if (data['pagePattern'] != null) {
            sketch.pagePattern = PagePattern.values.firstWhere(
              (e) => e.name == data['pagePattern'],
              orElse: () => PagePattern.blank,
            );
          }
        }

        // Clear encrypted data
        sketch.encryptedStrokes = null;

        AppLogger.log('Decrypted sketch data');
      } catch (e) {
        AppLogger.error('Error decrypting sketch data', e);
        rethrow; // Let unlock handle the error
      }
    }
  }

  /// Generates thumbnails for attachments that don't have them yet.
  /// Must be called before encrypting attachments (files must be readable).
  Future<void> _generateMissingThumbnails() async {
    final fs = await fileSystem();

    for (final attachment in attachments) {
      try {
        if (attachment.type == AttachmentType.image) {
          final image = attachment.image;
          if (image == null || image.blurredThumbnail != null) continue;

          final path = image.src;
          if (path.isEmpty || !await fs.exists(path)) continue;

          final data = await readEncryptedBytes(path);
          final thumbnail = await ThumbnailGenerator.generateFromBytes(data);
          if (thumbnail != null) {
            image.blurredThumbnail = thumbnail;
            AppLogger.log('Generated thumbnail for image: $path');
          }
        } else if (attachment.type == AttachmentType.sketch) {
          final sketch = attachment.sketch;
          if (sketch == null || sketch.blurredThumbnail != null) continue;

          final path = sketch.previewImage;
          if (path == null || path.isEmpty || !await fs.exists(path)) continue;

          final data = await readEncryptedBytes(path);
          final thumbnail = await ThumbnailGenerator.generateFromBytes(data);
          if (thumbnail != null) {
            sketch.blurredThumbnail = thumbnail;
            AppLogger.log('Generated thumbnail for sketch: $path');
          }
        }
      } catch (e) {
        AppLogger.error('Error generating thumbnail', e);
      }
    }
  }

  /// Gets all file paths for an attachment.
  /// Sketches may have both a preview image and a background image.
  List<String> _getAttachmentPaths(NoteAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        final src = attachment.image?.src;
        return src != null ? [src] : [];
      case AttachmentType.sketch:
        final paths = <String>[];
        if (attachment.sketch?.previewImage != null) {
          paths.add(attachment.sketch!.previewImage!);
        }
        if (attachment.sketch?.backgroundImage != null) {
          paths.add(attachment.sketch!.backgroundImage!);
        }
        return paths;
      case AttachmentType.audio:
        final src = attachment.recording?.src;
        return src != null ? [src] : [];
    }
  }

  Future<void> addImage(NoteImage image) async {
    if (hasImage(image)) {
      return;
    }

    attachments.add(NoteAttachment.image(image));

    // If note is locked and unlocked, encrypt the new attachment
    if (_locked && _unlocked && _password != null) {
      await _encryptSingleAttachment(image.src, _password!);
    }

    await save();
  }

  /// Encrypts a single attachment file with the note's password.
  Future<void> _encryptSingleAttachment(String? path, String password) async {
    if (path == null || path.isEmpty) return;

    final fs = await fileSystem();
    if (!await fs.exists(path)) return;

    try {
      final data = await readEncryptedBytes(path);
      if (isBytesPasswordEncrypted(data)) return; // Already encrypted

      final encrypted = await encryptBytesWithPassword(data, password);
      await writeEncryptedBytes(path, encrypted);
      AppLogger.log('Encrypted new attachment: $path');
    } catch (e) {
      AppLogger.error('Error encrypting new attachment', e);
    }
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

  Future<void> addSketch(SketchData sketch) async {
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

    // If note is locked and unlocked, encrypt the new attachment
    if (_locked && _unlocked && _password != null) {
      await _encryptSingleAttachment(sketch.previewImage, _password!);
      if (sketch.backgroundImage != null) {
        await _encryptSingleAttachment(sketch.backgroundImage, _password!);
      }
    }

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
    _unlocked = true;
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

    // Capture the note id before deletion for sync tracking
    final noteId = id!;

    if (isAlarmSupported) {
      final alarmId = await AlarmIdService.getAlarmId(noteId);
      await Alarm.stop(alarmId);
      await AlarmIdService.removeAlarmId(noteId);
    }

    // Update sync track BEFORE deleting from local database.
    // This ensures the delete action is properly recorded and the remoteId
    // is preserved from any existing sync track.
    await _updateSyncTrack(SyncAction.delete);

    int result = await AppState.db.delete(
      model,
      where: "id = ?",
      whereArgs: [noteId],
    );
    await _deleteLocalFiles();
    // Emit the deleted event for UI listeners (without sync tracking since
    // we already updated the sync track above)
    super.notify("deleted");
    return result;
  }

  /// Prepares and returns JSON for saving to database.
  /// Handles encryption of locked notes asynchronously.
  Future<Map<String, dynamic>> toJsonAsync() async {
    // Prepare content for saving
    String? contentToSave = content;
    String? plainTextToSave = plainText;

    // Encrypt content if note is locked and was unlocked for editing
    if (_locked && _unlocked) {
      if (_password == null || _password!.isEmpty) {
        // Reset unlocked state if no password - prevents data loss
        _unlocked = false;
        AppLogger.log(
          'Warning: Locked note without password, keeping existing content',
        );
      } else {
        try {
          contentToSave = await encrypt(content ?? '', _password!);
          _unlocked = false;
          content = contentToSave; // Update instance state
        } catch (e) {
          AppLogger.log('Error encrypting note content: $e');
          // Keep existing content rather than losing data
          _unlocked = false;
        }
      }
    }

    if (!_locked) {
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

    // Encrypt sketch data within attachments if files encryption is enabled
    final encryptedAttachments = <Map<String, dynamic>>[];
    for (final attachment in attachments) {
      final attachmentJson = attachment.toJson();

      // Encrypt sketch metadata (strokes, bgColor, pagePattern) if files encryption is enabled
      if (attachment.type == AttachmentType.sketch &&
          attachment.sketch != null) {
        final sketch = attachment.sketch!;
        final sketchMetadata = json.encode({
          'strokes': sketch.strokes.map((s) => s.toString()).toList(),
          'bgColor': sketch.backgroundColor.toARGB32(),
          'pagePattern': sketch.pagePattern.name,
        });
        final encryptedMetadata = await localEncryption
            .encryptAttachmentMetadata(sketchMetadata);

        // If encrypted (different from original), store as encrypted field
        if (encryptedMetadata != sketchMetadata) {
          attachmentJson['data'] = {
            'encrypted_metadata': encryptedMetadata,
            'previewImage': sketch.previewImage,
            'backgroundImage': sketch.backgroundImage,
            'aspectRatio': sketch.aspectRatio,
            if (sketch.blurredThumbnail != null)
              'blurredThumbnail': sketch.blurredThumbnail,
          };
        }
      }

      encryptedAttachments.add(attachmentJson);
    }

    final attachmentsJson = json.encode(encryptedAttachments);

    return {
      'id': id,
      'title': title,
      'labels': labels,
      'content': contentEncrypted,
      'plain_text': plainTextToSave,
      'locked': _locked ? 1 : 0,
      'pinned': pinned ? 1 : 0,
      'trashed': trashed ? 1 : 0,
      'archived': archived ? 1 : 0,
      'read_only': readOnly ? 1 : 0,
      'completed': completed ? 1 : 0,
      'color': color.toARGB32().toString(),
      'updated_at': updatedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'attachments': attachmentsJson,
      'reminder': reminder != null ? json.encode(reminder!.toJson()) : null,
    };
  }

  /// Returns JSON representation of the note for display/serialization.
  /// NOTE: This does not encrypt locked notes. Use [toJsonAsync] for saving.
  Map<String, dynamic> toJson() {
    final plainTextValue = _locked ? '' : (document?.toPlainText() ?? '');

    return {
      'id': id,
      'title': title,
      'labels': labels,
      'content': content,
      'plain_text': plainTextValue,
      'locked': _locked ? 1 : 0,
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
