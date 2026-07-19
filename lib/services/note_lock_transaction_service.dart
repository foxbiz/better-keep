import 'dart:async';
import 'dart:convert';

import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

typedef NoteLockPathExists = Future<bool> Function(String filePath);
typedef NoteLockReadBytes = Future<Uint8List> Function(String filePath);
typedef NoteLockWriteBytes =
    Future<void> Function(String filePath, Uint8List bytes);
typedef NoteLockDeletePath = Future<bool> Function(String filePath);
typedef NoteLockDocumentDirectory = Future<String> Function();
typedef NoteLockResolvePath = Future<String> Function(String filePath);
typedef NoteLockPasswordEncrypt =
    Future<Uint8List> Function(Uint8List bytes, String password);
typedef NoteLockPasswordDecrypt =
    Future<Uint8List> Function(Uint8List bytes, String password);

enum NoteLockAssetKind {
  image,
  audio,
  sketchBackground,
  sketchPreview,
  sketchStrokes,
}

enum NoteLockJournalPhase { planning, ready }

@immutable
class NoteLockFileReplacement {
  final int attachmentIndex;
  final NoteLockAssetKind kind;
  final String? oldPath;
  final String newPath;

  const NoteLockFileReplacement({
    required this.attachmentIndex,
    required this.kind,
    required this.oldPath,
    required this.newPath,
  });

  factory NoteLockFileReplacement.fromJson(Map<String, dynamic> json) {
    return NoteLockFileReplacement(
      attachmentIndex: json['attachmentIndex'] as int,
      kind: NoteLockAssetKind.values.byName(json['kind'] as String),
      oldPath: json['oldPath'] as String?,
      newPath: json['newPath'] as String,
    );
  }

  Map<String, dynamic> toJson({bool omitInlineSource = false}) => {
    'attachmentIndex': attachmentIndex,
    'kind': kind.name,
    if (oldPath != null && !(omitInlineSource && oldPath!.startsWith('data:')))
      'oldPath': oldPath,
    'newPath': newPath,
  };
}

@immutable
class NoteLockJournalRecord {
  static const int currentVersion = 1;

  final int version;
  final String transactionId;
  final int noteId;
  final NoteLockJournalPhase phase;
  final List<NoteLockFileReplacement> replacements;
  final String? expectedAttachmentsDigest;

  const NoteLockJournalRecord({
    this.version = currentVersion,
    required this.transactionId,
    required this.noteId,
    required this.phase,
    required this.replacements,
    this.expectedAttachmentsDigest,
  });

  factory NoteLockJournalRecord.fromJson(Map<String, dynamic> json) {
    return NoteLockJournalRecord(
      version: json['version'] as int? ?? 0,
      transactionId: json['transactionId'] as String,
      noteId: json['noteId'] as int,
      phase: NoteLockJournalPhase.values.byName(json['phase'] as String),
      replacements: (json['replacements'] as List<dynamic>)
          .map(
            (value) => NoteLockFileReplacement.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(growable: false),
      expectedAttachmentsDigest: json['expectedAttachmentsDigest'] as String?,
    );
  }

  NoteLockJournalRecord readyForCommit(String attachments) {
    return NoteLockJournalRecord(
      transactionId: transactionId,
      noteId: noteId,
      phase: NoteLockJournalPhase.ready,
      replacements: replacements,
      expectedAttachmentsDigest: attachmentsDigest(attachments),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'transactionId': transactionId,
    'noteId': noteId,
    'phase': phase.name,
    'replacements': replacements
        .map((replacement) => replacement.toJson(omitInlineSource: true))
        .toList(growable: false),
    if (expectedAttachmentsDigest != null)
      'expectedAttachmentsDigest': expectedAttachmentsDigest,
  };

  static String attachmentsDigest(String attachments) {
    return sha256.convert(utf8.encode(attachments)).toString();
  }
}

/// Local-only journal used to resolve an interrupted lock operation without
/// storing a PIN, plaintext note content, or stroke payloads.
class NoteLockJournal {
  static const preferenceKey = 'pending_note_lock_transactions_v1';
  static Future<void> _mutationQueue = Future<void>.value();

  final SharedPreferences preferences;

  const NoteLockJournal(this.preferences);

  Future<List<NoteLockJournalRecord>> load() async {
    final encoded = preferences.getString(preferenceKey);
    if (encoded == null || encoded.isEmpty) return const [];

    try {
      final decoded = jsonDecode(encoded) as List<dynamic>;
      return decoded
          .map(
            (value) => NoteLockJournalRecord.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where(
            (record) => record.version == NoteLockJournalRecord.currentVersion,
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to read pending note-lock transactions',
        error,
        stackTrace,
      );
      return const [];
    }
  }

  Future<void> put(NoteLockJournalRecord record) {
    return _mutate(() async {
      final records = (await load()).toList(growable: true);
      final index = records.indexWhere(
        (candidate) => candidate.transactionId == record.transactionId,
      );
      if (index == -1) {
        records.add(record);
      } else {
        records[index] = record;
      }
      await _save(records);
    });
  }

  Future<void> remove(String transactionId) {
    return _mutate(() async {
      final records = (await load())
          .where((record) => record.transactionId != transactionId)
          .toList(growable: false);
      await _save(records);
    });
  }

  static Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _save(List<NoteLockJournalRecord> records) async {
    if (records.isEmpty) {
      final removed = await preferences.remove(preferenceKey);
      if (!removed && preferences.containsKey(preferenceKey)) {
        throw StateError('Unable to clear the note-lock transaction journal');
      }
      return;
    }

    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
    if (!saved) {
      throw StateError('Unable to persist the note-lock transaction journal');
    }
  }
}

enum NoteLockRemovalJournalPhase { planning, ready }

@immutable
class NoteLockRemovalJournalRecord {
  static const int currentVersion = 1;

  final int version;
  final String transactionId;
  final int noteId;
  final NoteLockRemovalJournalPhase phase;
  final List<NoteLockFileReplacement> replacements;
  final String? expectedAttachmentsDigest;

  const NoteLockRemovalJournalRecord({
    this.version = currentVersion,
    required this.transactionId,
    required this.noteId,
    required this.phase,
    required this.replacements,
    this.expectedAttachmentsDigest,
  });

  factory NoteLockRemovalJournalRecord.fromJson(Map<String, dynamic> json) {
    return NoteLockRemovalJournalRecord(
      version: json['version'] as int? ?? 0,
      transactionId: json['transactionId'] as String,
      noteId: json['noteId'] as int,
      phase: NoteLockRemovalJournalPhase.values.byName(json['phase'] as String),
      replacements: (json['replacements'] as List<dynamic>)
          .map(
            (value) => NoteLockFileReplacement.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(growable: false),
      expectedAttachmentsDigest: json['expectedAttachmentsDigest'] as String?,
    );
  }

  NoteLockRemovalJournalRecord readyForCommit(String attachments) {
    return NoteLockRemovalJournalRecord(
      transactionId: transactionId,
      noteId: noteId,
      phase: NoteLockRemovalJournalPhase.ready,
      replacements: replacements,
      expectedAttachmentsDigest: NoteLockJournalRecord.attachmentsDigest(
        attachments,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'transactionId': transactionId,
    'noteId': noteId,
    'phase': phase.name,
    'replacements': replacements
        .map((replacement) => replacement.toJson(omitInlineSource: true))
        .toList(growable: false),
    if (expectedAttachmentsDigest != null)
      'expectedAttachmentsDigest': expectedAttachmentsDigest,
  };
}

/// Local-only journal for interrupted permanent lock-removal transactions.
/// It deliberately stores paths and digests only, never PINs or file contents.
class NoteLockRemovalJournal {
  static const preferenceKey = 'pending_note_lock_removal_transactions_v1';
  static Future<void> _mutationQueue = Future<void>.value();

  final SharedPreferences preferences;

  const NoteLockRemovalJournal(this.preferences);

  Future<List<NoteLockRemovalJournalRecord>> load() async {
    final encoded = preferences.getString(preferenceKey);
    if (encoded == null || encoded.isEmpty) return const [];

    try {
      final decoded = jsonDecode(encoded) as List<dynamic>;
      return decoded
          .map(
            (value) => NoteLockRemovalJournalRecord.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where(
            (record) =>
                record.version == NoteLockRemovalJournalRecord.currentVersion,
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to read pending note lock-removal transactions',
        error,
        stackTrace,
      );
      return const [];
    }
  }

  Future<void> put(NoteLockRemovalJournalRecord record) {
    return _mutate(() async {
      final records = (await load()).toList(growable: true);
      final index = records.indexWhere(
        (candidate) => candidate.transactionId == record.transactionId,
      );
      if (index == -1) {
        records.add(record);
      } else {
        records[index] = record;
      }
      await _save(records);
    });
  }

  Future<void> remove(String transactionId) {
    return _mutate(() async {
      final records = (await load())
          .where((record) => record.transactionId != transactionId)
          .toList(growable: false);
      await _save(records);
    });
  }

  static Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _save(List<NoteLockRemovalJournalRecord> records) async {
    if (records.isEmpty) {
      final removed = await preferences.remove(preferenceKey);
      if (!removed && preferences.containsKey(preferenceKey)) {
        throw StateError(
          'Unable to clear the note lock-removal transaction journal',
        );
      }
      return;
    }

    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
    if (!saved) {
      throw StateError(
        'Unable to persist the note lock-removal transaction journal',
      );
    }
  }
}

class NoteLockFileOperations {
  final NoteLockPathExists exists;
  final NoteLockReadBytes read;
  final NoteLockWriteBytes write;
  final NoteLockDeletePath delete;
  final NoteLockDocumentDirectory documentDirectory;
  final NoteLockPasswordEncrypt encryptWithPassword;
  final NoteLockPasswordDecrypt decryptWithPassword;
  final String Function() newId;
  final NoteLockResolvePath? resolvePath;

  const NoteLockFileOperations({
    required this.exists,
    required this.read,
    required this.write,
    required this.delete,
    required this.documentDirectory,
    required this.encryptWithPassword,
    required this.decryptWithPassword,
    required this.newId,
    this.resolvePath,
  });

  Future<String> resolve(String filePath) async =>
      resolvePath == null ? filePath : resolvePath!(filePath);

  static Future<NoteLockFileOperations> platform() async {
    final fs = await fileSystem();
    return NoteLockFileOperations(
      exists: fs.exists,
      read: readEncryptedBytes,
      write: writeEncryptedBytes,
      delete: fs.delete,
      documentDirectory: () => fs.documentDir,
      encryptWithPassword: encryptBytesWithPassword,
      decryptWithPassword: decryptBytesWithPassword,
      newId: () => const Uuid().v4(),
      resolvePath: FileUtils.fixPath,
    );
  }
}

class NoteLockPreparationException implements Exception {
  final String message;
  final Object? cause;

  const NoteLockPreparationException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class NoteLockRemovalPreparationException implements Exception {
  final String message;
  final Object? cause;

  const NoteLockRemovalPreparationException(this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

@immutable
class NoteLockPreparation {
  final NoteLockJournalRecord journalRecord;
  final List<int> clearedPreviewIndexes;

  const NoteLockPreparation({
    required this.journalRecord,
    this.clearedPreviewIndexes = const [],
  });

  List<NoteLockFileReplacement> get replacements => journalRecord.replacements;

  void apply(List<NoteAttachment> attachments) {
    for (final replacement in replacements) {
      _setAttachmentPath(attachments, replacement, replacement.newPath);
    }
    for (final attachmentIndex in clearedPreviewIndexes) {
      attachments[attachmentIndex].sketch!.previewImage = null;
    }
  }

  void revert(List<NoteAttachment> attachments) {
    for (final replacement in replacements.reversed) {
      _setAttachmentPath(attachments, replacement, replacement.oldPath);
    }
  }
}

class _PlannedAsset {
  final NoteLockFileReplacement replacement;
  final Uint8List? currentStrokes;
  final String? resolvedSourcePath;

  const _PlannedAsset(
    this.replacement, {
    this.currentStrokes,
    this.resolvedSourcePath,
  });
}

@immutable
class NoteLockRemovalPreparation {
  final NoteLockRemovalJournalRecord journalRecord;
  final List<int> clearedPreviewIndexes;

  const NoteLockRemovalPreparation({
    required this.journalRecord,
    this.clearedPreviewIndexes = const [],
  });

  List<NoteLockFileReplacement> get replacements => journalRecord.replacements;

  void apply(List<NoteAttachment> attachments) {
    for (final replacement in replacements) {
      _setAttachmentPath(attachments, replacement, replacement.newPath);
    }
    for (final attachmentIndex in clearedPreviewIndexes) {
      attachments[attachmentIndex].sketch!.previewImage = null;
    }
  }
}

class _PlaintextRemovalAsset {
  final NoteLockFileReplacement replacement;
  final Uint8List plaintext;

  const _PlaintextRemovalAsset(this.replacement, this.plaintext);
}

/// Prepares password-protected copies without mutating attachment objects or
/// overwriting the only existing copy of any source file.
class NoteLockTransactionService {
  final NoteLockFileOperations operations;

  const NoteLockTransactionService(this.operations);

  Future<NoteLockPreparation> prepare({
    required int noteId,
    required List<NoteAttachment> attachments,
    required String password,
    required NoteLockJournal journal,
  }) async {
    final transactionId = operations.newId();
    final documentDirectory = await operations.documentDirectory();
    final plannedAssets = <_PlannedAsset>[];
    final clearedPreviewIndexes = <int>[];

    for (var index = 0; index < attachments.length; index++) {
      final attachment = attachments[index];
      switch (attachment.type) {
        case AttachmentType.image:
          plannedAssets.add(
            (await _planPath(
              attachmentIndex: index,
              kind: NoteLockAssetKind.image,
              sourcePath: attachment.image!.src,
              documentDirectory: documentDirectory,
              required: true,
            ))!,
          );
        case AttachmentType.audio:
          plannedAssets.add(
            (await _planPath(
              attachmentIndex: index,
              kind: NoteLockAssetKind.audio,
              sourcePath: attachment.recording!.src,
              documentDirectory: documentDirectory,
              required: true,
            ))!,
          );
        case AttachmentType.sketch:
          final sketch = attachment.sketch!;
          if (sketch.backgroundImage != null &&
              sketch.backgroundImage!.isNotEmpty) {
            plannedAssets.add(
              (await _planPath(
                attachmentIndex: index,
                kind: NoteLockAssetKind.sketchBackground,
                sourcePath: sketch.backgroundImage!,
                documentDirectory: documentDirectory,
                required: true,
              ))!,
            );
          }

          final previewPath = sketch.previewImage;
          if (previewPath != null && previewPath.isNotEmpty) {
            final preview = await _planPath(
              attachmentIndex: index,
              kind: NoteLockAssetKind.sketchPreview,
              sourcePath: previewPath,
              documentDirectory: documentDirectory,
              required: false,
            );
            if (preview == null) {
              clearedPreviewIndexes.add(index);
            } else {
              plannedAssets.add(preview);
            }
          }

          final currentStrokes = sketch.strokes.isNotEmpty
              ? Uint8List.fromList(
                  utf8.encode(jsonEncode(sketch.toStrokesFileJson())),
                )
              : null;
          final strokesPath = sketch.strokesFilePath;
          if (currentStrokes == null &&
              (strokesPath == null || strokesPath.isEmpty)) {
            throw NoteLockPreparationException(
              'Sketch source data is unavailable locally',
            );
          }
          plannedAssets.add(
            (await _planPath(
              attachmentIndex: index,
              kind: NoteLockAssetKind.sketchStrokes,
              sourcePath: strokesPath,
              documentDirectory: documentDirectory,
              required: currentStrokes == null,
              forcedExtension: '.json',
              currentStrokes: currentStrokes,
            ))!,
          );
      }
    }

    final record = NoteLockJournalRecord(
      transactionId: transactionId,
      noteId: noteId,
      phase: NoteLockJournalPhase.planning,
      replacements: plannedAssets
          .map((asset) => asset.replacement)
          .toList(growable: false),
    );
    await journal.put(record);

    try {
      for (final asset in plannedAssets) {
        final plaintext =
            asset.currentStrokes ??
            await _readSource(asset.resolvedSourcePath!, password);
        if (plaintext.isEmpty) {
          throw NoteLockPreparationException(
            '${asset.replacement.kind.name} source is empty',
          );
        }
        _validateSource(asset.replacement.kind, plaintext);

        final encrypted = await operations.encryptWithPassword(
          plaintext,
          password,
        );
        if (!isBytesPasswordEncrypted(encrypted)) {
          throw NoteLockPreparationException(
            'Password encryption did not protect ${asset.replacement.kind.name}',
          );
        }

        await operations.write(asset.replacement.newPath, encrypted);
        final written = await operations.read(asset.replacement.newPath);
        if (!isBytesPasswordEncrypted(written)) {
          throw NoteLockPreparationException(
            'Encrypted ${asset.replacement.kind.name} failed verification',
          );
        }
        Uint8List verified;
        try {
          verified = await operations.decryptWithPassword(written, password);
        } catch (error) {
          throw NoteLockPreparationException(
            'Encrypted ${asset.replacement.kind.name} failed verification',
            error,
          );
        }
        if (!listEquals(verified, plaintext)) {
          throw NoteLockPreparationException(
            'Encrypted ${asset.replacement.kind.name} changed during writing',
          );
        }
      }
    } catch (error) {
      final cleaned = await cleanupStaged(record);
      if (cleaned) {
        try {
          await journal.remove(record.transactionId);
        } catch (journalError, stackTrace) {
          AppLogger.error(
            'Failed to clear aborted note-lock journal',
            journalError,
            stackTrace,
          );
        }
      }
      rethrow;
    }

    return NoteLockPreparation(
      journalRecord: record,
      clearedPreviewIndexes: clearedPreviewIndexes,
    );
  }

  Future<bool> cleanupStaged(
    NoteLockJournalRecord record, {
    Set<String> retainedPaths = const {},
  }) {
    return _deletePaths(
      record.replacements.map((value) => value.newPath),
      retainedPaths: retainedPaths,
    );
  }

  Future<bool> cleanupOriginals(
    NoteLockJournalRecord record, {
    Set<String> retainedPaths = const {},
  }) {
    return _deletePaths(
      record.replacements.map((value) => value.oldPath).whereType<String>(),
      retainedPaths: retainedPaths,
    );
  }

  Future<_PlannedAsset?> _planPath({
    required int attachmentIndex,
    required NoteLockAssetKind kind,
    required String? sourcePath,
    required String documentDirectory,
    required bool required,
    String? forcedExtension,
    Uint8List? currentStrokes,
  }) async {
    final hasCurrentStrokes = currentStrokes != null;
    final resolvedSourcePath =
        sourcePath == null ||
            sourcePath.isEmpty ||
            sourcePath.startsWith('data:') ||
            _isRemotePath(sourcePath)
        ? sourcePath
        : await operations.resolve(sourcePath);
    if (!hasCurrentStrokes) {
      if (sourcePath == null || sourcePath.isEmpty) {
        if (!required) return null;
        throw NoteLockPreparationException(
          '${kind.name} source is unavailable locally',
        );
      }
      if (_isRemotePath(sourcePath)) {
        if (!required) return null;
        throw NoteLockPreparationException(
          '${kind.name} must be available locally before locking',
        );
      }
      if (!sourcePath.startsWith('data:') &&
          !await operations.exists(resolvedSourcePath!)) {
        if (!required) return null;
        throw NoteLockPreparationException(
          '${kind.name} source file is missing',
        );
      }
    }

    final extension = forcedExtension ?? _safeExtension(sourcePath, kind);
    final newPath = path.join(
      documentDirectory,
      '${operations.newId()}$extension',
    );
    return _PlannedAsset(
      NoteLockFileReplacement(
        attachmentIndex: attachmentIndex,
        kind: kind,
        oldPath: sourcePath,
        newPath: newPath,
      ),
      currentStrokes: currentStrokes,
      resolvedSourcePath: resolvedSourcePath,
    );
  }

  Future<Uint8List> _readSource(String sourcePath, String password) async {
    Uint8List bytes;
    if (sourcePath.startsWith('data:')) {
      final comma = sourcePath.indexOf(',');
      if (comma < 0) {
        throw NoteLockPreparationException('Attachment data URI is invalid');
      }
      try {
        bytes = Uint8List.fromList(
          base64Decode(sourcePath.substring(comma + 1)),
        );
      } catch (error) {
        throw NoteLockPreparationException(
          'Attachment data URI cannot be decoded',
          error,
        );
      }
    } else {
      bytes = await operations.read(sourcePath);
    }

    if (!isBytesPasswordEncrypted(bytes)) return bytes;
    try {
      return await operations.decryptWithPassword(bytes, password);
    } catch (error) {
      throw NoteLockPreparationException(
        'An attachment is already protected with a different password',
        error,
      );
    }
  }

  static void _validateSource(NoteLockAssetKind kind, Uint8List bytes) {
    if (kind != NoteLockAssetKind.sketchStrokes) return;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['strokes'] is! List) {
        throw const FormatException('Missing strokes list');
      }
      for (final encodedStroke in decoded['strokes'] as List<dynamic>) {
        if (encodedStroke is! String) {
          throw const FormatException('Invalid stroke entry');
        }
        SketchStroke.parse(encodedStroke);
      }
    } catch (error) {
      throw NoteLockPreparationException(
        'Sketch source data is corrupt',
        error,
      );
    }
  }

  Future<bool> _deletePaths(
    Iterable<String> paths, {
    Set<String> retainedPaths = const {},
  }) async {
    var complete = true;
    final resolvedRetainedPaths = <String>{};
    for (final retainedPath in retainedPaths) {
      if (retainedPath.isEmpty ||
          retainedPath.startsWith('data:') ||
          _isRemotePath(retainedPath)) {
        continue;
      }
      try {
        resolvedRetainedPaths.add(await operations.resolve(retainedPath));
      } catch (_) {
        // A path that cannot be resolved is retained conservatively in its
        // stored form so cleanup never becomes more destructive on failure.
        resolvedRetainedPaths.add(retainedPath);
      }
    }
    for (final filePath in paths.toSet()) {
      if (filePath.isEmpty ||
          filePath.startsWith('data:') ||
          _isRemotePath(filePath)) {
        continue;
      }
      try {
        final resolvedPath = await operations.resolve(filePath);
        if (resolvedRetainedPaths.contains(resolvedPath) ||
            retainedPaths.contains(filePath)) {
          continue;
        }
        if (await operations.exists(resolvedPath) &&
            !await operations.delete(resolvedPath)) {
          complete = false;
        }
      } catch (error, stackTrace) {
        complete = false;
        AppLogger.error(
          'Failed to clean up note-lock file $filePath',
          error,
          stackTrace,
        );
      }
    }
    return complete;
  }

  static bool _isRemotePath(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  static String _safeExtension(String? sourcePath, NoteLockAssetKind kind) {
    if (sourcePath != null && sourcePath.startsWith('data:')) {
      final match = RegExp(
        r'^data:[^/]+/([a-zA-Z0-9+.-]+)',
      ).firstMatch(sourcePath);
      if (match != null) return '.${match.group(1)}';
    }
    if (sourcePath != null && !sourcePath.startsWith('data:')) {
      final extension = path.extension(sourcePath);
      if (extension.isNotEmpty && extension.length <= 12) return extension;
    }
    return switch (kind) {
      NoteLockAssetKind.image ||
      NoteLockAssetKind.sketchBackground ||
      NoteLockAssetKind.sketchPreview => '.img',
      NoteLockAssetKind.audio => '.audio',
      NoteLockAssetKind.sketchStrokes => '.json',
    };
  }
}

/// Prepares fresh, locally encrypted-at-rest files whose contents no longer
/// carry the note PIN's ENCP wrapper. Originals are never modified in place.
class NoteLockRemovalTransactionService {
  final NoteLockFileOperations operations;

  const NoteLockRemovalTransactionService(this.operations);

  Future<NoteLockRemovalPreparation> prepare({
    required int noteId,
    required List<NoteAttachment> attachments,
    required String password,
    required NoteLockRemovalJournal journal,
  }) async {
    final transactionId = operations.newId();
    final documentDirectory = await operations.documentDirectory();
    final assets = <_PlaintextRemovalAsset>[];
    final clearedPreviewIndexes = <int>[];

    for (var index = 0; index < attachments.length; index++) {
      final attachment = attachments[index];
      switch (attachment.type) {
        case AttachmentType.image:
          assets.add(
            await _prepareAsset(
              attachmentIndex: index,
              kind: NoteLockAssetKind.image,
              sourcePath: attachment.image!.src,
              documentDirectory: documentDirectory,
              password: password,
            ),
          );
        case AttachmentType.audio:
          assets.add(
            await _prepareAsset(
              attachmentIndex: index,
              kind: NoteLockAssetKind.audio,
              sourcePath: attachment.recording!.src,
              documentDirectory: documentDirectory,
              password: password,
            ),
          );
        case AttachmentType.sketch:
          final sketch = attachment.sketch!;
          final backgroundPath = sketch.backgroundImage;
          if (backgroundPath != null && backgroundPath.isNotEmpty) {
            assets.add(
              await _prepareAsset(
                attachmentIndex: index,
                kind: NoteLockAssetKind.sketchBackground,
                sourcePath: backgroundPath,
                documentDirectory: documentDirectory,
                password: password,
              ),
            );
          }

          final previewPath = sketch.previewImage;
          if (previewPath != null && previewPath.isNotEmpty) {
            try {
              assets.add(
                await _prepareAsset(
                  attachmentIndex: index,
                  kind: NoteLockAssetKind.sketchPreview,
                  sourcePath: previewPath,
                  documentDirectory: documentDirectory,
                  password: password,
                ),
              );
            } catch (error) {
              clearedPreviewIndexes.add(index);
              AppLogger.log(
                'Discarding unavailable sketch preview during lock removal: '
                '$error',
              );
            }
          }

          final strokesPath = sketch.strokesFilePath;
          assets.add(
            await _prepareAsset(
              attachmentIndex: index,
              kind: NoteLockAssetKind.sketchStrokes,
              sourcePath: strokesPath,
              documentDirectory: documentDirectory,
              password: password,
              forcedExtension: '.json',
            ),
          );
      }
    }

    final record = NoteLockRemovalJournalRecord(
      transactionId: transactionId,
      noteId: noteId,
      phase: NoteLockRemovalJournalPhase.planning,
      replacements: assets
          .map((asset) => asset.replacement)
          .toList(growable: false),
    );
    await journal.put(record);

    try {
      for (final asset in assets) {
        await operations.write(asset.replacement.newPath, asset.plaintext);
        final written = await operations.read(asset.replacement.newPath);
        if (isBytesPasswordEncrypted(written)) {
          throw NoteLockRemovalPreparationException(
            '${asset.replacement.kind.name} remained password-protected',
          );
        }
        if (written.isEmpty) {
          throw NoteLockRemovalPreparationException(
            '${asset.replacement.kind.name} became empty while writing',
          );
        }
        NoteLockTransactionService._validateSource(
          asset.replacement.kind,
          written,
        );
        if (!listEquals(written, asset.plaintext)) {
          throw NoteLockRemovalPreparationException(
            '${asset.replacement.kind.name} changed during writing',
          );
        }
      }
    } catch (error) {
      final cleaned = await cleanupStaged(record);
      if (cleaned) {
        try {
          await journal.remove(record.transactionId);
        } catch (journalError, stackTrace) {
          AppLogger.error(
            'Failed to clear aborted note lock-removal journal',
            journalError,
            stackTrace,
          );
        }
      }
      if (error is NoteLockRemovalPreparationException) rethrow;
      throw NoteLockRemovalPreparationException(
        'Failed to stage files for lock removal',
        error,
      );
    }

    return NoteLockRemovalPreparation(
      journalRecord: record,
      clearedPreviewIndexes: clearedPreviewIndexes,
    );
  }

  Future<bool> cleanupStaged(
    NoteLockRemovalJournalRecord record, {
    Set<String> retainedPaths = const {},
  }) {
    return NoteLockTransactionService(operations)._deletePaths(
      record.replacements.map((replacement) => replacement.newPath),
      retainedPaths: retainedPaths,
    );
  }

  Future<bool> cleanupOriginals(
    NoteLockRemovalJournalRecord record, {
    Set<String> retainedPaths = const {},
  }) {
    return NoteLockTransactionService(operations)._deletePaths(
      record.replacements
          .map((replacement) => replacement.oldPath)
          .whereType<String>(),
      retainedPaths: retainedPaths,
    );
  }

  Future<_PlaintextRemovalAsset> _prepareAsset({
    required int attachmentIndex,
    required NoteLockAssetKind kind,
    required String? sourcePath,
    required String documentDirectory,
    required String password,
    String? forcedExtension,
  }) async {
    if (sourcePath == null || sourcePath.isEmpty) {
      throw NoteLockRemovalPreparationException(
        '${kind.name} source is unavailable locally',
      );
    }
    if (NoteLockTransactionService._isRemotePath(sourcePath)) {
      throw NoteLockRemovalPreparationException(
        '${kind.name} must be downloaded before removing the lock',
      );
    }
    final resolvedSourcePath = sourcePath.startsWith('data:')
        ? sourcePath
        : await operations.resolve(sourcePath);
    if (!sourcePath.startsWith('data:') &&
        !await operations.exists(resolvedSourcePath)) {
      throw NoteLockRemovalPreparationException(
        '${kind.name} source file is missing',
      );
    }

    Uint8List plaintext;
    try {
      Uint8List source;
      if (sourcePath.startsWith('data:')) {
        final comma = sourcePath.indexOf(',');
        if (comma < 0) {
          throw const FormatException('Invalid attachment data URI');
        }
        source = Uint8List.fromList(
          base64Decode(sourcePath.substring(comma + 1)),
        );
      } else {
        source = await operations.read(resolvedSourcePath);
      }
      plaintext = isBytesPasswordEncrypted(source)
          ? await operations.decryptWithPassword(source, password)
          : source;
    } catch (error) {
      throw NoteLockRemovalPreparationException(
        'Unable to decrypt ${kind.name} source',
        error,
      );
    }

    if (plaintext.isEmpty) {
      throw NoteLockRemovalPreparationException('${kind.name} source is empty');
    }
    try {
      NoteLockTransactionService._validateSource(kind, plaintext);
    } catch (error) {
      throw NoteLockRemovalPreparationException(
        '${kind.name} source is corrupt',
        error,
      );
    }

    final extension =
        forcedExtension ??
        NoteLockTransactionService._safeExtension(sourcePath, kind);
    return _PlaintextRemovalAsset(
      NoteLockFileReplacement(
        attachmentIndex: attachmentIndex,
        kind: kind,
        oldPath: sourcePath,
        newPath: path.join(
          documentDirectory,
          '${operations.newId()}$extension',
        ),
      ),
      Uint8List.fromList(plaintext),
    );
  }
}

/// Resolves journals before the note UI or sync can observe an interrupted
/// path switch. Recovery is idempotent and deletes nothing in ambiguous state.
class NoteFileReferenceService {
  NoteFileReferenceService._();

  /// Returns every local attachment path still referenced by SQLite.
  /// Callers must fail closed when this query cannot be completed.
  static Future<Set<String>> databaseReferencedLocalPaths(Database db) async {
    final referenced = <String>{};
    final noteRows = await db.query('note', columns: ['attachments']);
    for (final row in noteRows) {
      final attachments = row['attachments'] as String? ?? '';
      referenced.addAll(
        await NoteLockRecoveryService._attachmentPaths(
          attachments,
          strict: true,
        ),
      );
    }
    final fileRows = await db.query('file_sync_track', columns: ['local_path']);
    referenced.addAll(
      fileRows.map((row) => row['local_path'] as String?).whereType<String>(),
    );
    return referenced;
  }
}

class NoteLockRecoveryService {
  NoteLockRecoveryService._();

  static Future<void> recoverPending({
    Database? database,
    NoteLockFileOperations? fileOperations,
    NoteLockJournal? journal,
  }) async {
    final db = database ?? AppState.db;
    final operations =
        fileOperations ?? await NoteLockFileOperations.platform();
    final activeJournal = journal ?? NoteLockJournal(await AppState.prefs);
    final transactionService = NoteLockTransactionService(operations);

    for (final record in await activeJournal.load()) {
      try {
        final rows = await db.query(
          'note',
          columns: ['locked', 'attachments'],
          where: 'id = ?',
          whereArgs: [record.noteId],
          limit: 1,
        );
        final row = rows.isEmpty ? null : rows.single;
        final attachments = row?['attachments'] as String? ?? '';
        final digestMatches =
            record.expectedAttachmentsDigest != null &&
            NoteLockJournalRecord.attachmentsDigest(attachments) ==
                record.expectedAttachmentsDigest;
        final referencedPaths = await _attachmentPaths(attachments);
        final newPaths = record.replacements
            .map((replacement) => replacement.newPath)
            .toSet();
        final allNewPathsReferenced =
            newPaths.isNotEmpty && newPaths.every(referencedPaths.contains);
        final anyNewPathReferenced = newPaths.any(referencedPaths.contains);
        final committed =
            row != null &&
            (row['locked'] == 1 || row['locked'] == true) &&
            (digestMatches || allNewPathsReferenced);

        if (committed) {
          if (!await _allProtected(newPaths, operations)) {
            AppLogger.log(
              'Pending note-lock transaction ${record.transactionId} has '
              'missing or unverified committed files; retaining journal',
            );
            continue;
          }
          final retainedPaths =
              await NoteFileReferenceService.databaseReferencedLocalPaths(db);
          if (await transactionService.cleanupOriginals(
            record,
            retainedPaths: retainedPaths,
          )) {
            await activeJournal.remove(record.transactionId);
          }
          continue;
        }

        if (anyNewPathReferenced) {
          AppLogger.log(
            'Pending note-lock transaction ${record.transactionId} is '
            'ambiguous; retaining both file sets',
          );
          continue;
        }
        final retainedPaths =
            await NoteFileReferenceService.databaseReferencedLocalPaths(db);
        if (await transactionService.cleanupStaged(
          record,
          retainedPaths: retainedPaths,
        )) {
          await activeJournal.remove(record.transactionId);
        }
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to recover note-lock transaction ${record.transactionId}',
          error,
          stackTrace,
        );
      }
    }
  }

  static Future<Set<String>> _attachmentPaths(
    String serialized, {
    bool strict = false,
  }) async {
    if (serialized.isEmpty) return const {};
    var decoded = serialized;
    if (LocalDataEncryption.isEncrypted(decoded)) {
      decoded = await LocalDataEncryption.instance.decryptString(decoded);
    }
    if (decoded.isEmpty) return const {};

    try {
      final attachments = (jsonDecode(decoded) as List<dynamic>).map(
        (value) =>
            NoteAttachment.fromJson(Map<String, dynamic>.from(value as Map)),
      );
      final result = <String>{};
      for (final attachment in attachments) {
        switch (attachment.type) {
          case AttachmentType.image:
            result.add(attachment.image!.src);
          case AttachmentType.audio:
            result.add(attachment.recording!.src);
          case AttachmentType.sketch:
            final sketch = attachment.sketch!;
            if (sketch.backgroundImage != null) {
              result.add(sketch.backgroundImage!);
            }
            if (sketch.previewImage != null) {
              result.add(sketch.previewImage!);
            }
            if (sketch.strokesFilePath != null) {
              result.add(sketch.strokesFilePath!);
            }
        }
      }
      return result;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to inspect attachment paths during note-lock recovery',
        error,
        stackTrace,
      );
      if (strict) rethrow;
      return const {};
    }
  }

  static Future<bool> _allProtected(
    Set<String> paths,
    NoteLockFileOperations operations,
  ) async {
    for (final filePath in paths) {
      try {
        final resolvedPath = await operations.resolve(filePath);
        if (!await operations.exists(resolvedPath)) return false;
        if (!isBytesPasswordEncrypted(await operations.read(resolvedPath))) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }
    return true;
  }
}

/// Resolves interrupted permanent lock-removal transactions before notes or
/// sync can observe a partially switched set of plaintext paths.
class NoteLockRemovalRecoveryService {
  NoteLockRemovalRecoveryService._();

  static Future<void> recoverPending({
    Database? database,
    NoteLockFileOperations? fileOperations,
    NoteLockRemovalJournal? journal,
  }) async {
    final db = database ?? AppState.db;
    final operations =
        fileOperations ?? await NoteLockFileOperations.platform();
    final activeJournal =
        journal ?? NoteLockRemovalJournal(await AppState.prefs);
    final transactionService = NoteLockRemovalTransactionService(operations);

    for (final record in await activeJournal.load()) {
      try {
        final rows = await db.query(
          'note',
          columns: ['locked', 'attachments'],
          where: 'id = ?',
          whereArgs: [record.noteId],
          limit: 1,
        );
        final row = rows.isEmpty ? null : rows.single;
        final attachments = row?['attachments'] as String? ?? '';
        final referencedPaths = await NoteLockRecoveryService._attachmentPaths(
          attachments,
          strict: true,
        );
        final newPaths = record.replacements
            .map((replacement) => replacement.newPath)
            .toSet();
        final digestMatches =
            record.expectedAttachmentsDigest != null &&
            NoteLockJournalRecord.attachmentsDigest(attachments) ==
                record.expectedAttachmentsDigest;
        final allNewPathsReferenced = newPaths.every(referencedPaths.contains);
        final anyNewPathReferenced = newPaths.any(referencedPaths.contains);
        final committed =
            row != null &&
            (row['locked'] == 0 || row['locked'] == false) &&
            digestMatches &&
            allNewPathsReferenced;

        if (committed) {
          if (!await _allPlaintext(record.replacements, operations)) {
            AppLogger.log(
              'Pending note lock-removal transaction '
              '${record.transactionId} has missing or unverified committed '
              'files; retaining journal',
            );
            continue;
          }
          final retainedPaths =
              await NoteFileReferenceService.databaseReferencedLocalPaths(db);
          if (await transactionService.cleanupOriginals(
            record,
            retainedPaths: retainedPaths,
          )) {
            await activeJournal.remove(record.transactionId);
          }
          continue;
        }

        if (anyNewPathReferenced) {
          AppLogger.log(
            'Pending note lock-removal transaction ${record.transactionId} '
            'is ambiguous; retaining both file sets',
          );
          continue;
        }
        final retainedPaths =
            await NoteFileReferenceService.databaseReferencedLocalPaths(db);
        if (await transactionService.cleanupStaged(
          record,
          retainedPaths: retainedPaths,
        )) {
          await activeJournal.remove(record.transactionId);
        }
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to recover note lock-removal transaction '
          '${record.transactionId}',
          error,
          stackTrace,
        );
      }
    }
  }

  static Future<Set<String>> databaseReferencedLocalPaths(Database db) async {
    return NoteFileReferenceService.databaseReferencedLocalPaths(db);
  }

  static Future<bool> _allPlaintext(
    List<NoteLockFileReplacement> replacements,
    NoteLockFileOperations operations,
  ) async {
    for (final replacement in replacements) {
      try {
        final resolvedPath = await operations.resolve(replacement.newPath);
        if (!await operations.exists(resolvedPath)) return false;
        final bytes = await operations.read(resolvedPath);
        if (bytes.isEmpty || isBytesPasswordEncrypted(bytes)) return false;
        NoteLockTransactionService._validateSource(replacement.kind, bytes);
      } catch (_) {
        return false;
      }
    }
    return true;
  }
}

void _setAttachmentPath(
  List<NoteAttachment> attachments,
  NoteLockFileReplacement replacement,
  String? value,
) {
  final attachment = attachments[replacement.attachmentIndex];
  switch (replacement.kind) {
    case NoteLockAssetKind.image:
      attachment.image!.src = value!;
    case NoteLockAssetKind.audio:
      attachment.recording!.src = value!;
    case NoteLockAssetKind.sketchBackground:
      attachment.sketch!.backgroundImage = value;
    case NoteLockAssetKind.sketchPreview:
      attachment.sketch!.previewImage = value;
    case NoteLockAssetKind.sketchStrokes:
      attachment.sketch!.strokesFilePath = value;
  }
}
