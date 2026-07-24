import 'dart:async';
import 'dart:convert';

import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/legacy_sketch_migration_service.dart';
import 'package:better_keep/services/note_share_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

typedef NoteEvent = ModelEvent<Note>;
typedef NoteListener = ModelListener<Note>;
typedef ReminderScheduleCallback =
    Future<ReminderScheduleResult> Function(Note note);

Reminder? _parseReminder(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    return Reminder.fromJson(Map<String, Object?>.from(jsonDecode(raw) as Map));
  }
  if (raw is Map) {
    return Reminder.fromJson(Map<String, Object?>.from(raw));
  }
  return null;
}

enum _AttachmentSerializationPolicy { standard, lockedPinBoundary }

class NoteColor {
  final Color value;
  final int count;

  NoteColor(this.value, this.count);
}

class NoteUnlockException implements Exception {
  final String message;
  const NoteUnlockException(this.message);

  @override
  String toString() => message;
}

class NoteLockRemovalException extends NoteUnlockException {
  final Object? cause;

  const NoteLockRemovalException(super.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class NoteLockException implements Exception {
  final String message;
  final Object? cause;

  const NoteLockException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class NoteRelockException implements Exception {
  final String message;
  final Object? cause;

  const NoteRelockException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class NoteSketchSaveException implements Exception {
  final String message;
  final Object? cause;

  const NoteSketchSaveException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

enum NoteAttachmentCommitFailure {
  authentication,
  sourceUnavailable,
  protection,
  verification,
  persistence,
}

class NoteAttachmentCommitException implements Exception {
  final NoteAttachmentCommitFailure failure;
  final String message;
  final Object? cause;

  const NoteAttachmentCommitException(this.failure, this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

@immutable
class _ProtectedNoteUnlockState {
  final String? content;
  final bool locked;
  final bool unlocked;
  final String? password;

  const _ProtectedNoteUnlockState({
    required this.content,
    required this.locked,
    required this.unlocked,
    required this.password,
  });

  factory _ProtectedNoteUnlockState.capture(Note note) {
    return _ProtectedNoteUnlockState(
      content: note.content,
      locked: note._locked,
      unlocked: note._unlocked,
      password: note._password,
    );
  }

  bool matches(Note note) {
    return note.content == content &&
        note._locked == locked &&
        note._unlocked == unlocked &&
        note._password == password;
  }
}

extension NoteEventData on NoteEvent {
  Note get note => payload;
}

enum NoteType { all, archived, trashed, pinned, locked, reminder }

class Note extends BaseModel<Note> {
  static final ModelSchema<Note> _schema = _createSchema();
  static const model = "note";
  static const decryptionFailedContent = '{"decryption_failed": true}';

  @visibleForTesting
  static NoteLockFileOperations? lockFileOperationsOverride;

  @visibleForTesting
  static void Function(Note note, bool wasNew)? lockCommittedNotifierOverride;

  /// Pauses a lock after its detached row and journal are ready, but before the
  /// optimistic database transaction starts.
  @visibleForTesting
  static Future<void> Function(Note note)? lockBeforeCommitOverride;

  @visibleForTesting
  static Future<void> Function(Note note)? lockRemovalBeforeCommitOverride;

  @visibleForTesting
  static void Function(Note note)? lockRemovalCommittedNotifierOverride;

  @visibleForTesting
  static Future<void> Function()? legacyMigrationSyncTriggerOverride;

  @visibleForTesting
  static Future<void> Function()? protectedAttachmentRepairSyncTriggerOverride;

  @visibleForTesting
  static Future<String> Function(String content, String password)?
  pinContentEncryptOverride;

  @visibleForTesting
  static Future<String> Function(String content, String password)?
  pinContentDecryptOverride;

  @visibleForTesting
  static Future<Uint8List> Function(Uint8List bytes, String password)?
  pinAttachmentDecryptOverride;

  @visibleForTesting
  static Future<void> Function(Note note, String password)?
  unlockPostAuthenticationOverride;

  @visibleForTesting
  static LocalSketchMetadataDecryptor? localSketchMetadataDecryptOverride;

  @visibleForTesting
  static LocalSketchMetadataEncryptor? localSketchMetadataEncryptOverride;

  @visibleForTesting
  static NewAttachmentTransactionJournal? newAttachmentJournalOverride;

  @visibleForTesting
  static AttachmentSessionRead? newAttachmentReadOverride;

  @visibleForTesting
  static AttachmentSessionWrite? newAttachmentWriteOverride;

  @visibleForTesting
  static void Function()? syncTriggerOverride;

  bool _locked;
  String? syncId;
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

  final _mutationQueue = _AsyncMutationQueue();

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

  /// Restores PIN-protected in-memory content and clears the cached password.
  ///
  /// The transition is atomic and throws [NoteRelockException] without clearing
  /// the PIN when encryption, verification, or the optimistic state guard fails.
  Future<void> clearPassword() =>
      _enqueueMutation(_clearPasswordWithinMutation);

  Future<void> _clearPasswordWithinMutation() async {
    if (!_locked) {
      _password = null;
      _unlocked = false;
      return;
    }

    if (!_unlocked) {
      _clearPlaintextBodyCaches();
      _password = null;
      return;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      final password = _password;
      if (password == null || password.isEmpty) {
        throw const NoteRelockException(
          'Cannot forget the PIN while the locked note is unprotected',
        );
      }

      final plainContent = content ?? '';
      final plainTextSnapshot = plainText;
      late final String protectedContent;
      late final String verifiedContent;
      try {
        protectedContent = await _encryptPinContent(plainContent, password);
        verifiedContent = await _decryptPinContent(protectedContent, password);
      } catch (error) {
        throw NoteRelockException(
          'Failed to restore protected note content',
          error,
        );
      }

      if (verifiedContent != plainContent) {
        throw const NoteRelockException(
          'Protected note content failed verification',
        );
      }

      final stateIsUnchanged =
          _locked &&
          _unlocked &&
          _password == password &&
          content == plainContent &&
          plainText == plainTextSnapshot;
      if (!stateIsUnchanged) {
        if (attempt == 0) continue;
        throw const NoteRelockException(
          'The note changed while its PIN was being forgotten',
        );
      }

      content = protectedContent;
      _clearPlaintextBodyCaches();
      _clearSketchStrokes(attachments);
      _password = null;
      _unlocked = false;
      return;
    }
  }

  void _clearPlaintextBodyCaches() {
    plainText = '';
    _cachedCheckboxCount = null;
    _lastContentForCheckbox = null;
  }

  static Future<String> _encryptPinContent(String content, String password) {
    return (pinContentEncryptOverride ?? encrypt)(content, password);
  }

  static Future<String> _decryptPinContent(String content, String password) {
    return (pinContentDecryptOverride ?? decrypt)(content, password);
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

  static Future<int> count(
    NoteType type, [
    List<String>? filterLabels,
    String? searchQuery,
  ]) {
    return _schema.count([type, filterLabels, searchQuery]);
  }

  static Future<List<Note>> filterByColor(Color color) {
    return _schema.get([NoteType.all, null, null, color.toARGB32().toString()]);
  }

  static Future<int> countByColor(Color color) {
    return _schema.count([
      NoteType.all,
      null,
      null,
      color.toARGB32().toString(),
    ]);
  }

  static Future<List<Note>> filterByLabels(List<String>? filterLabels) {
    if (filterLabels == null) {
      return _schema.get([NoteType.all, null, null, null, true]);
    }

    return _schema.get([NoteType.all, filterLabels]);
  }

  static Future<int> countByLabels(List<String>? filterLabels) {
    if (filterLabels == null) {
      return _schema.count([NoteType.all, null, null, null, true]);
    }

    return _schema.count([NoteType.all, filterLabels]);
  }

  static Future<List<NoteColor>> getAllColors() async {
    final rows = await AppState.db.rawQuery('''
        SELECT DISTINCT color, COUNT(*) as count
        FROM note
        WHERE trashed = 0 AND archived = 0
        GROUP BY color
        ORDER BY color ASC;
      ''');
    return rows.map((row) {
      final colorValue = int.tryParse(row['color'] as String? ?? '') ?? 0;
      final count = row['count'] as int? ?? 0;
      return NoteColor(Color(colorValue), count);
    }).toList();
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
    return reminder?.isOverdueAt(DateTime.now()) ?? false;
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

    // Skip if note is locked - content is encrypted
    if (_locked && !_unlocked) {
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

      return documentFromJsonSafe(parsed);
    } catch (e) {
      // Log parse errors to help debug corrupted content (but not for locked notes)
      if (!_locked) {
        AppLogger.error('Warning: Failed to parse note document (id=$id)', e);
      }
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
    this.syncId,
    this.title,
    this.labels,
    this.content,
    this.reminder,
    this.plainText,
    this.createdAt,
    this.updatedAt,
    // Keep the public constructor argument separate from its private backing
    // field so callers can continue using `Note(locked: ...)`.
    bool locked = false,
    this.pinned = false,
    this.trashed = false,
    this.archived = false,
    this.readOnly = false,
    this.completed = false,
    this.color = Colors.transparent,
    List<NoteAttachment>? attachments,
    // ignore: prefer_initializing_formals
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

    List<NoteAttachment> parsedAttachments = [];
    String? rawAttachmentsStr;
    if (obj['attachments'] != null) {
      final attachmentsData = obj['attachments'];
      if (attachmentsData is String) {
        if (LocalDataEncryption.isEncrypted(attachmentsData)) {
          rawAttachmentsStr = attachmentsData;
        } else {
          try {
            parsedAttachments = (json.decode(attachmentsData) as List)
                .map((e) => NoteAttachment.fromJson(e))
                .toList();
          } catch (e) {
            AppLogger.error('Error parsing attachments in fromJson', e);
          }
        }
      } else if (attachmentsData is List) {
        parsedAttachments = attachmentsData
            .map((e) => NoteAttachment.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    }

    final note = Note(
      locked: locked,
      id: obj['id'] ?? -1,
      syncId: obj['sync_id'] as String?,
      title: obj['title'] ?? '',
      labels: obj['labels'] ?? '',
      content: obj['content'] ?? '',
      plainText: obj['plain_text'] ?? '',
      attachments: parsedAttachments,
      completed: (obj['completed'] == 1 || obj['completed'] == true)
          ? true
          : false,
      reminder: _parseReminder(obj['reminder']),
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
    syncId = obj['sync_id'] as String? ?? syncId;
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

    final reminderWasProvided = obj.containsKey('reminder');
    if (reminderWasProvided) {
      final reminderData = obj['reminder'];
      reminder = _parseReminder(reminderData);
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
    await save(false, ModelChangeOrigin.remoteSync);
    if (id != null && reminderWasProvided) {
      if (reminder != null && !completed && !trashed) {
        await ReminderCoordinator.instance.schedule(this);
      } else {
        await ReminderCoordinator.instance.cancel(id!);
      }
    }
    return this;
  }

  static Future<Note> fromJsonAsync(Map<String, dynamic> obj) async {
    final note = Note.fromJson(obj);
    await note.decryptFields();
    return note;
  }

  Future<void> decryptFields() async {
    final localEncryption = LocalDataEncryption.instance;

    // Decrypt content
    if (content != null && content!.isNotEmpty) {
      content = await localEncryption.decryptString(content!);
    }

    if (_rawEncryptedAttachments != null) {
      try {
        final decryptedStr = await localEncryption.decryptString(
          _rawEncryptedAttachments!,
        );
        final List attachmentList = json.decode(decryptedStr);
        attachments = attachmentList
            .map((a) => NoteAttachment.fromJson(a as Map<String, dynamic>))
            .toList();
        _rawEncryptedAttachments = null;
      } catch (e) {
        AppLogger.error('Error decrypting attachments', e);
      }
    }

    for (final attachment in attachments) {
      if (attachment.type == AttachmentType.sketch &&
          attachment.sketch != null &&
          attachment.sketch!.hasEncryptedMetadata) {
        // Local attachment encryption is not a substitute for the note PIN.
        // Locked sketches keep this deprecated value opaque until the PIN has
        // authenticated the migration that removes or re-protects it.
        if (_locked) continue;
        try {
          final decryptedMetadata = await localEncryption.decryptString(
            attachment.sketch!.encryptedMetadata!,
          );
          final metadata =
              json.decode(decryptedMetadata) as Map<String, dynamic>;

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
          attachment.sketch!.encryptedMetadata = null;
          attachment.sketch!.markStrokesHydrated();
        } catch (e) {
          AppLogger.error('Error decrypting sketch metadata', e);
        }
      }
    }
  }

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
    final triggerSync = syncTriggerOverride;
    if (triggerSync != null) {
      triggerSync();
    } else {
      NoteSyncService().sync();
    }
  }

  @override
  void notify(
    String event, [
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  ]) async {
    super.notifyWithOrigin(event, origin);

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
    final triggerSync = syncTriggerOverride;
    if (triggerSync != null) {
      triggerSync();
    } else {
      NoteSyncService().sync();
    }
  }

  /// Password-protects the note and all locally referenced source files.
  ///
  /// The transition is fail-closed: [NoteLockException] is thrown unless all
  /// required files are staged, verified, and committed atomically.
  Future<void> lock(String password) =>
      _enqueueMutation(() => _lockWithinMutation(password));

  Future<void> _lockWithinMutation(String password) async {
    if (_locked) {
      return;
    }

    if (password.isEmpty) {
      throw const NoteLockException('A PIN is required to lock this note');
    }

    final stateFingerprint = _NoteLockStateFingerprint.capture(this);
    final authenticatedContent = content ?? '';
    final authenticatedPlainText = plainText;
    final originalId = id;
    final wasNew = originalId == null;
    Map<String, Object?>? expectedRow;
    if (!wasNew) {
      late final List<Map<String, Object?>> rows;
      try {
        rows = await AppState.db.query(
          model,
          where: 'id = ?',
          whereArgs: [originalId],
          limit: 1,
        );
      } catch (error) {
        throw NoteLockException(
          'Unable to read the note before locking',
          error,
        );
      }
      if (rows.isEmpty) {
        throw const NoteLockException(
          'The note no longer exists locally; reload it before locking',
        );
      }
      expectedRow = Map<String, Object?>.from(rows.single);
    }

    late final NoteLockFileOperations operations;
    late final NoteLockJournal journal;
    try {
      operations =
          lockFileOperationsOverride ?? await NoteLockFileOperations.platform();
      journal = NoteLockJournal(await AppState.prefs);
    } catch (error) {
      throw NoteLockException(
        'Unable to initialize protected file storage',
        error,
      );
    }

    final noteId = originalId ?? DateTime.now().millisecondsSinceEpoch;
    final transactionService = NoteLockTransactionService(operations);
    NoteLockJournalRecord? activeRecord;
    var databaseCommitted = false;

    try {
      final encryptedContent = await encrypt(authenticatedContent, password);
      final workingAttachments = _deepCopyAttachments(attachments);

      // Thumbnails are optional presentation data. Failure leaves a locked-card
      // placeholder but must not weaken the source-file transaction.
      await _generateMissingAttachmentThumbnails(workingAttachments);
      final preparation = await transactionService.prepare(
        noteId: noteId,
        attachments: workingAttachments,
        password: password,
        journal: journal,
      );
      activeRecord = preparation.journalRecord;

      preparation.apply(workingAttachments);
      _clearSketchStrokes(workingAttachments);
      final proposedUpdatedAt = DateTime.now();
      final proposedCreatedAt =
          createdAt ??
          (wasNew
              ? proposedUpdatedAt
              : DateTime.tryParse(
                  expectedRow?['created_at']?.toString() ?? '',
                ));
      final detached = Note(
        id: noteId,
        title: title,
        labels: labels,
        content: encryptedContent,
        reminder: reminder,
        plainText: '',
        createdAt: proposedCreatedAt,
        updatedAt: proposedUpdatedAt,
        locked: true,
        pinned: pinned,
        trashed: trashed,
        archived: archived,
        readOnly: readOnly,
        completed: completed,
        color: color,
        attachments: workingAttachments,
      );
      detached._password = password;
      detached._unlocked = false;

      final row = await detached.toJsonAsync();
      row['id'] = noteId;
      final attachmentsValue = row['attachments'] as String;
      activeRecord = activeRecord.readyForCommit(attachmentsValue);
      await journal.put(activeRecord);

      await lockBeforeCommitOverride?.call(this);
      if (!stateFingerprint.matches(this)) {
        throw StateError(
          'The note changed in memory while it was being locked; retry the lock',
        );
      }

      await _commitLockTransaction(
        noteId: noteId,
        row: row,
        expectedRow: expectedRow,
        wasNew: wasNew,
        replacements: activeRecord.replacements,
      );
      databaseCommitted = true;

      // Publish the protected state only after SQLite and file tracking commit.
      // No await belongs in this block: observers must never see a partial
      // in-memory transition.
      id = noteId;
      if (!_publishAttachments(attachments, workingAttachments)) {
        attachments = workingAttachments;
      }
      // Supplying the PIN authenticates the editor's current process session.
      // SQLite and the canonical attachment files remain protected, while the
      // live model keeps plaintext content so subsequent queued edits can be
      // serialized safely with the cached PIN.
      content = authenticatedContent;
      plainText = authenticatedPlainText;
      _password = password;
      _locked = true;
      _unlocked = true;
      updatedAt = proposedUpdatedAt;
      createdAt = proposedCreatedAt;
    } catch (error, stackTrace) {
      if (!databaseCommitted && activeRecord != null) {
        try {
          final retainedPaths =
              await NoteFileReferenceService.databaseReferencedLocalPaths(
                AppState.db,
              );
          final cleaned = await transactionService.cleanupStaged(
            activeRecord,
            retainedPaths: retainedPaths,
          );
          if (cleaned) {
            await journal.remove(activeRecord.transactionId);
          }
        } catch (cleanupError, cleanupStackTrace) {
          AppLogger.error(
            'Failed to safely clear rolled-back note-lock files',
            cleanupError,
            cleanupStackTrace,
          );
        }
      }

      AppLogger.error('Error locking note', error, stackTrace);
      if (error is NoteLockException) rethrow;
      throw NoteLockException('Failed to lock note', error);
    }

    final committedNotifier = lockCommittedNotifierOverride;
    if (committedNotifier != null) {
      committedNotifier(this, wasNew);
    } else {
      notify(wasNew ? 'created' : 'updated');
    }

    // The committed note references only verified encrypted copies. Cleanup is
    // journaled and may safely continue on the next startup if deletion fails.
    try {
      final retainedPaths =
          await NoteFileReferenceService.databaseReferencedLocalPaths(
            AppState.db,
          );
      final cleaned = await transactionService.cleanupOriginals(
        activeRecord,
        retainedPaths: retainedPaths,
      );
      if (cleaned) {
        await journal.remove(activeRecord.transactionId);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Locked note committed; original-file cleanup will retry at startup',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _commitLockTransaction({
    required int noteId,
    required Map<String, Object?> row,
    required Map<String, Object?>? expectedRow,
    required bool wasNew,
    required List<NoteLockFileReplacement> replacements,
  }) async {
    await AppState.db.transaction((transaction) async {
      if (wasNew) {
        final existing = await transaction.query(
          model,
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [noteId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          throw StateError('A note with this ID was created concurrently');
        }
        await transaction.insert(model, row);
      } else {
        final currentRows = await transaction.query(
          model,
          where: 'id = ?',
          whereArgs: [noteId],
          limit: 1,
        );
        if (currentRows.isEmpty ||
            !mapEquals(
              Map<String, Object?>.from(currentRows.single),
              expectedRow,
            )) {
          throw StateError(
            'The note changed while it was being locked; reload and retry',
          );
        }
        final updated = await transaction.update(
          model,
          row,
          where: 'id = ?',
          whereArgs: [noteId],
        );
        if (updated != 1) {
          throw StateError('The locked note could not be persisted');
        }
      }

      for (final replacement in replacements) {
        final oldPath = replacement.oldPath;
        if (oldPath == null ||
            oldPath.isEmpty ||
            oldPath.startsWith('data:') ||
            oldPath.startsWith('http://') ||
            oldPath.startsWith('https://')) {
          continue;
        }
        await transaction.rawUpdate(
          '''
          UPDATE file_sync_track
          SET local_path = ?, content_hash = NULL
          WHERE note_id = ? AND local_path = ?
          ''',
          [replacement.newPath, noteId, oldPath],
        );
      }
    });
  }

  Future<void> unlock(String password) =>
      _enqueueMutation(() => _unlockWithinMutation(password));

  Future<void> _unlockWithinMutation(String password) async {
    if (!_locked || _unlocked) {
      return;
    }

    final protectedState = _ProtectedNoteUnlockState.capture(this);
    late final String decryptedContent;
    try {
      decryptedContent = await _decryptPinContent(content ?? '', password);
      if (decryptedContent.isEmpty && content != null && content!.isNotEmpty) {
        throw const NoteUnlockException('Decryption produced empty content');
      }
    } on FormatException {
      throw const NoteUnlockException('Incorrect PIN or corrupted note data');
    } on NoteUnlockException {
      rethrow;
    } catch (error) {
      throw NoteUnlockException('Failed to unlock note: $error');
    }

    if (!protectedState.matches(this) ||
        !protectedState.locked ||
        protectedState.unlocked) {
      throw const NoteUnlockException(
        'The protected note changed while it was being unlocked',
      );
    }

    // Publish the authenticated session without an asynchronous gap. From this
    // point onward any save sees both plaintext content and the PIN required to
    // protect its serialized copy.
    content = decryptedContent;
    _password = password;
    _unlocked = true;

    await _runPostUnlockBestEffort(password);
  }

  Future<void> _runPostUnlockBestEffort(String password) async {
    try {
      final override = unlockPostAuthenticationOverride;
      if (override != null) {
        await override(this, password);
        return;
      }

      var migrationResult = const LegacySketchMigrationResult(
        status: LegacySketchMigrationStatus.notNeeded,
      );
      if (id != null) {
        migrationResult = await _migrateLegacySketchesAfterUnlock(password);
      }

      try {
        await _repairExposedLockedAttachmentsAfterUnlock(password);
      } catch (error, stackTrace) {
        // Authentication succeeded, so do not deny note access merely because
        // an older exposed canonical file could not be replaced yet. The
        // originals and journal remain available for an idempotent retry.
        AppLogger.error(
          'Protected attachment repair was deferred for note $id',
          error,
          stackTrace,
        );
      }

      await SketchPreviewRepairService.repairAfterUnlock(this);
      if (migrationResult.shouldTriggerSync) {
        _triggerLegacyMigrationSyncBestEffort();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Post-unlock preparation was deferred for note $id',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _repairExposedLockedAttachmentsAfterUnlock(
    String password,
  ) async {
    final noteId = id;
    if (noteId == null || !_locked || !_unlocked || _password != password) {
      return;
    }

    final operations =
        lockFileOperationsOverride ?? await NoteLockFileOperations.platform();
    if (!await _hasExposedCanonicalAttachment(operations)) return;

    final rows = await AppState.db.query(
      model,
      where: 'id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const NoteUnlockException(
        'The authenticated note no longer exists locally',
      );
    }
    final expectedRow = Map<String, Object?>.from(rows.single);
    final stateFingerprint = _NoteLockStateFingerprint.capture(this);
    final workingAttachments = _deepCopyAttachments(attachments);
    final journal = NoteLockJournal(await AppState.prefs);
    final transactionService = NoteLockTransactionService(operations);
    NoteLockJournalRecord? activeRecord;
    var databaseCommitted = false;

    try {
      final preparation = await transactionService.prepare(
        noteId: noteId,
        attachments: workingAttachments,
        password: password,
        journal: journal,
      );
      activeRecord = preparation.journalRecord;
      preparation.apply(workingAttachments);

      final detached = Note(locked: true, attachments: workingAttachments);
      final attachmentsValue = await detached
          .serializeAttachmentsForLocalStorage();
      activeRecord = activeRecord.readyForCommit(attachmentsValue);
      await journal.put(activeRecord);

      if (!stateFingerprint.matches(this) ||
          !_locked ||
          !_unlocked ||
          _password != password) {
        throw const NoteUnlockException(
          'The note changed while its protected attachments were repaired',
        );
      }

      final proposedUpdatedAt = DateTime.now();
      await _commitProtectedAttachmentRepair(
        noteId: noteId,
        expectedRow: expectedRow,
        attachments: attachmentsValue,
        updatedAt: proposedUpdatedAt,
        replacements: activeRecord.replacements,
      );
      databaseCommitted = true;

      if (!_publishAttachments(attachments, workingAttachments)) {
        attachments = workingAttachments;
      }
      updatedAt = proposedUpdatedAt;
      notify('updated', false);
      final syncTrigger = protectedAttachmentRepairSyncTriggerOverride;
      unawaited(syncTrigger != null ? syncTrigger() : NoteSyncService().sync());
    } catch (_) {
      if (!databaseCommitted && activeRecord != null) {
        try {
          final retainedPaths =
              await NoteFileReferenceService.databaseReferencedLocalPaths(
                AppState.db,
              );
          final cleaned = await transactionService.cleanupStaged(
            activeRecord,
            retainedPaths: retainedPaths,
          );
          if (cleaned) await journal.remove(activeRecord.transactionId);
        } catch (cleanupError, cleanupStackTrace) {
          AppLogger.error(
            'Failed to safely clear staged attachment-repair files',
            cleanupError,
            cleanupStackTrace,
          );
        }
      }
      rethrow;
    }

    try {
      final retainedPaths =
          await NoteFileReferenceService.databaseReferencedLocalPaths(
            AppState.db,
          );
      final cleaned = await transactionService.cleanupOriginals(
        activeRecord,
        retainedPaths: retainedPaths,
      );
      if (cleaned) await journal.remove(activeRecord.transactionId);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Protected attachment repair committed; cleanup will retry at startup',
        error,
        stackTrace,
      );
    }
  }

  Future<bool> _hasExposedCanonicalAttachment(
    NoteLockFileOperations operations,
  ) async {
    final sourcePaths = <String>{};
    for (final attachment in attachments) {
      switch (attachment.type) {
        case AttachmentType.image:
          sourcePaths.add(attachment.image!.src);
        case AttachmentType.audio:
          sourcePaths.add(attachment.recording!.src);
        case AttachmentType.sketch:
          final sketch = attachment.sketch!;
          if (sketch.backgroundImage?.isNotEmpty ?? false) {
            sourcePaths.add(sketch.backgroundImage!);
          }
          if (sketch.previewImage?.isNotEmpty ?? false) {
            sourcePaths.add(sketch.previewImage!);
          }
          if (sketch.strokesFilePath?.isNotEmpty ?? false) {
            sourcePaths.add(sketch.strokesFilePath!);
          }
      }
    }

    for (final sourcePath in sourcePaths) {
      if (sourcePath.isEmpty ||
          sourcePath.startsWith('http://') ||
          sourcePath.startsWith('https://')) {
        continue;
      }
      // Inline sources are readable attachment bytes stored directly inside the
      // note row. Even when those bytes already carry an ENCP header, moving
      // them to a canonical protected file removes the payload from SQLite.
      if (sourcePath.startsWith('data:')) return true;
      final resolvedPath = await operations.resolve(sourcePath);
      if (!await operations.exists(resolvedPath)) continue;
      if (!isBytesPasswordEncrypted(await operations.read(resolvedPath))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _commitProtectedAttachmentRepair({
    required int noteId,
    required Map<String, Object?> expectedRow,
    required String attachments,
    required DateTime updatedAt,
    required List<NoteLockFileReplacement> replacements,
  }) async {
    await AppState.db.transaction((transaction) async {
      final currentRows = await transaction.query(
        model,
        where: 'id = ?',
        whereArgs: [noteId],
        limit: 1,
      );
      if (currentRows.isEmpty ||
          !mapEquals(
            Map<String, Object?>.from(currentRows.single),
            expectedRow,
          )) {
        throw StateError(
          'The note changed while its protected attachments were repaired',
        );
      }

      final updated = await transaction.update(
        model,
        {'attachments': attachments, 'updated_at': updatedAt.toIso8601String()},
        where: 'id = ?',
        whereArgs: [noteId],
      );
      if (updated != 1) {
        throw StateError('Protected attachment repair was not persisted');
      }

      for (final replacement in replacements) {
        final oldPath = replacement.oldPath;
        if (oldPath == null ||
            oldPath.isEmpty ||
            oldPath.startsWith('data:') ||
            oldPath.startsWith('http://') ||
            oldPath.startsWith('https://')) {
          continue;
        }
        await transaction.rawUpdate(
          '''
          UPDATE file_sync_track
          SET local_path = ?, content_hash = NULL
          WHERE note_id = ? AND local_path = ?
          ''',
          [replacement.newPath, noteId, oldPath],
        );
      }

      final syncRows = await transaction.query(
        NoteSyncTrack.model,
        where: 'local_id = ?',
        whereArgs: [noteId],
        limit: 1,
      );
      final syncTime = DateTime.now().toIso8601String();
      if (syncRows.isEmpty) {
        await transaction.insert(NoteSyncTrack.model, {
          'local_id': noteId,
          'action': SyncAction.upload.name,
          'status': SyncStatus.pending.name,
          'created_at': syncTime,
          'updated_at': syncTime,
        });
      } else if (syncRows.single['action'] != SyncAction.delete.name) {
        await transaction.update(
          NoteSyncTrack.model,
          {
            'action': SyncAction.upload.name,
            'status': SyncStatus.pending.name,
            'updated_at': syncTime,
          },
          where: 'id = ?',
          whereArgs: [syncRows.single['id']],
        );
      }
    });
  }

  Future<LegacySketchMigrationResult> _migrateLegacySketchesAfterUnlock(
    String password,
  ) async {
    try {
      final operations =
          lockFileOperationsOverride ?? await NoteLockFileOperations.platform();
      final migrationResult = await LegacySketchMigrationService(
        database: AppState.db,
        operations: operations,
        journal: LegacySketchMigrationJournal(await AppState.prefs),
        localMetadataDecryptor: localSketchMetadataDecryptOverride,
      ).migrate(noteId: id!, password: password);
      migrationResult.applyTo(this);
      return migrationResult;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Legacy sketch migration was deferred for note $id',
        error,
        stackTrace,
      );
      for (final sketch in sketches.where(
        (candidate) =>
            candidate.hasEncryptedStrokes || candidate.hasEncryptedMetadata,
      )) {
        sketch.markLegacyMigrationFailed(
          'Legacy drawing conversion was deferred',
        );
      }
      return const LegacySketchMigrationResult(
        status: LegacySketchMigrationStatus.deferred,
      );
    }
  }

  void _triggerLegacyMigrationSyncBestEffort() {
    try {
      notify('updated', false);
      final sync = legacyMigrationSyncTriggerOverride;
      final syncFuture = sync != null ? sync() : NoteSyncService().sync();
      unawaited(
        syncFuture.catchError((Object error, StackTrace stackTrace) {
          AppLogger.error(
            'Failed to trigger sync after legacy sketch migration for note $id',
            error,
            stackTrace,
          );
        }),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to schedule sync after legacy sketch migration for note $id',
        error,
        stackTrace,
      );
    }
  }

  Future<void> removeLock(String password) =>
      _enqueueMutation(() => _removeLockWithinMutation(password));

  Future<void> _removeLockWithinMutation(String password) async {
    if (!_locked) return;
    if (password.isEmpty) {
      throw const NoteLockRemovalException(
        'A PIN is required to remove the note lock',
      );
    }
    final noteId = id;
    if (noteId == null) {
      throw const NoteLockRemovalException(
        'The note must be saved before its lock can be removed',
      );
    }

    late final String plaintextContent;
    if (_unlocked) {
      final cachedPassword = _password;
      if (cachedPassword == null || cachedPassword.isEmpty) {
        throw const NoteLockRemovalException(
          'The unlocked note has no authenticated PIN',
        );
      }
      if (cachedPassword != password) {
        throw const NoteLockRemovalException('Incorrect PIN');
      }
      plaintextContent = content ?? '';
    } else {
      try {
        plaintextContent = await decrypt(content ?? '', password);
      } catch (error) {
        throw NoteLockRemovalException('Incorrect PIN', error);
      }
    }

    if (sketches.any((sketch) => sketch.requiresLegacyMigration)) {
      try {
        final operations =
            lockFileOperationsOverride ??
            await NoteLockFileOperations.platform();
        final migration = await LegacySketchMigrationService(
          database: AppState.db,
          operations: operations,
          journal: LegacySketchMigrationJournal(await AppState.prefs),
          localMetadataDecryptor: localSketchMetadataDecryptOverride,
        ).migrate(noteId: noteId, password: password);
        migration.applyTo(this);
        if (migration.shouldTriggerSync) {
          notify('updated', false);
          final sync = legacyMigrationSyncTriggerOverride;
          if (sync != null) {
            unawaited(sync());
          } else {
            unawaited(NoteSyncService().sync());
          }
        }
      } catch (error) {
        throw NoteLockRemovalException(
          'The protected legacy drawing could not be recovered',
          error,
        );
      }
    }
    if (sketches.any((sketch) => sketch.requiresLegacyMigration)) {
      throw const NoteLockRemovalException(
        'The lock cannot be removed until the protected legacy drawing is recovered',
      );
    }

    late final Map<String, Object?> expectedRow;
    try {
      final rows = await AppState.db.query(
        model,
        where: 'id = ?',
        whereArgs: [noteId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const NoteLockRemovalException(
          'The note no longer exists locally; reload it before removing the lock',
        );
      }
      expectedRow = Map<String, Object?>.from(rows.single);
    } on NoteLockRemovalException {
      rethrow;
    } catch (error) {
      throw NoteLockRemovalException(
        'Unable to read the note before removing its lock',
        error,
      );
    }

    final stateFingerprint = _NoteLockStateFingerprint.capture(this);
    late final NoteLockFileOperations operations;
    late final NoteLockRemovalJournal journal;
    try {
      operations =
          lockFileOperationsOverride ?? await NoteLockFileOperations.platform();
      journal = NoteLockRemovalJournal(await AppState.prefs);
    } catch (error) {
      throw NoteLockRemovalException(
        'Unable to initialize lock-removal storage',
        error,
      );
    }

    final transactionService = NoteLockRemovalTransactionService(operations);
    NoteLockRemovalJournalRecord? activeRecord;
    var databaseCommitted = false;

    try {
      final workingAttachments = _deepCopyAttachments(attachments);
      final preparation = await transactionService.prepare(
        noteId: noteId,
        attachments: workingAttachments,
        password: password,
        journal: journal,
      );
      activeRecord = preparation.journalRecord;
      preparation.apply(workingAttachments);

      final now = DateTime.now();
      final proposedUpdatedAt = updatedAt != null && !now.isAfter(updatedAt!)
          ? updatedAt!.add(const Duration(microseconds: 1))
          : now;
      final detached = Note(
        id: noteId,
        title: title,
        labels: labels,
        content: plaintextContent,
        reminder: reminder,
        plainText: plainText,
        createdAt: createdAt,
        updatedAt: proposedUpdatedAt,
        locked: false,
        pinned: pinned,
        trashed: trashed,
        archived: archived,
        readOnly: readOnly,
        completed: completed,
        color: color,
        attachments: workingAttachments,
      );
      final row = await detached.toJsonAsync();
      row['id'] = noteId;
      activeRecord = activeRecord.readyForCommit(row['attachments'] as String);
      await journal.put(activeRecord);

      await lockRemovalBeforeCommitOverride?.call(this);
      if (!stateFingerprint.matches(this)) {
        throw StateError(
          'The note changed in memory while its lock was being removed',
        );
      }

      await _commitLockRemovalTransaction(
        noteId: noteId,
        row: row,
        expectedRow: expectedRow,
        replacements: activeRecord.replacements,
      );
      databaseCommitted = true;

      if (!_publishAttachments(attachments, workingAttachments)) {
        attachments = workingAttachments;
      }
      content = plaintextContent;
      plainText = detached.plainText;
      _locked = false;
      _unlocked = false;
      _password = null;
      updatedAt = proposedUpdatedAt;
    } catch (error, stackTrace) {
      if (!databaseCommitted && activeRecord != null) {
        try {
          final retainedPaths =
              await NoteFileReferenceService.databaseReferencedLocalPaths(
                AppState.db,
              );
          final cleaned = await transactionService.cleanupStaged(
            activeRecord,
            retainedPaths: retainedPaths,
          );
          if (cleaned) {
            await journal.remove(activeRecord.transactionId);
          }
        } catch (cleanupError, cleanupStackTrace) {
          AppLogger.error(
            'Failed to safely clear rolled-back lock-removal files',
            cleanupError,
            cleanupStackTrace,
          );
        }
      }
      AppLogger.error('Error removing note lock', error, stackTrace);
      if (error is NoteLockRemovalException) rethrow;
      throw NoteLockRemovalException('Failed to remove note lock', error);
    }

    final committedNotifier = lockRemovalCommittedNotifierOverride;
    if (committedNotifier != null) {
      committedNotifier(this);
    } else {
      notify('updated', false);
      unawaited(NoteSyncService().sync());
    }

    try {
      final retainedPaths =
          await NoteFileReferenceService.databaseReferencedLocalPaths(
            AppState.db,
          );
      final cleaned = await transactionService.cleanupOriginals(
        activeRecord,
        retainedPaths: retainedPaths,
      );
      if (cleaned) {
        await journal.remove(activeRecord.transactionId);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Note lock removed; original-file cleanup will retry at startup',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _commitLockRemovalTransaction({
    required int noteId,
    required Map<String, Object?> row,
    required Map<String, Object?> expectedRow,
    required List<NoteLockFileReplacement> replacements,
  }) async {
    await AppState.db.transaction((transaction) async {
      final currentRows = await transaction.query(
        model,
        where: 'id = ?',
        whereArgs: [noteId],
        limit: 1,
      );
      if (currentRows.isEmpty ||
          !mapEquals(
            Map<String, Object?>.from(currentRows.single),
            expectedRow,
          )) {
        throw StateError(
          'The note changed while its lock was being removed; reload and retry',
        );
      }
      final updated = await transaction.update(
        model,
        row,
        where: 'id = ?',
        whereArgs: [noteId],
      );
      if (updated != 1) {
        throw StateError('The unlocked note could not be persisted');
      }

      for (final replacement in replacements) {
        final oldPath = replacement.oldPath;
        if (oldPath == null ||
            oldPath.isEmpty ||
            oldPath.startsWith('data:') ||
            oldPath.startsWith('http://') ||
            oldPath.startsWith('https://')) {
          continue;
        }
        await transaction.rawUpdate(
          '''
          UPDATE file_sync_track
          SET local_path = ?, content_hash = NULL
          WHERE note_id = ? AND local_path = ?
          ''',
          [replacement.newPath, noteId, oldPath],
        );
      }

      final syncRows = await transaction.query(
        NoteSyncTrack.model,
        where: 'local_id = ?',
        whereArgs: [noteId],
        limit: 1,
      );
      final syncTime = DateTime.now().toIso8601String();
      if (syncRows.isEmpty) {
        await transaction.insert(NoteSyncTrack.model, {
          'local_id': noteId,
          'action': SyncAction.upload.name,
          'status': SyncStatus.pending.name,
          'created_at': syncTime,
          'updated_at': syncTime,
        });
      } else if (syncRows.single['action'] != SyncAction.delete.name) {
        await transaction.update(
          NoteSyncTrack.model,
          {
            'action': SyncAction.upload.name,
            'status': SyncStatus.pending.name,
            'updated_at': syncTime,
          },
          where: 'id = ?',
          whereArgs: [syncRows.single['id']],
        );
      }
    });
  }

  Future<void> _migrateSketchesToStrokesFiles({
    bool rewriteLoadedStrokes = false,
  }) async {
    final fs = await fileSystem();

    for (final attachment in attachments) {
      if (attachment.type != AttachmentType.sketch) continue;

      final sketch = attachment.sketch;
      if (sketch == null) continue;

      // The one-time converter owns this ciphertext. A normal save may
      // preserve it, but must never reinterpret it as an empty drawing.
      if (sketch.requiresLegacyMigration) continue;

      // Normal saves only migrate missing files. Locking also flushes loaded
      // strokes so clearing memory can never discard a newer drawing state.
      if (sketch.hasStrokesFile &&
          (!rewriteLoadedStrokes || sketch.strokes.isEmpty)) {
        continue;
      }

      final strokesFilePath = sketch.hasStrokesFile
          ? sketch.strokesFilePath!
          : path.join(await fs.documentDir, '${Uuid().v4()}.json');

      final strokesJson = json.encode(sketch.toStrokesFileJson());
      await writeEncryptedBytes(
        strokesFilePath,
        Uint8List.fromList(utf8.encode(strokesJson)),
      );

      sketch.strokesFilePath = strokesFilePath;
      AppLogger.log('Migrated sketch to strokes file: $strokesFilePath');
    }
  }

  static void _clearSketchStrokes(List<NoteAttachment> targetAttachments) {
    for (final attachment in targetAttachments) {
      if (attachment.type != AttachmentType.sketch) continue;
      final sketch = attachment.sketch;
      if (sketch == null) continue;
      sketch.strokes = [];
      sketch.markStrokesUnhydrated();
      sketch.encryptedStrokes = null;
    }
  }

  /// Generates local-only privacy thumbnails from attachment files which are
  /// currently readable in plaintext.
  ///
  /// Callers must run this before password encryption or after successful PIN
  /// decryption. The returned value reports whether attachment metadata changed
  /// so repair flows can persist it with an attachment-only guarded update.
  Future<bool> generateMissingAttachmentThumbnails({
    Future<Uint8List> Function(String path)? readBytes,
  }) => _generateMissingAttachmentThumbnails(attachments, readBytes: readBytes);

  static Future<bool> _generateMissingAttachmentThumbnails(
    List<NoteAttachment> targetAttachments, {
    Future<Uint8List> Function(String path)? readBytes,
  }) async {
    final fs = await fileSystem();
    var changed = false;

    for (final attachment in targetAttachments) {
      try {
        if (attachment.type == AttachmentType.image) {
          final image = attachment.image;
          if (image == null || image.blurredThumbnail != null) continue;

          final path = image.src;
          if (path.isEmpty || !await fs.exists(path)) continue;

          final data = await (readBytes ?? readEncryptedBytes)(path);
          final thumbnail = await ThumbnailGenerator.generateFromBytes(data);
          if (thumbnail != null) {
            image.blurredThumbnail = thumbnail;
            changed = true;
            AppLogger.log('Generated thumbnail for image: $path');
          }
        } else if (attachment.type == AttachmentType.sketch) {
          final sketch = attachment.sketch;
          if (sketch == null || sketch.blurredThumbnail != null) continue;

          final path = sketch.previewImage;
          if (path == null || path.isEmpty || !await fs.exists(path)) continue;

          final data = await (readBytes ?? readEncryptedBytes)(path);
          final thumbnail = await ThumbnailGenerator.generateFromBytes(data);
          if (thumbnail != null) {
            sketch.blurredThumbnail = thumbnail;
            changed = true;
            AppLogger.log('Generated thumbnail for sketch: $path');
          }
        }
      } catch (e) {
        AppLogger.error('Error generating thumbnail', e);
      }
    }

    return changed;
  }

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
        if (attachment.sketch?.strokesFilePath != null) {
          paths.add(attachment.sketch!.strokesFilePath!);
        }
        return paths;
      case AttachmentType.audio:
        final src = attachment.recording?.src;
        return src != null ? [src] : [];
    }
  }

  Future<void> addImage(NoteImage image) => _enqueueMutation(() async {
    if (hasImage(image)) return;
    await _commitNewFileAttachment(
      sourcePath: image.src,
      buildAttachment: (committedPath) => NoteAttachment.image(
        NoteImage(
          src: committedPath,
          size: image.size,
          index: image.index,
          aspectRatio: image.aspectRatio,
          lastModified: image.lastModified,
          blurredThumbnail: image.blurredThumbnail,
        ),
      ),
      publishCommittedPath: (committedPath, attachment) {
        image.src = committedPath;
        attachment.image = image;
      },
    );
  });

  Future<void> _commitNewFileAttachment({
    required String sourcePath,
    required NoteAttachment Function(String committedPath) buildAttachment,
    required void Function(String committedPath, NoteAttachment attachment)
    publishCommittedPath,
  }) async {
    PreparedNewAttachmentFile? prepared;
    NewAttachmentTransactionService? transactionService;
    NoteAttachment? pendingAttachment;
    var databaseCommitted = false;
    var committedPath = sourcePath;

    try {
      if (_locked) {
        if (!_unlocked || _password == null || _password!.isEmpty) {
          throw const NoteAttachmentCommitException(
            NoteAttachmentCommitFailure.authentication,
            'Unlock the note before adding an attachment',
          );
        }
        final operations =
            lockFileOperationsOverride ??
            await NoteLockFileOperations.platform();
        final journal =
            newAttachmentJournalOverride ??
            NewAttachmentTransactionJournal(await AppState.prefs);
        transactionService = NewAttachmentTransactionService(
          operations: operations,
          journal: journal,
        );
        prepared = await transactionService.prepare(
          sourcePath: sourcePath,
          readForSession: newAttachmentReadOverride ?? readAttachmentForSession,
          writeForSession:
              newAttachmentWriteOverride ?? writeAttachmentForSession,
        );
        committedPath = prepared.stagedPath;
      }

      final attachment = buildAttachment(committedPath);
      pendingAttachment = attachment;
      attachments.add(attachment);
      final result = await _saveWithinMutation();
      if (result < 0) {
        attachments.remove(attachment);
        throw const NoteAttachmentCommitException(
          NoteAttachmentCommitFailure.persistence,
          'The attachment could not be saved',
        );
      }

      databaseCommitted = true;
      publishCommittedPath(committedPath, attachment);
      pendingAttachment = null;

      if (prepared != null && transactionService != null) {
        try {
          final cleaned = await transactionService.finishCommitted(
            prepared,
            AppState.db,
          );
          if (!cleaned) {
            AppLogger.log(
              'Attachment committed; source cleanup deferred to startup',
            );
          }
        } catch (error, stackTrace) {
          // SQLite already owns the staged path. Retain the journal and let
          // startup recovery perform reference-safe cleanup.
          AppLogger.error(
            'Attachment committed but cleanup was deferred',
            error,
            stackTrace,
          );
        }
      }
    } catch (error, stackTrace) {
      if (databaseCommitted) {
        // SQLite already owns the attachment. Never roll back or invite a
        // duplicate retry after a post-commit in-memory/cleanup failure.
        AppLogger.error(
          'Attachment committed with deferred in-memory cleanup',
          error,
          stackTrace,
        );
        return;
      }
      if (pendingAttachment != null) {
        attachments.remove(pendingAttachment);
      }
      if (prepared != null && transactionService != null) {
        try {
          await transactionService.rollback(prepared);
        } catch (cleanupError, cleanupStackTrace) {
          AppLogger.error(
            'Failed to roll back staged attachment files',
            cleanupError,
            cleanupStackTrace,
          );
        }
      }
      if (error is NoteAttachmentCommitException) rethrow;
      final failure = switch (error) {
        NewAttachmentPreparationException(
          failure: NewAttachmentPreparationFailure.sourceUnavailable,
        ) =>
          NoteAttachmentCommitFailure.sourceUnavailable,
        NewAttachmentPreparationException(
          failure: NewAttachmentPreparationFailure.verification,
        ) =>
          NoteAttachmentCommitFailure.verification,
        NewAttachmentPreparationException() =>
          NoteAttachmentCommitFailure.protection,
        _ => NoteAttachmentCommitFailure.persistence,
      };
      AppLogger.error('Failed to commit a new attachment', error, stackTrace);
      throw NoteAttachmentCommitException(
        failure,
        'The attachment could not be added safely',
        error,
      );
    }
  }

  Future<void> _protectNewAttachment(NoteAttachment attachment) async {
    if (!_locked) return;

    final password = _password;
    if (password == null || password.isEmpty) {
      throw const NoteRelockException(
        'Cannot add an attachment to a locked note without its cached PIN',
      );
    }

    for (final path in _getAttachmentPaths(attachment)) {
      await _encryptSingleAttachment(path, password);
    }
  }

  /// Encrypts a single attachment file with the note's password.
  Future<void> _encryptSingleAttachment(String? path, String password) async {
    if (path == null || path.isEmpty) {
      throw const NoteRelockException(
        'A protected attachment is missing its local source path',
      );
    }

    final fs = await fileSystem();
    if (!await fs.exists(path)) {
      throw NoteRelockException(
        'A protected attachment source is unavailable locally',
        path,
      );
    }

    try {
      final data = await readEncryptedBytes(path);
      if (isBytesPasswordEncrypted(data)) return; // Already encrypted

      final encrypted = await encryptBytesWithPassword(data, password);
      await writeEncryptedBytes(path, encrypted);
      AppLogger.log('Encrypted new attachment: $path');
    } catch (error, stackTrace) {
      AppLogger.error('Error encrypting new attachment', error, stackTrace);
      throw NoteRelockException('Failed to protect a new attachment', error);
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

  Future<NoteAttachment> removeImage(NoteImage image) =>
      _enqueueMutation(() async {
        if (!hasImage(image)) {
          throw Exception("Image not found in note attachments");
        }

        final removed = attachments.firstWhere(
          (attachment) =>
              attachment.type == AttachmentType.image &&
              attachment.image == image,
        );
        attachments.remove(removed);
        await _saveWithinMutation();
        return removed;
      });

  Future<void> addSketch(SketchData sketch) => _enqueueMutation(() async {
    if (hasSketch(sketch)) return;

    final previewImageSrc = sketch.previewImage ?? '';
    if (previewImageSrc.isEmpty) {
      snackbar("Error saving sketch, no preview available", Colors.red);
      AppLogger.error('Error adding sketch to note: no preview image');
      return;
    }

    final attachment = NoteAttachment.sketch(sketch);
    attachments.add(attachment);
    try {
      // A sketch without a strokes file is migrated before protection so a
      // post-lock edit can never publish an unprotected source path.
      if (_locked && !sketch.hasStrokesFile) {
        await _migrateSketchesToStrokesFiles();
      }
      await _protectNewAttachment(attachment);
    } catch (_) {
      attachments.remove(attachment);
      rethrow;
    }
    await _saveWithinMutation();
  });

  bool hasSketch(SketchData sketch) {
    return attachments.any(
      (attachment) =>
          attachment.type == AttachmentType.sketch &&
          attachment.sketch == sketch,
    );
  }

  Future<NoteAttachment> removeSketch(SketchData sketch) =>
      _enqueueMutation(() async {
        if (!hasSketch(sketch)) {
          throw Exception("Sketch not found in note attachments");
        }

        final index = attachments.indexWhere(
          (attachment) =>
              attachment.type == AttachmentType.sketch &&
              attachment.sketch == sketch,
        );
        final removed = attachments[index];
        attachments.remove(removed);
        final result = await _saveWithinMutation();
        if (result < 0) {
          attachments.insert(index, removed);
          throw const NoteSketchSaveException('Failed to delete the sketch');
        }
        await _deleteSketchFiles(sketch);
        return removed;
      });

  /// Deletes local files associated with a sketch (preview image, strokes file, background image).
  Future<void> _deleteSketchFiles(SketchData sketch) async {
    try {
      final fs = await fileSystem();
      final files = <String>[];

      if (sketch.previewImage != null && sketch.previewImage!.isNotEmpty) {
        files.add(sketch.previewImage!);
      }
      if (sketch.strokesFilePath != null &&
          sketch.strokesFilePath!.isNotEmpty) {
        files.add(sketch.strokesFilePath!);
      }
      if (sketch.backgroundImage != null &&
          sketch.backgroundImage!.isNotEmpty) {
        files.add(sketch.backgroundImage!);
      }

      for (final file in files) {
        if (await fs.exists(file)) {
          await fs.delete(file);
          AppLogger.log('Deleted sketch file: $file');
        }
      }
    } catch (e) {
      AppLogger.error('Error deleting sketch files', e);
    }
  }

  Future<void> addRecording(NoteRecording recording) =>
      _enqueueMutation(() async {
        if (hasRecording(recording.src)) return;
        await _commitNewFileAttachment(
          sourcePath: recording.src,
          buildAttachment: (committedPath) => NoteAttachment.audio(
            NoteRecording(
              src: committedPath,
              title: recording.title,
              length: recording.length,
              transcript: recording.transcript,
            ),
          ),
          publishCommittedPath: (committedPath, attachment) {
            recording.src = committedPath;
            attachment.recording = recording;
          },
        );
      });

  Future<void> updateRecording(NoteRecording recording) =>
      _enqueueMutation(() async {
        final index = attachments.indexWhere(
          (attachment) =>
              attachment.type == AttachmentType.audio &&
              attachment.recording!.src == recording.src,
        );
        if (index != -1) {
          attachments[index].recording = recording;
          await _saveWithinMutation();
        }
      });

  bool hasRecording(String src) {
    return attachments.any(
      (attachment) =>
          attachment.type == AttachmentType.audio &&
          attachment.recording!.src == src,
    );
  }

  Future<NoteAttachment> removeRecording(String src) =>
      _enqueueMutation(() async {
        if (!hasRecording(src)) {
          throw Exception("Audio recording not found in note attachments");
        }

        final removed = attachments.firstWhere(
          (attachment) =>
              attachment.type == AttachmentType.audio &&
              attachment.recording!.src == src,
        );
        attachments.remove(removed);
        await _saveWithinMutation();
        return removed;
      });

  Future<int> done() async {
    // Check if this is a repeating reminder
    if (reminder != null && reminder!.isRepeating) {
      // Schedule the next occurrence
      final currentReminder = reminder!;
      final nextReminder = currentReminder.getNextOccurrence();
      if (nextReminder != null) {
        reminder = nextReminder.copyWith(
          revision: currentReminder.revision + 1,
        );
        completed = false; // Keep it active for repeating reminders
        final rowId = await save();
        if (rowId >= 0) await ReminderCoordinator.instance.schedule(this);
        return rowId;
      }
    }

    // Non-repeating reminder: mark as completed
    completed = true;
    final rowId = await save();
    if (rowId >= 0 && id != null) {
      await ReminderCoordinator.instance.cancel(id!);
    }
    return rowId;
  }

  /// Delete the reminder from this note entirely
  Future<int> deleteReminder() async {
    final previousReminder = reminder;
    final previousCompleted = completed;
    reminder = null;
    completed = false;
    final rowId = await save();
    if (rowId < 0) {
      reminder = previousReminder;
      completed = previousCompleted;
      return rowId;
    }
    if (id != null) await ReminderCoordinator.instance.cancel(id!);
    return rowId;
  }

  Future<int> setContent(String newContent, String newPlainText) =>
      _enqueueMutation(() async {
        if (_locked &&
            (!_unlocked || _password == null || _password!.isEmpty)) {
          throw const NoteRelockException(
            'Cannot edit a locked note without an authenticated PIN session',
          );
        }
        content = newContent;
        plainText = newPlainText;
        return _saveWithinMutation();
      });

  /// Persists one immutable editor snapshot as a single model mutation.
  ///
  /// When a lock command is already queued, this operation runs afterward and
  /// uses the cached PIN to serialize the newer edit as protected content.
  Future<int> saveEditorSnapshot({
    required String title,
    required String content,
    required String plainText,
    bool trackSync = true,
  }) => _enqueueMutation(() async {
    if (_locked) {
      if (!_unlocked || _password == null || _password!.isEmpty) {
        throw const NoteRelockException(
          'Cannot edit a locked note without an authenticated PIN session',
        );
      }
    }
    this.title = title;
    this.content = content;
    this.plainText = plainText;
    return _saveWithinMutation(trackSync);
  });

  /// Decrypts one password-protected attachment for the authenticated process
  /// session without changing the canonical attachment file.
  ///
  /// The optimistic session check prevents a decoder that outlives
  /// [clearPassword] or lock removal from publishing plaintext playback data.
  Future<Uint8List> decryptAttachmentForSession(
    Uint8List protectedBytes,
  ) async {
    if (!_locked || !_unlocked) {
      throw const NoteUnlockException(
        'The locked note has no authenticated session',
      );
    }
    final password = _password;
    if (password == null || password.isEmpty) {
      throw const NoteUnlockException(
        'The authenticated note session has no cached PIN',
      );
    }
    if (!isBytesPasswordEncrypted(protectedBytes)) {
      throw const NoteUnlockException(
        'The attachment is not password-protected',
      );
    }

    late final Uint8List plaintext;
    try {
      plaintext =
          await (pinAttachmentDecryptOverride ?? decryptBytesWithPassword)(
            protectedBytes,
            password,
          );
    } catch (error) {
      throw NoteUnlockException(
        'The protected attachment could not be decrypted: $error',
      );
    }

    if (!_locked || !_unlocked || _password != password) {
      throw const NoteUnlockException(
        'The authenticated note session ended during decryption',
      );
    }
    if (plaintext.isEmpty ||
        isBytesPasswordEncrypted(plaintext) ||
        LocalDataEncryption.isBytesEncrypted(plaintext)) {
      throw const NoteUnlockException(
        'The protected attachment failed decryption verification',
      );
    }
    return plaintext;
  }

  /// Reads a canonical attachment for the current authenticated session.
  ///
  /// Local at-rest encryption is removed first. PIN-protected bytes are then
  /// decrypted only in memory; the canonical file is never rewritten.
  Future<Uint8List> readAttachmentForSession(String filePath) async {
    if (filePath.isEmpty || filePath.startsWith('http')) {
      throw const NoteUnlockException(
        'A local attachment path is required for reading',
      );
    }
    if (_locked && (!_unlocked || _password == null || _password!.isEmpty)) {
      throw const NoteUnlockException(
        'The locked note has no authenticated session',
      );
    }

    final expectedPassword = _password;
    if (filePath.startsWith('data:')) {
      final decoded = _decodeInlineAttachment(filePath);
      if (_locked && (!_unlocked || _password != expectedPassword)) {
        throw const NoteUnlockException(
          'The authenticated note session ended while reading an attachment',
        );
      }
      if (!_locked || !isBytesPasswordEncrypted(decoded)) return decoded;
      return decryptAttachmentForSession(decoded);
    }
    final storedBytes = await readEncryptedBytes(filePath);
    if (!_locked) return storedBytes;

    if (!_unlocked || _password != expectedPassword) {
      throw const NoteUnlockException(
        'The authenticated note session ended while reading an attachment',
      );
    }
    if (!isBytesPasswordEncrypted(storedBytes)) {
      // Compatibility for sources exposed by the previous unlock behavior.
      // The authenticated protection repair replaces them with ENCP copies.
      return storedBytes;
    }
    return decryptAttachmentForSession(storedBytes);
  }

  static Uint8List _decodeInlineAttachment(String source) {
    final comma = source.indexOf(',');
    if (comma < 0) {
      throw const NoteUnlockException('Inline attachment data is invalid');
    }
    final metadata = source.substring(0, comma).toLowerCase();
    final payload = source.substring(comma + 1);
    try {
      if (metadata.endsWith(';base64')) {
        return base64Decode(payload);
      }
      return utf8.encode(Uri.decodeComponent(payload));
    } catch (error) {
      throw NoteUnlockException('Inline attachment data is invalid: $error');
    }
  }

  /// Writes attachment content without moving a locked source outside the PIN
  /// boundary. The caller keeps the plaintext only in its authenticated UI
  /// state; the canonical file remains password-protected on disk.
  Future<void> writeAttachmentForSession(
    String filePath,
    Uint8List plaintext,
  ) async {
    if (filePath.isEmpty || filePath.startsWith('http')) {
      throw const NoteRelockException(
        'A local attachment path is required for saving',
      );
    }
    if (plaintext.isEmpty || isBytesPasswordEncrypted(plaintext)) {
      throw const NoteRelockException(
        'Attachment plaintext is empty or already password-protected',
      );
    }
    if (!_locked) {
      await writeEncryptedBytes(filePath, plaintext);
      return;
    }
    if (!_unlocked) {
      throw const NoteRelockException(
        'Cannot save a locked attachment without an authenticated session',
      );
    }
    final password = _password;
    if (password == null || password.isEmpty) {
      throw const NoteRelockException(
        'The authenticated note session has no cached PIN',
      );
    }

    late final Uint8List protectedBytes;
    try {
      protectedBytes = await encryptBytesWithPassword(plaintext, password);
    } catch (error) {
      throw NoteRelockException('Failed to protect attachment changes', error);
    }
    if (!_locked || !_unlocked || _password != password) {
      throw const NoteRelockException(
        'The authenticated note session ended while saving an attachment',
      );
    }
    if (!isBytesPasswordEncrypted(protectedBytes)) {
      throw const NoteRelockException(
        'Attachment changes were not password-protected',
      );
    }
    await writeEncryptedBytes(filePath, protectedBytes);
  }

  Future<ReminderUpdateResult> setReminder(
    Reminder newReminder, {
    ReminderScheduleCallback? schedule,
  }) async {
    final nextRevision = (reminder?.revision ?? 0) + 1;
    final previousReminder = reminder;
    final previousCompleted = completed;
    reminder = newReminder.copyWith(revision: nextRevision);
    completed = false;
    final rowId = await save();
    if (rowId < 0) {
      reminder = previousReminder;
      completed = previousCompleted;
      return ReminderUpdateResult(rowId: rowId);
    }
    final savedReminder = reminder!;
    final delivery = await (schedule != null
        ? schedule(this)
        : ReminderCoordinator.instance.schedule(
            this,
            requestPermissions: true,
          ));
    return ReminderUpdateResult(
      rowId: rowId,
      savedReminder: savedReminder,
      delivery: delivery,
    );
  }

  /// Compatibility entry point retained for callers that previously requested
  /// alarm-only scheduling after sync or permission changes.
  Future<void> setAlarm() async {
    if (id == null || reminder == null || completed || trashed) return;
    await ReminderCoordinator.instance.schedule(this);
  }

  Future<T> _enqueueMutation<T>(Future<T> Function() action) {
    return _mutationQueue.run(action);
  }

  /// Runs a complete sketch file/model update in the same per-note ordering
  /// domain as [save], [lock], [unlock], and [removeLock].
  ///
  /// The callback must finish every required file write before publishing its
  /// attachment mutations. It must not call another queued [Note] method.
  Future<void> persistSketchMutation(
    Future<void> Function() mutation, {
    bool trackSync = true,
  }) => _enqueueMutation(() async {
    if (_locked && (!_unlocked || _password == null || _password!.isEmpty)) {
      throw const NoteSketchSaveException(
        'Cannot save a locked sketch without an authenticated PIN session',
      );
    }
    await mutation();
    final result = await _saveWithinMutation(trackSync);
    if (result < 0) {
      throw const NoteSketchSaveException('Failed to save the sketch');
    }
  });

  Future<int> save([
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  ]) => _enqueueMutation(() => _saveWithinMutation(trackSync, origin));

  Future<int> _saveWithinMutation([
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  ]) async {
    if (isEmpty) {
      return Future.value(-1);
    }
    syncId ??= const Uuid().v4();

    // Migrate any old sketches to new strokes file format before saving. A
    // failed source write must prevent attachment metadata from being saved.
    try {
      await _migrateSketchesToStrokesFiles();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to persist sketch source data',
        error,
        stackTrace,
      );
      snackbar('Failed to save the note', Colors.red);
      return -1;
    }

    final previousUpdatedAt = updatedAt;

    // Only update timestamp for local changes, not when syncing from remote
    if (trackSync) {
      updatedAt = DateTime.now();
    }

    late final Map<String, dynamic> jsonObj;
    try {
      jsonObj = await toJsonAsync();
    } catch (error, stackTrace) {
      updatedAt = previousUpdatedAt;
      AppLogger.error('Failed to serialize note safely', error, stackTrace);
      snackbar('Failed to save the note', Colors.red);
      return -1;
    }

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
          notify("updated", trackSync, origin);
          return id!;
        } catch (e) {
          updatedAt = previousUpdatedAt;
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
    jsonObj['sync_id'] = syncId;
    if (jsonObj['created_at'] == null) {
      jsonObj['created_at'] = DateTime.now().toIso8601String();
    }

    try {
      await AppState.db.insert(model, jsonObj);
      notify("created", trackSync, origin);
      return id!;
    } catch (e) {
      updatedAt = previousUpdatedAt;
      snackbar("Failed to save the note", Colors.red);
      AppLogger.log("Error saving note: $e");
      id = null;
      return -1;
    }
  }

  Future<void> moveToTrash() async {
    final previousTrashed = trashed;
    final previousArchived = archived;
    final previousPinned = pinned;
    final previousReadOnly = readOnly;
    trashed = true;
    archived = false;
    pinned = false;
    readOnly = true;
    final rowId = await save();
    if (rowId < 0) {
      trashed = previousTrashed;
      archived = previousArchived;
      pinned = previousPinned;
      readOnly = previousReadOnly;
      return;
    }
    if (id != null) await ReminderCoordinator.instance.cancel(id!);

    // Revoke all share links for this note
    final noteId = id?.toString();
    if (noteId != null && noteId.isNotEmpty) {
      await NoteShareService().revokeAllSharesForNote(noteId);
    }
  }

  Future<void> restoreFromTrash() async {
    final previousTrashed = trashed;
    final previousReadOnly = readOnly;
    trashed = false;
    readOnly = false;
    final rowId = await save();
    if (rowId < 0) {
      trashed = previousTrashed;
      readOnly = previousReadOnly;
      return;
    }

    if (reminder != null && !completed) {
      await ReminderCoordinator.instance.schedule(this);
    }
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
            if (attachment.sketch!.strokesFilePath != null) {
              files.add(attachment.sketch!.strokesFilePath!);
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

  Future<int> delete({
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  }) async {
    // If id is null, the note was never saved - nothing to delete
    if (id == null) {
      return 0;
    }

    // Capture the note id before deletion for sync tracking
    final noteId = id!;

    if (trackSync) {
      await _updateSyncTrack(SyncAction.delete);
    }

    int result = await AppState.db.delete(
      model,
      where: "id = ?",
      whereArgs: [noteId],
    );
    try {
      await ReminderCoordinator.instance.forget(noteId);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Note deleted but reminder cleanup failed',
        error,
        stackTrace,
      );
    }
    await _deleteLocalFiles();
    super.notifyWithOrigin("deleted", origin);
    return result;
  }

  Future<Map<String, dynamic>> toJsonAsync() async {
    String? contentToSave = content;
    String? plainTextToSave = plainText;

    if (_locked && _unlocked) {
      if (_password == null || _password!.isEmpty) {
        throw const NoteRelockException(
          'Cannot serialize an unlocked locked note without its PIN',
        );
      }
      try {
        contentToSave = await _encryptPinContent(content ?? '', _password!);
      } catch (error) {
        throw NoteRelockException(
          'Failed to protect locked note content for storage',
          error,
        );
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

    final attachmentsJson = await serializeAttachmentsForLocalStorage();

    return {
      'id': id,
      'sync_id': syncId,
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

  /// Serializes attachments exactly as they are stored in the local database.
  /// This is intentionally separate from [toJsonAsync] so local maintenance
  /// tasks can update attachment metadata without writing a stale whole note.
  Future<String> serializeAttachmentsForLocalStorage() async {
    final localEncryption = LocalDataEncryption.instance;
    final policy = _locked
        ? _AttachmentSerializationPolicy.lockedPinBoundary
        : _AttachmentSerializationPolicy.standard;

    // Encrypt sketch data within attachments if files encryption is enabled.
    final encryptedAttachments = <Map<String, dynamic>>[];
    for (final attachment in attachments) {
      final attachmentJson = attachment.toJson();

      // Encrypt sketch metadata (strokes, bgColor, pagePattern) if files encryption is enabled
      if (attachment.type == AttachmentType.sketch &&
          attachment.sketch != null) {
        final sketch = attachment.sketch!;
        if (policy == _AttachmentSerializationPolicy.lockedPinBoundary) {
          // Never duplicate hydrated locked strokes under the app-wide local
          // key. Preserve only a value that already existed so authenticated
          // recovery can migrate the last surviving source without data loss.
          if (sketch.hasEncryptedMetadata) {
            attachmentJson['data'] = {
              ...Map<String, dynamic>.from(
                attachmentJson['data'] as Map<String, dynamic>,
              ),
              'encrypted_metadata': sketch.encryptedMetadata,
            };
          }
          encryptedAttachments.add(attachmentJson);
          continue;
        }
        final sketchMetadata = json.encode({
          'strokes': sketch.strokes.map((s) => s.toString()).toList(),
          'bgColor': sketch.backgroundColor.toARGB32(),
          'pagePattern': sketch.pagePattern.name,
        });
        final metadataEncryptor = localSketchMetadataEncryptOverride;
        final encryptedMetadata = metadataEncryptor != null
            ? await metadataEncryptor(sketchMetadata)
            : await localEncryption.encryptAttachmentMetadata(sketchMetadata);

        // If encrypted (different from original), store as encrypted field
        if (encryptedMetadata != sketchMetadata) {
          attachmentJson['data'] = {
            'encrypted_metadata': encryptedMetadata,
            'previewImage': sketch.previewImage,
            'backgroundImage': sketch.backgroundImage,
            'aspectRatio': sketch.aspectRatio,
            if (sketch.strokesFilePath != null)
              'strokesFilePath': sketch.strokesFilePath,
            if (sketch.strokesContentHash != null)
              'strokesContentHash': sketch.strokesContentHash,
            if (sketch.blurredThumbnail != null)
              'blurredThumbnail': sketch.blurredThumbnail,
            if (sketch.hasEncryptedStrokes)
              'encryptedStrokes': sketch.encryptedStrokes,
          };
        }
      }

      encryptedAttachments.add(attachmentJson);
    }

    return json.encode(encryptedAttachments);
  }

  /// Updates only local attachment metadata when the database row still
  /// matches the snapshot used to produce it.
  ///
  /// Guarding both values catches ordinary edits as well as sync writes that
  /// preserve or reuse an `updated_at` timestamp.
  static Future<bool> updateAttachmentsIfUnchanged({
    required int id,
    required Object? expectedUpdatedAt,
    required Object? expectedAttachments,
    required String attachments,
  }) async {
    final updatedRows = await AppState.db.rawUpdate(
      '''
      UPDATE note
      SET attachments = ?
      WHERE id = ?
        AND updated_at IS ?
        AND attachments IS ?
      ''',
      [attachments, id, expectedUpdatedAt, expectedAttachments],
    );
    return updatedRows == 1;
  }

  Map<String, dynamic> toJson() {
    final plainTextValue = _locked ? '' : (document?.toPlainText() ?? '');

    return {
      'id': id,
      'sync_id': syncId,
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

  static Future<Note?> findBySyncId(String syncId) async {
    final rows = await AppState.db.query(
      model,
      where: "sync_id = ?",
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Note.fromJsonAsync(rows.first);
  }
}

class _NoteLockStateFingerprint {
  final String value;
  final String? password;

  const _NoteLockStateFingerprint(this.value, this.password);

  factory _NoteLockStateFingerprint.capture(Note note) =>
      _NoteLockStateFingerprint(
        jsonEncode({
          'id': note.id,
          'title': note.title,
          'labels': note.labels,
          'content': note.content,
          'plainText': note.plainText,
          'locked': note._locked,
          'unlocked': note._unlocked,
          'pinned': note.pinned,
          'trashed': note.trashed,
          'archived': note.archived,
          'readOnly': note.readOnly,
          'completed': note.completed,
          'color': note.color.toARGB32(),
          'reminder': note.reminder?.toJson(),
          'createdAt': note.createdAt?.toIso8601String(),
          'updatedAt': note.updatedAt?.toIso8601String(),
          'attachments': note.attachments
              .map(_attachmentLockFingerprint)
              .toList(growable: false),
        }),
        note._password,
      );

  bool matches(Note note) {
    final current = _NoteLockStateFingerprint.capture(note);
    return value == current.value && password == current.password;
  }
}

/// Serializes mutations for one model instance without letting a failed
/// operation prevent later work from running.
class _AsyncMutationQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

Map<String, Object?> _attachmentLockFingerprint(NoteAttachment attachment) {
  switch (attachment.type) {
    case AttachmentType.image:
      return {'type': 'image', 'data': attachment.image!.toJson()};
    case AttachmentType.audio:
      return {'type': 'audio', 'data': attachment.recording!.toJson()};
    case AttachmentType.sketch:
      final sketch = attachment.sketch!;
      return {
        'type': 'sketch',
        'previewImage': sketch.previewImage,
        'backgroundImage': sketch.backgroundImage,
        'aspectRatio': sketch.aspectRatio,
        'backgroundColor': sketch.backgroundColor.toARGB32(),
        'pagePattern': sketch.pagePattern.name,
        'blurredThumbnail': sketch.blurredThumbnail,
        'encryptedStrokes': sketch.encryptedStrokes,
        'encryptedMetadata': sketch.encryptedMetadata,
        'strokesFilePath': sketch.strokesFilePath,
        'strokesContentHash': sketch.strokesContentHash,
        'legacyState': sketch.legacyMigrationState.name,
        'legacyError': sketch.legacyMigrationError,
        'strokesHydrated': sketch.hasHydratedStrokeSource,
        'strokes': sketch.strokes
            .map((stroke) => stroke.toString())
            .toList(growable: false),
      };
  }
}

List<NoteAttachment> _deepCopyAttachments(List<NoteAttachment> attachments) =>
    attachments
        .map((attachment) {
          switch (attachment.type) {
            case AttachmentType.image:
              final image = attachment.image!;
              return NoteAttachment.image(
                NoteImage(
                  src: image.src,
                  size: image.size,
                  index: image.index,
                  aspectRatio: image.aspectRatio,
                  lastModified: image.lastModified,
                  blurredThumbnail: image.blurredThumbnail,
                ),
              );
            case AttachmentType.audio:
              final recording = attachment.recording!;
              return NoteAttachment.audio(
                NoteRecording(
                  src: recording.src,
                  length: recording.length,
                  title: recording.title,
                  transcript: recording.transcript,
                ),
              );
            case AttachmentType.sketch:
              final sketch = attachment.sketch!;
              return NoteAttachment.sketch(
                SketchData(
                  previewImage: sketch.previewImage,
                  backgroundImage: sketch.backgroundImage,
                  aspectRatio: sketch.aspectRatio,
                  strokes: sketch.strokes
                      .map(
                        (stroke) => SketchStroke(
                          points: stroke.points,
                          color: stroke.color,
                          size: stroke.size,
                          tool: stroke.tool,
                        ),
                      )
                      .toList(growable: false),
                  backgroundColor: sketch.backgroundColor,
                  pagePattern: sketch.pagePattern,
                  blurredThumbnail: sketch.blurredThumbnail,
                  encryptedStrokes: sketch.encryptedStrokes,
                  encryptedMetadata: sketch.encryptedMetadata,
                  strokesFilePath: sketch.strokesFilePath,
                  strokesContentHash: sketch.strokesContentHash,
                  legacyMigrationState: sketch.legacyMigrationState,
                  legacyMigrationError: sketch.legacyMigrationError,
                  strokesHydrated: sketch.hasHydratedStrokeSource,
                ),
              );
          }
        })
        .toList(growable: false);

bool _publishAttachments(
  List<NoteAttachment> live,
  List<NoteAttachment> prepared,
) {
  if (live.length != prepared.length) {
    return false;
  }

  for (var index = 0; index < live.length; index++) {
    final target = live[index];
    final source = prepared[index];
    if (target.type != source.type) {
      return false;
    }

    switch (target.type) {
      case AttachmentType.image:
        final targetImage = target.image!;
        final sourceImage = source.image!;
        targetImage.src = sourceImage.src;
        targetImage.size = sourceImage.size;
        targetImage.index = sourceImage.index;
        targetImage.aspectRatio = sourceImage.aspectRatio;
        targetImage.lastModified = sourceImage.lastModified;
        targetImage.blurredThumbnail = sourceImage.blurredThumbnail;
      case AttachmentType.audio:
        final targetRecording = target.recording!;
        final sourceRecording = source.recording!;
        targetRecording.src = sourceRecording.src;
        targetRecording.length = sourceRecording.length;
        targetRecording.title = sourceRecording.title;
        targetRecording.transcript = sourceRecording.transcript;
      case AttachmentType.sketch:
        final targetSketch = target.sketch!;
        final sourceSketch = source.sketch!;
        targetSketch.previewImage = sourceSketch.previewImage;
        targetSketch.backgroundImage = sourceSketch.backgroundImage;
        targetSketch.aspectRatio = sourceSketch.aspectRatio;
        targetSketch.strokes = sourceSketch.strokes;
        targetSketch.backgroundColor = sourceSketch.backgroundColor;
        targetSketch.pagePattern = sourceSketch.pagePattern;
        targetSketch.blurredThumbnail = sourceSketch.blurredThumbnail;
        targetSketch.encryptedStrokes = sourceSketch.encryptedStrokes;
        targetSketch.encryptedMetadata = sourceSketch.encryptedMetadata;
        targetSketch.strokesFilePath = sourceSketch.strokesFilePath;
        targetSketch.strokesContentHash = sourceSketch.strokesContentHash;
        targetSketch.legacyMigrationState = sourceSketch.legacyMigrationState;
        targetSketch.legacyMigrationError = sourceSketch.legacyMigrationError;
        if (sourceSketch.hasHydratedStrokeSource) {
          targetSketch.markStrokesHydrated();
        } else {
          targetSketch.markStrokesUnhydrated();
        }
    }
  }
  return true;
}

ModelSchema<Note> _createSchema() {
  final schema = _NoteSchema();
  BaseModel.registerSchema<Note>(schema);
  return schema;
}

class _NoteSchema implements ModelSchema<Note> {
  @override
  Future<void> createTable(Database db) async {
    await db.execute("""
      CREATE TABLE IF NOT EXISTS note (
        id INTEGER PRIMARY KEY,
        sync_id TEXT,
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
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_note_sync_id '
      'ON note(sync_id) WHERE sync_id IS NOT NULL',
    );
  }

  @override
  Future<void> upgradeTable(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 8 && newVersion >= 8) {
      final columns = await db.rawQuery('PRAGMA table_info(note)');
      if (!columns.any((column) => column['name'] == 'sync_id')) {
        await db.execute('ALTER TABLE note ADD COLUMN sync_id TEXT');
      }
    }
  }

  @override
  Future<List<Note>> get(List<dynamic> args) async {
    final rows = await getOrCountRows(false, args);
    final notes = await Future.wait(rows.map(Note.fromJsonAsync));
    return notes;
  }

  @override
  Future<int> count(List<dynamic> args) async {
    final rows = await getOrCountRows(true, args);
    if (rows.isNotEmpty && rows.first.containsKey('count')) {
      return rows.first['count'] as int;
    }
    return 0;
  }

  Future<List<Map<String, dynamic>>> getOrCountRows(
    bool count,
    List<dynamic> args,
  ) async {
    NoteType filter = args.isNotEmpty ? args[0] as NoteType : NoteType.all;
    List<String>? filterLabels = args.length > 1
        ? args[1] as List<String>?
        : null;
    String? searchQuery = args.length > 2 ? args[2] as String? : null;
    String? color = args.length > 3 ? args[3] as String? : null;
    bool? withoutLabel = args.length > 4 ? args[4] as bool? : null;

    List<String> whereClauses = [
      switch (filter) {
        NoteType.archived => "archived = 1",
        NoteType.locked => "locked = 1",
        NoteType.pinned => "pinned = 1",
        NoteType.trashed => "trashed = 1",
        NoteType.reminder =>
          "reminder IS NOT NULL AND trashed = 0 AND (completed = 0 OR reminder LIKE '%Daily%' OR reminder LIKE '%Weekly%' OR reminder LIKE '%Monthly%' OR reminder LIKE '%Yearly%')",
        _ => "trashed = 0 AND archived = 0",
      },
    ];

    List<String> whereArgs = [];
    if (searchQuery != null && searchQuery.isNotEmpty) {
      // Escape special characters and use parameterized query to prevent SQL injection
      final sanitizedQuery = searchQuery
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      whereClauses.add(
        "(title LIKE ? ESCAPE '\\' OR plain_text LIKE ? ESCAPE '\\')",
      );
      whereArgs.add('%$sanitizedQuery%');
      whereArgs.add('%$sanitizedQuery%');
    }

    if (color != null && color.isNotEmpty) {
      whereClauses.add("color = ?");
      whereArgs.add(color);
    }

    if (filterLabels == null || filterLabels.isEmpty) {
      if (withoutLabel == true) {
        whereClauses.add("(labels IS NULL OR labels = '')");
      }
      return await AppState.db.rawQuery('''
          SELECT ${count ? "COUNT(id) as count" : "*"}
          FROM note
          WHERE ${whereClauses.join(" AND ")}
          ORDER BY pinned DESC, updated_at DESC;
        ''', whereArgs);
    }

    final placeholders = List.filled(filterLabels.length, '?').join(', ');
    return await AppState.db.rawQuery(
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
        SELECT ${count ? "COUNT(DISTINCT n.id) as count" : "DISTINCT n.*"}
        FROM note n
        JOIN splitter s ON s.id = n.id
        WHERE ${whereClauses.join(" AND ")}
          AND s.part IN ($placeholders)
        ORDER BY n.pinned DESC, n.updated_at DESC;
      ''',
      [...whereArgs, ...filterLabels],
    );
  }
}
