import 'dart:convert';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

enum LegacySketchMigrationStatus { notNeeded, migrated, partial, deferred }

@immutable
class LegacyDecodedSketch {
  final List<SketchStroke> strokes;
  final Color backgroundColor;
  final PagePattern pagePattern;

  const LegacyDecodedSketch({
    required this.strokes,
    required this.backgroundColor,
    required this.pagePattern,
  });

  List<String> get encodedStrokes =>
      strokes.map((stroke) => stroke.toString()).toList(growable: false);

  bool sameDrawing(LegacyDecodedSketch other) =>
      listEquals(encodedStrokes, other.encodedStrokes) &&
      backgroundColor.toARGB32() == other.backgroundColor.toARGB32() &&
      pagePattern == other.pagePattern;
}

/// The only component allowed to understand the deprecated ciphertext
/// payload. New code must never call the matching legacy encryption path.
class LegacyEncryptedSketchDecoder {
  const LegacyEncryptedSketchDecoder._();

  static Future<LegacyDecodedSketch> decode({
    required String ciphertext,
    required String password,
    required Color fallbackBackgroundColor,
    required PagePattern fallbackPagePattern,
  }) async {
    final plaintext = await decrypt(ciphertext, password);
    final decoded = jsonDecode(plaintext);

    late final List<dynamic> encodedStrokes;
    var backgroundColor = fallbackBackgroundColor;
    var pagePattern = fallbackPagePattern;
    if (decoded is List<dynamic>) {
      encodedStrokes = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final strokesValue = decoded['strokes'];
      if (strokesValue is! List<dynamic>) {
        throw const FormatException('Legacy sketch is missing its strokes');
      }
      encodedStrokes = strokesValue;
      final colorValue = decoded['bgColor'];
      if (colorValue != null) {
        if (colorValue is! int) {
          throw const FormatException('Legacy sketch color is invalid');
        }
        backgroundColor = Color(colorValue);
      }
      final patternValue = decoded['pagePattern'];
      if (patternValue != null) {
        if (patternValue is! String) {
          throw const FormatException('Legacy page pattern is invalid');
        }
        pagePattern = PagePattern.values.firstWhere(
          (candidate) => candidate.name == patternValue,
          orElse: () =>
              throw const FormatException('Legacy page pattern is unknown'),
        );
      }
    } else {
      throw const FormatException('Legacy sketch payload is invalid');
    }

    final strokes = encodedStrokes
        .map((value) {
          if (value is! String) {
            throw const FormatException('Legacy stroke entry is invalid');
          }
          return SketchStroke.parse(value);
        })
        .toList(growable: false);
    return LegacyDecodedSketch(
      strokes: strokes,
      backgroundColor: backgroundColor,
      pagePattern: pagePattern,
    );
  }
}

typedef LocalSketchMetadataDecryptor =
    Future<String> Function(String ciphertext);
typedef LocalSketchMetadataEncryptor =
    Future<String> Function(String plaintext);

/// Decodes the deprecated app-key metadata only inside an already
/// PIN-authenticated migration. Locked note loading must never call this.
class LocalEncryptedSketchMetadataDecoder {
  const LocalEncryptedSketchMetadataDecoder._();

  static Future<LegacyDecodedSketch> decode({
    required String ciphertext,
    required LocalSketchMetadataDecryptor decryptor,
    required Color fallbackBackgroundColor,
    required PagePattern fallbackPagePattern,
  }) async {
    final plaintext = await decryptor(ciphertext);
    if (plaintext.isEmpty) {
      throw const FormatException(
        'Local sketch metadata could not be decrypted',
      );
    }
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Local sketch metadata is invalid');
    }
    final strokesValue = decoded['strokes'];
    if (strokesValue is! List<dynamic>) {
      throw const FormatException('Local sketch metadata is missing strokes');
    }
    final strokes = strokesValue
        .map((value) {
          if (value is! String) {
            throw const FormatException('Local sketch stroke entry is invalid');
          }
          return SketchStroke.parse(value);
        })
        .toList(growable: false);

    var backgroundColor = fallbackBackgroundColor;
    final colorValue = decoded['bgColor'];
    if (colorValue != null) {
      if (colorValue is! int) {
        throw const FormatException('Local sketch color is invalid');
      }
      backgroundColor = Color(colorValue);
    }

    var pagePattern = fallbackPagePattern;
    final patternValue = decoded['pagePattern'];
    if (patternValue != null) {
      if (patternValue is! String) {
        throw const FormatException('Local sketch page pattern is invalid');
      }
      pagePattern = PagePattern.values.firstWhere(
        (candidate) => candidate.name == patternValue,
        orElse: () =>
            throw const FormatException('Local sketch page pattern is unknown'),
      );
    }

    return LegacyDecodedSketch(
      strokes: strokes,
      backgroundColor: backgroundColor,
      pagePattern: pagePattern,
    );
  }
}

@immutable
class LegacyMigratedSketch {
  final int attachmentIndex;
  final String newPath;
  final LegacyDecodedSketch drawing;
  final double aspectRatio;

  const LegacyMigratedSketch({
    required this.attachmentIndex,
    required this.newPath,
    required this.drawing,
    required this.aspectRatio,
  });

  void apply(List<NoteAttachment> attachments) {
    if (attachmentIndex < 0 || attachmentIndex >= attachments.length) return;
    final sketch = attachments[attachmentIndex].sketch;
    if (sketch == null) return;
    sketch.strokes = List<SketchStroke>.from(drawing.strokes);
    sketch.backgroundColor = drawing.backgroundColor;
    sketch.pagePattern = drawing.pagePattern;
    sketch.aspectRatio = aspectRatio;
    sketch.strokesFilePath = newPath;
    sketch.strokesContentHash = null;
    sketch.markLegacyMigrationSucceeded();
  }
}

@immutable
class LegacySanitizedSketch {
  final int attachmentIndex;
  final LegacyDecodedSketch drawing;
  final double aspectRatio;

  const LegacySanitizedSketch({
    required this.attachmentIndex,
    required this.drawing,
    required this.aspectRatio,
  });

  void apply(List<NoteAttachment> attachments) {
    if (attachmentIndex < 0 || attachmentIndex >= attachments.length) return;
    final sketch = attachments[attachmentIndex].sketch;
    if (sketch == null) return;
    sketch.strokes = List<SketchStroke>.from(drawing.strokes);
    sketch.backgroundColor = drawing.backgroundColor;
    sketch.pagePattern = drawing.pagePattern;
    sketch.aspectRatio = aspectRatio;
    sketch.markLegacyMigrationSucceeded();
  }
}

@immutable
class LegacyQuarantinedSketch {
  final int attachmentIndex;
  final String message;

  const LegacyQuarantinedSketch({
    required this.attachmentIndex,
    required this.message,
  });

  void apply(List<NoteAttachment> attachments) {
    if (attachmentIndex < 0 || attachmentIndex >= attachments.length) return;
    attachments[attachmentIndex].sketch?.markLegacyMigrationFailed(message);
  }
}

@immutable
class LegacySketchMigrationResult {
  final LegacySketchMigrationStatus status;
  final List<LegacyMigratedSketch> migrated;
  final List<LegacySanitizedSketch> sanitized;
  final List<LegacyQuarantinedSketch> quarantined;
  final DateTime? updatedAt;
  final bool shouldTriggerSync;

  const LegacySketchMigrationResult({
    required this.status,
    this.migrated = const [],
    this.sanitized = const [],
    this.quarantined = const [],
    this.updatedAt,
    this.shouldTriggerSync = false,
  });

  Set<String> get protectedMigratedPaths =>
      migrated.map((item) => item.newPath).toSet();

  void applyTo(Note note) {
    for (final item in migrated) {
      item.apply(note.attachments);
    }
    for (final item in sanitized) {
      item.apply(note.attachments);
    }
    for (final item in quarantined) {
      item.apply(note.attachments);
    }
    if (updatedAt != null) note.updatedAt = updatedAt;
  }
}

enum LegacySketchMigrationJournalPhase { planning, ready }

@immutable
class LegacySketchMigrationJournalRecord {
  static const currentVersion = 1;

  final int version;
  final String transactionId;
  final int noteId;
  final LegacySketchMigrationJournalPhase phase;
  final List<NoteLockFileReplacement> replacements;
  final String? expectedAttachmentsDigest;

  const LegacySketchMigrationJournalRecord({
    this.version = currentVersion,
    required this.transactionId,
    required this.noteId,
    required this.phase,
    required this.replacements,
    this.expectedAttachmentsDigest,
  });

  factory LegacySketchMigrationJournalRecord.fromJson(
    Map<String, dynamic> json,
  ) => LegacySketchMigrationJournalRecord(
    version: json['version'] as int? ?? 0,
    transactionId: json['transactionId'] as String,
    noteId: json['noteId'] as int,
    phase: LegacySketchMigrationJournalPhase.values.byName(
      json['phase'] as String,
    ),
    replacements: (json['replacements'] as List<dynamic>)
        .map(
          (value) => NoteLockFileReplacement.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList(growable: false),
    expectedAttachmentsDigest: json['expectedAttachmentsDigest'] as String?,
  );

  LegacySketchMigrationJournalRecord withReplacements(
    List<NoteLockFileReplacement> value,
  ) => LegacySketchMigrationJournalRecord(
    transactionId: transactionId,
    noteId: noteId,
    phase: phase,
    replacements: value,
    expectedAttachmentsDigest: expectedAttachmentsDigest,
  );

  LegacySketchMigrationJournalRecord readyForCommit(String attachments) =>
      LegacySketchMigrationJournalRecord(
        transactionId: transactionId,
        noteId: noteId,
        phase: LegacySketchMigrationJournalPhase.ready,
        replacements: replacements,
        expectedAttachmentsDigest: attachmentsDigest(attachments),
      );

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

  static String attachmentsDigest(String attachments) =>
      sha256.convert(utf8.encode(attachments)).toString();
}

class LegacySketchMigrationJournal {
  static String get preferenceKey =>
      FirebaseScopedPreferences.key('pending_legacy_sketch_migrations_v1');
  static Future<void> _mutationQueue = Future<void>.value();

  final SharedPreferences preferences;

  const LegacySketchMigrationJournal(this.preferences);

  Future<List<LegacySketchMigrationJournalRecord>> load() async {
    final encoded = preferences.getString(preferenceKey);
    if (encoded == null || encoded.isEmpty) return const [];
    try {
      return (jsonDecode(encoded) as List<dynamic>)
          .map(
            (value) => LegacySketchMigrationJournalRecord.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where(
            (record) =>
                record.version ==
                LegacySketchMigrationJournalRecord.currentVersion,
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to read pending legacy sketch migrations',
        error,
        stackTrace,
      );
      return const [];
    }
  }

  Future<void> put(LegacySketchMigrationJournalRecord record) =>
      _mutate(() async {
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

  Future<void> remove(String transactionId) => _mutate(() async {
    final records = (await load())
        .where((record) => record.transactionId != transactionId)
        .toList(growable: false);
    await _save(records);
  });

  static Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _save(List<LegacySketchMigrationJournalRecord> records) async {
    if (records.isEmpty) {
      final removed = await preferences.remove(preferenceKey);
      if (!removed && preferences.containsKey(preferenceKey)) {
        throw StateError('Unable to clear legacy sketch migration journal');
      }
      return;
    }
    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
    if (!saved) {
      throw StateError('Unable to persist legacy sketch migration journal');
    }
  }
}

class _LegacyMigrationPlan {
  final int attachmentIndex;
  final String? oldPath;
  final String newPath;
  final LegacyDecodedSketch drawing;
  final double aspectRatio;
  final Uint8List plaintext;

  const _LegacyMigrationPlan({
    required this.attachmentIndex,
    required this.oldPath,
    required this.newPath,
    required this.drawing,
    required this.aspectRatio,
    required this.plaintext,
  });

  NoteLockFileReplacement get replacement => NoteLockFileReplacement(
    attachmentIndex: attachmentIndex,
    kind: NoteLockAssetKind.sketchStrokes,
    oldPath: oldPath,
    newPath: newPath,
  );
}

class _LegacyMetadataCleanupPlan {
  final int attachmentIndex;
  final LegacyDecodedSketch drawing;
  final double aspectRatio;

  const _LegacyMetadataCleanupPlan({
    required this.attachmentIndex,
    required this.drawing,
    required this.aspectRatio,
  });

  LegacySanitizedSketch get result => LegacySanitizedSketch(
    attachmentIndex: attachmentIndex,
    drawing: drawing,
    aspectRatio: aspectRatio,
  );

  void apply(List<NoteAttachment> attachments) => result.apply(attachments);
}

class _LegacySketchPlan {
  final _LegacyMigrationPlan? migration;
  final _LegacyMetadataCleanupPlan? cleanup;

  const _LegacySketchPlan.migration(this.migration) : cleanup = null;
  const _LegacySketchPlan.cleanup(this.cleanup) : migration = null;
}

class _LegacyMigrationConflict implements Exception {
  const _LegacyMigrationConflict();
}

class LegacySketchMigrationService {
  final Database database;
  final NoteLockFileOperations operations;
  final LegacySketchMigrationJournal journal;
  final LocalSketchMetadataDecryptor? localMetadataDecryptor;

  const LegacySketchMigrationService({
    required this.database,
    required this.operations,
    required this.journal,
    this.localMetadataDecryptor,
  });

  Future<LegacySketchMigrationResult> migrate({
    required int noteId,
    required String password,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _attempt(noteId: noteId, password: password);
      } on _LegacyMigrationConflict {
        if (attempt == 0) continue;
        return const LegacySketchMigrationResult(
          status: LegacySketchMigrationStatus.deferred,
        );
      }
    }
    return const LegacySketchMigrationResult(
      status: LegacySketchMigrationStatus.deferred,
    );
  }

  Future<LegacySketchMigrationResult> _attempt({
    required int noteId,
    required String password,
  }) async {
    final rows = await database.query(
      Note.model,
      where: 'id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const LegacySketchMigrationResult(
        status: LegacySketchMigrationStatus.notNeeded,
      );
    }
    final expectedRow = Map<String, Object?>.from(rows.single);
    final note = await Note.fromJsonAsync(expectedRow);
    if (!note.locked) {
      return const LegacySketchMigrationResult(
        status: LegacySketchMigrationStatus.notNeeded,
      );
    }

    // Revalidate the current database row with the same PIN. This matters on a
    // retry after a concurrent sync replaced the row.
    final decryptedContent = await decrypt(note.content ?? '', password);
    if (decryptedContent.isEmpty && (note.content?.isNotEmpty ?? false)) {
      throw const FormatException('Decryption produced empty note content');
    }

    final plans = <_LegacyMigrationPlan>[];
    final metadataCleanups = <_LegacyMetadataCleanupPlan>[];
    final quarantined = <LegacyQuarantinedSketch>[];
    for (var index = 0; index < note.attachments.length; index++) {
      final attachment = note.attachments[index];
      if (attachment.type != AttachmentType.sketch ||
          attachment.sketch == null) {
        continue;
      }
      final sketch = attachment.sketch!;
      try {
        final planned = await _planSketch(
          attachmentIndex: index,
          sketch: sketch,
          password: password,
        );
        if (planned?.migration != null) plans.add(planned!.migration!);
        if (planned?.cleanup != null) metadataCleanups.add(planned!.cleanup!);
      } catch (error, stackTrace) {
        if (sketch.hasEncryptedStrokes || sketch.hasEncryptedMetadata) {
          quarantined.add(
            LegacyQuarantinedSketch(
              attachmentIndex: index,
              message: 'Legacy drawing conversion failed: $error',
            ),
          );
          AppLogger.error(
            'Quarantined legacy sketch $index in note $noteId',
            error,
            stackTrace,
          );
        }
      }
    }

    if (plans.isEmpty && metadataCleanups.isEmpty) {
      return LegacySketchMigrationResult(
        status: quarantined.isEmpty
            ? LegacySketchMigrationStatus.notNeeded
            : LegacySketchMigrationStatus.deferred,
        quarantined: quarantined,
      );
    }

    if (plans.isEmpty) {
      try {
        for (final cleanup in metadataCleanups) {
          cleanup.apply(note.attachments);
        }
        for (final failure in quarantined) {
          failure.apply(note.attachments);
        }
        final serializedAttachments = await note
            .serializeAttachmentsForLocalStorage();
        await _commitLocalMetadataCleanup(
          expectedRow: expectedRow,
          attachments: serializedAttachments,
        );
        return LegacySketchMigrationResult(
          status: quarantined.isEmpty
              ? LegacySketchMigrationStatus.migrated
              : LegacySketchMigrationStatus.partial,
          sanitized: metadataCleanups
              .map((cleanup) => cleanup.result)
              .toList(growable: false),
          quarantined: quarantined,
        );
      } on _LegacyMigrationConflict {
        rethrow;
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to remove redundant locked sketch metadata for note $noteId',
          error,
          stackTrace,
        );
        return LegacySketchMigrationResult(
          status: LegacySketchMigrationStatus.deferred,
          quarantined: [
            ...quarantined,
            for (final cleanup in metadataCleanups)
              LegacyQuarantinedSketch(
                attachmentIndex: cleanup.attachmentIndex,
                message: 'Local sketch metadata cleanup was deferred',
              ),
          ],
        );
      }
    }

    var record = LegacySketchMigrationJournalRecord(
      transactionId: operations.newId(),
      noteId: noteId,
      phase: LegacySketchMigrationJournalPhase.planning,
      replacements: plans.map((plan) => plan.replacement).toList(),
    );
    await journal.put(record);

    final staged = <_LegacyMigrationPlan>[];
    try {
      for (final plan in plans) {
        try {
          final protected = await operations.encryptWithPassword(
            plan.plaintext,
            password,
          );
          if (!isBytesPasswordEncrypted(protected)) {
            throw StateError('Converted strokes were not password-protected');
          }
          await operations.write(plan.newPath, protected);
          final written = await operations.read(plan.newPath);
          final verified = await operations.decryptWithPassword(
            written,
            password,
          );
          if (!listEquals(verified, plan.plaintext)) {
            throw StateError('Converted strokes changed while being written');
          }
          _verifyCurrentFile(verified, plan);
          staged.add(plan);
        } catch (error, stackTrace) {
          await _deletePaths([plan.newPath]);
          quarantined.add(
            LegacyQuarantinedSketch(
              attachmentIndex: plan.attachmentIndex,
              message: 'Legacy drawing could not be stored safely: $error',
            ),
          );
          AppLogger.error(
            'Failed to stage converted legacy sketch for note $noteId',
            error,
            stackTrace,
          );
        }
      }

      record = record.withReplacements(
        staged.map((plan) => plan.replacement).toList(growable: false),
      );
      if (staged.isEmpty) {
        for (final cleanup in metadataCleanups) {
          cleanup.apply(note.attachments);
        }
        for (final failure in quarantined) {
          failure.apply(note.attachments);
        }
        if (metadataCleanups.isNotEmpty) {
          final serializedAttachments = await note
              .serializeAttachmentsForLocalStorage();
          await _commitLocalMetadataCleanup(
            expectedRow: expectedRow,
            attachments: serializedAttachments,
          );
        }
        await journal.remove(record.transactionId);
        return LegacySketchMigrationResult(
          status: metadataCleanups.isEmpty
              ? LegacySketchMigrationStatus.deferred
              : LegacySketchMigrationStatus.partial,
          sanitized: metadataCleanups
              .map((cleanup) => cleanup.result)
              .toList(growable: false),
          quarantined: quarantined,
        );
      }
      await journal.put(record);

      for (final plan in staged) {
        final sketch = note.attachments[plan.attachmentIndex].sketch!;
        sketch.strokes = List<SketchStroke>.from(plan.drawing.strokes);
        sketch.backgroundColor = plan.drawing.backgroundColor;
        sketch.pagePattern = plan.drawing.pagePattern;
        sketch.aspectRatio = plan.aspectRatio;
        sketch.strokesFilePath = plan.newPath;
        sketch.strokesContentHash = null;
        sketch.markLegacyMigrationSucceeded();
      }
      for (final cleanup in metadataCleanups) {
        cleanup.apply(note.attachments);
      }
      for (final failure in quarantined) {
        failure.apply(note.attachments);
      }

      final serializedAttachments = await note
          .serializeAttachmentsForLocalStorage();
      final nextUpdatedAt = _nextTimestamp(expectedRow['updated_at']);
      record = record.readyForCommit(serializedAttachments);
      await journal.put(record);
      await _commit(
        expectedRow: expectedRow,
        attachments: serializedAttachments,
        updatedAt: nextUpdatedAt,
        replacements: record.replacements,
      );

      final referencedPaths = _collectAttachmentPaths(note.attachments);
      final cleanupComplete = await _deletePaths(
        record.replacements
            .map((replacement) => replacement.oldPath)
            .whereType<String>()
            .where((oldPath) => !referencedPaths.contains(oldPath)),
      );
      if (cleanupComplete) await journal.remove(record.transactionId);

      final migrated = staged
          .map(
            (plan) => LegacyMigratedSketch(
              attachmentIndex: plan.attachmentIndex,
              newPath: plan.newPath,
              drawing: plan.drawing,
              aspectRatio: plan.aspectRatio,
            ),
          )
          .toList(growable: false);
      return LegacySketchMigrationResult(
        status: quarantined.isEmpty
            ? LegacySketchMigrationStatus.migrated
            : LegacySketchMigrationStatus.partial,
        migrated: migrated,
        sanitized: metadataCleanups
            .map((cleanup) => cleanup.result)
            .toList(growable: false),
        quarantined: quarantined,
        updatedAt: nextUpdatedAt,
        shouldTriggerSync: true,
      );
    } on _LegacyMigrationConflict {
      await _rollback(record);
      rethrow;
    } catch (error, stackTrace) {
      await _rollback(record);
      AppLogger.error(
        'Failed to commit legacy sketch migration for note $noteId',
        error,
        stackTrace,
      );
      return LegacySketchMigrationResult(
        status: LegacySketchMigrationStatus.deferred,
        quarantined: [
          ...quarantined,
          for (final plan in staged)
            LegacyQuarantinedSketch(
              attachmentIndex: plan.attachmentIndex,
              message: 'Legacy drawing conversion was deferred',
            ),
          for (final cleanup in metadataCleanups)
            LegacyQuarantinedSketch(
              attachmentIndex: cleanup.attachmentIndex,
              message: 'Local sketch metadata cleanup was deferred',
            ),
        ],
      );
    }
  }

  Future<_LegacySketchPlan?> _planSketch({
    required int attachmentIndex,
    required SketchData sketch,
    required String password,
  }) async {
    final ciphertexts = <String>{
      if (sketch.hasEncryptedStrokes) sketch.encryptedStrokes!,
    };
    var currentStrokes = List<SketchStroke>.from(sketch.strokes);
    var fallbackBackground = sketch.backgroundColor;
    var fallbackPattern = sketch.pagePattern;
    var aspectRatio = sketch.aspectRatio;
    var currentSourceIsAuthoritative = sketch.strokes.isNotEmpty;
    var currentSourceIsPinProtected = false;

    LegacyDecodedSketch? localMetadataDrawing;
    if (sketch.hasEncryptedMetadata) {
      localMetadataDrawing = await LocalEncryptedSketchMetadataDecoder.decode(
        ciphertext: sketch.encryptedMetadata!,
        decryptor:
            localMetadataDecryptor ??
            LocalDataEncryption.instance.decryptString,
        fallbackBackgroundColor: fallbackBackground,
        fallbackPagePattern: fallbackPattern,
      );
    }

    final oldPath = sketch.strokesFilePath;
    if (oldPath != null &&
        oldPath.isNotEmpty &&
        !oldPath.startsWith('http') &&
        await operations.exists(oldPath)) {
      var bytes = await operations.read(oldPath);
      if (isBytesPasswordEncrypted(bytes)) {
        currentSourceIsPinProtected = true;
        bytes = await operations.decryptWithPassword(bytes, password);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Sketch source file is invalid');
      }
      final fileCiphertext = decoded['encryptedStrokes'];
      if (fileCiphertext != null) {
        if (fileCiphertext is! String || fileCiphertext.isEmpty) {
          throw const FormatException('Legacy ciphertext is invalid');
        }
        ciphertexts.add(fileCiphertext);
        // This is a fresh database model used only by the migration. Retaining
        // the value here lets partial commits preserve a failed file-contained
        // source rather than serializing it as an empty current sketch.
        sketch.encryptedStrokes = fileCiphertext;
        sketch.legacyMigrationState = LegacySketchMigrationState.pending;
      }
      final fileSketch = SketchData(
        aspectRatio: aspectRatio,
        backgroundColor: fallbackBackground,
        pagePattern: fallbackPattern,
      );
      fileSketch.loadFromStrokesFileJson(decoded);
      currentStrokes = List<SketchStroke>.from(fileSketch.strokes);
      fallbackBackground = fileSketch.backgroundColor;
      fallbackPattern = fileSketch.pagePattern;
      aspectRatio = fileSketch.aspectRatio;
      currentSourceIsAuthoritative =
          fileCiphertext == null && decoded['strokes'] is List<dynamic>;
    }

    if (ciphertexts.isEmpty && localMetadataDrawing == null) return null;
    final decodedCandidates = <LegacyDecodedSketch>[];
    for (final ciphertext in ciphertexts) {
      decodedCandidates.add(
        await LegacyEncryptedSketchDecoder.decode(
          ciphertext: ciphertext,
          password: password,
          fallbackBackgroundColor: fallbackBackground,
          fallbackPagePattern: fallbackPattern,
        ),
      );
    }
    LegacyDecodedSketch? drawing;
    if (decodedCandidates.isNotEmpty) {
      drawing = decodedCandidates.first;
      if (decodedCandidates
          .skip(1)
          .any((item) => !item.sameDrawing(drawing!))) {
        throw const FormatException('Legacy sketch sources disagree');
      }
    }
    if (localMetadataDrawing != null) {
      if (drawing != null && !drawing.sameDrawing(localMetadataDrawing)) {
        throw const FormatException(
          'PIN and local sketch metadata sources disagree',
        );
      }
      drawing ??= localMetadataDrawing;
    }
    final resolvedDrawing = drawing!;
    final currentDrawing = LegacyDecodedSketch(
      strokes: currentStrokes,
      backgroundColor: fallbackBackground,
      pagePattern: fallbackPattern,
    );
    if (currentSourceIsAuthoritative &&
        !currentDrawing.sameDrawing(resolvedDrawing)) {
      throw const FormatException('Current and legacy sketch sources disagree');
    }

    if (localMetadataDrawing != null &&
        ciphertexts.isEmpty &&
        currentSourceIsAuthoritative &&
        currentSourceIsPinProtected) {
      return _LegacySketchPlan.cleanup(
        _LegacyMetadataCleanupPlan(
          attachmentIndex: attachmentIndex,
          drawing: resolvedDrawing,
          aspectRatio: aspectRatio,
        ),
      );
    }

    final currentSketch = SketchData(
      strokes: List<SketchStroke>.from(resolvedDrawing.strokes),
      backgroundColor: resolvedDrawing.backgroundColor,
      pagePattern: resolvedDrawing.pagePattern,
      aspectRatio: aspectRatio,
      strokesHydrated: true,
    );
    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode(currentSketch.toStrokesFileJson())),
    );
    final documentDirectory = await operations.documentDirectory();
    return _LegacySketchPlan.migration(
      _LegacyMigrationPlan(
        attachmentIndex: attachmentIndex,
        oldPath: oldPath,
        newPath: path.join(documentDirectory, '${operations.newId()}.json'),
        drawing: resolvedDrawing,
        aspectRatio: aspectRatio,
        plaintext: plaintext,
      ),
    );
  }

  static void _verifyCurrentFile(Uint8List bytes, _LegacyMigrationPlan plan) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded.containsKey('encryptedStrokes')) {
      throw const FormatException('Converted sketch is not current format');
    }
    final verified = SketchData();
    verified.loadFromStrokesFileJson(decoded);
    if (!listEquals(
          verified.strokes.map((stroke) => stroke.toString()).toList(),
          plan.drawing.encodedStrokes,
        ) ||
        verified.backgroundColor.toARGB32() !=
            plan.drawing.backgroundColor.toARGB32() ||
        verified.pagePattern != plan.drawing.pagePattern ||
        verified.aspectRatio != plan.aspectRatio) {
      throw const FormatException('Converted sketch failed verification');
    }
  }

  Future<void> _commitLocalMetadataCleanup({
    required Map<String, Object?> expectedRow,
    required String attachments,
  }) async {
    await database.transaction((transaction) async {
      final rows = await transaction.query(
        Note.model,
        where: 'id = ?',
        whereArgs: [expectedRow['id']],
        limit: 1,
      );
      if (rows.isEmpty ||
          !mapEquals(Map<String, Object?>.from(rows.single), expectedRow)) {
        throw const _LegacyMigrationConflict();
      }
      final updated = await transaction.update(
        Note.model,
        {'attachments': attachments},
        where: 'id = ?',
        whereArgs: [expectedRow['id']],
      );
      if (updated != 1) {
        throw StateError('Local sketch metadata cleanup failed');
      }
    });
  }

  Future<void> _commit({
    required Map<String, Object?> expectedRow,
    required String attachments,
    required DateTime updatedAt,
    required List<NoteLockFileReplacement> replacements,
  }) async {
    await database.transaction((transaction) async {
      final rows = await transaction.query(
        Note.model,
        where: 'id = ?',
        whereArgs: [expectedRow['id']],
        limit: 1,
      );
      if (rows.isEmpty ||
          !mapEquals(Map<String, Object?>.from(rows.single), expectedRow)) {
        throw const _LegacyMigrationConflict();
      }
      final updated = await transaction.update(
        Note.model,
        {'attachments': attachments, 'updated_at': updatedAt.toIso8601String()},
        where: 'id = ?',
        whereArgs: [expectedRow['id']],
      );
      if (updated != 1) throw StateError('Legacy sketch commit failed');

      for (final replacement in replacements) {
        final oldPath = replacement.oldPath;
        var trackedRows = 0;
        if (oldPath != null &&
            oldPath.isNotEmpty &&
            !oldPath.startsWith('http')) {
          trackedRows = await transaction.rawUpdate(
            '''
            UPDATE file_sync_track
            SET local_path = ?, content_hash = NULL
            WHERE note_id = ? AND local_path = ?
            ''',
            [replacement.newPath, expectedRow['id'], oldPath],
          );
        }
        if (trackedRows != 0) continue;

        final existingNewPath = await transaction.query(
          FileSyncTrack.model,
          columns: ['id'],
          where: 'note_id = ? AND local_path = ?',
          whereArgs: [expectedRow['id'], replacement.newPath],
          limit: 1,
        );
        if (existingNewPath.isEmpty) {
          await transaction.insert(FileSyncTrack.model, {
            'note_id': expectedRow['id'],
            'local_path': replacement.newPath,
            'content_hash': null,
          });
        }
      }

      final syncRows = await transaction.query(
        'sync_track',
        where: 'local_id = ?',
        whereArgs: [expectedRow['id']],
        limit: 1,
      );
      final now = DateTime.now().toIso8601String();
      if (syncRows.isEmpty) {
        await transaction.insert('sync_track', {
          'local_id': expectedRow['id'],
          'action': 'upload',
          'status': 'pending',
          'created_at': now,
          'updated_at': now,
        });
      } else if (syncRows.single['action'] != 'delete') {
        await transaction.update(
          'sync_track',
          {'action': 'upload', 'status': 'pending', 'updated_at': now},
          where: 'id = ?',
          whereArgs: [syncRows.single['id']],
        );
      }
    });
  }

  Future<void> _rollback(LegacySketchMigrationJournalRecord record) async {
    if (await _deletePaths(
      record.replacements.map((replacement) => replacement.newPath),
    )) {
      try {
        await journal.remove(record.transactionId);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to clear rolled-back legacy sketch journal',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<bool> _deletePaths(Iterable<String> paths) async {
    var complete = true;
    for (final filePath in paths.toSet()) {
      if (filePath.isEmpty || filePath.startsWith('http')) continue;
      try {
        if (await operations.exists(filePath) &&
            !await operations.delete(filePath)) {
          complete = false;
        }
      } catch (error, stackTrace) {
        complete = false;
        AppLogger.error(
          'Failed to clean legacy sketch migration file $filePath',
          error,
          stackTrace,
        );
      }
    }
    return complete;
  }

  static DateTime _nextTimestamp(Object? value) {
    final previous = DateTime.tryParse(value?.toString() ?? '');
    final now = DateTime.now();
    if (previous == null || now.isAfter(previous)) return now;
    return previous.add(const Duration(milliseconds: 1));
  }

  static Set<String> _collectAttachmentPaths(
    List<NoteAttachment> attachments,
  ) => <String>{
    for (final attachment in attachments)
      ...<String?>[
        attachment.image?.src,
        attachment.recording?.src,
        attachment.sketch?.backgroundImage,
        attachment.sketch?.previewImage,
        attachment.sketch?.strokesFilePath,
      ].whereType<String>(),
  };
}

class LegacySketchMigrationRecoveryService {
  const LegacySketchMigrationRecoveryService._();

  static Future<void> recoverPending({
    required Database database,
    required NoteLockFileOperations fileOperations,
    required LegacySketchMigrationJournal journal,
  }) async {
    for (final record in await journal.load()) {
      try {
        final rows = await database.query(
          Note.model,
          columns: ['locked', 'attachments'],
          where: 'id = ?',
          whereArgs: [record.noteId],
          limit: 1,
        );
        final rawAttachments = rows.isEmpty
            ? null
            : rows.single['attachments'] as String?;
        final referencedPaths = rawAttachments == null
            ? <String>{}
            : await _strokesPaths(rawAttachments);
        final newPaths = record.replacements
            .map((replacement) => replacement.newPath)
            .toSet();
        final allReferenced =
            newPaths.isNotEmpty && newPaths.every(referencedPaths.contains);
        final anyReferenced = newPaths.any(referencedPaths.contains);
        final digestMatches =
            rawAttachments != null &&
            record.expectedAttachmentsDigest != null &&
            LegacySketchMigrationJournalRecord.attachmentsDigest(
                  rawAttachments,
                ) ==
                record.expectedAttachmentsDigest;
        final committed =
            rows.isNotEmpty &&
            (rows.single['locked'] == 1 || rows.single['locked'] == true) &&
            (allReferenced || digestMatches);

        if (committed) {
          var verified = true;
          for (final newPath in newPaths) {
            if (!await fileOperations.exists(newPath) ||
                !isBytesPasswordEncrypted(await fileOperations.read(newPath))) {
              verified = false;
              break;
            }
          }
          if (!verified) {
            AppLogger.log(
              'Committed legacy sketch migration ${record.transactionId} '
              'has an unverified file; retaining journal',
            );
            continue;
          }
          var cleaned = true;
          for (final oldPath
              in record.replacements
                  .map((replacement) => replacement.oldPath)
                  .whereType<String>()
                  .where((value) => !referencedPaths.contains(value))) {
            if (await fileOperations.exists(oldPath) &&
                !await fileOperations.delete(oldPath)) {
              cleaned = false;
            }
          }
          if (cleaned) await journal.remove(record.transactionId);
          continue;
        }

        if (anyReferenced) {
          AppLogger.log(
            'Legacy sketch migration ${record.transactionId} is ambiguous; '
            'retaining both file sets',
          );
          continue;
        }
        var cleaned = true;
        for (final newPath in newPaths) {
          if (await fileOperations.exists(newPath) &&
              !await fileOperations.delete(newPath)) {
            cleaned = false;
          }
        }
        if (cleaned) await journal.remove(record.transactionId);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to recover legacy sketch migration '
          '${record.transactionId}',
          error,
          stackTrace,
        );
      }
    }
  }

  static Future<Set<String>> _strokesPaths(String serialized) async {
    var decoded = serialized;
    if (LocalDataEncryption.isEncrypted(decoded)) {
      decoded = await LocalDataEncryption.instance.decryptString(decoded);
    }
    final attachments = jsonDecode(decoded) as List<dynamic>;
    return attachments
        .map(
          (value) => NoteAttachment.fromJson(
            Map<String, dynamic>.from(value as Map),
          ).sketch?.strokesFilePath,
        )
        .whereType<String>()
        .toSet();
  }
}
