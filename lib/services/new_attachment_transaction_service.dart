import 'dart:async';
import 'dart:convert';

import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

typedef AttachmentSessionRead = Future<Uint8List> Function(String filePath);
typedef AttachmentSessionWrite =
    Future<void> Function(String filePath, Uint8List plaintext);
typedef AttachmentSourceCleanup = Future<void> Function(String sourcePath);

enum _AttachmentSourceOwner { caller, commit, finished }

/// Tracks the single owner responsible for an app-created attachment source.
/// Cleanup is idempotent and becomes the commit helper's responsibility only
/// after an explicit handoff.
class UncommittedAttachmentSourceLease {
  final String sourcePath;
  final AttachmentSourceCleanup cleanupSource;
  _AttachmentSourceOwner _owner = _AttachmentSourceOwner.caller;

  UncommittedAttachmentSourceLease({
    required this.sourcePath,
    required this.cleanupSource,
  });

  bool get isCallerOwned => _owner == _AttachmentSourceOwner.caller;

  void transferToCommit() {
    if (_owner == _AttachmentSourceOwner.caller) {
      _owner = _AttachmentSourceOwner.commit;
    }
  }

  void relinquishToExistingCommit() {
    _owner = _AttachmentSourceOwner.finished;
  }

  void markCommitted() {
    _owner = _AttachmentSourceOwner.finished;
  }

  Future<void> releaseByCaller() =>
      _releaseIfOwnedBy(_AttachmentSourceOwner.caller);

  Future<void> releaseAfterFailedCommit() =>
      _releaseIfOwnedBy(_AttachmentSourceOwner.commit);

  Future<void> _releaseIfOwnedBy(_AttachmentSourceOwner expectedOwner) async {
    if (_owner != expectedOwner) return;
    _owner = _AttachmentSourceOwner.finished;
    try {
      await cleanupSource(sourcePath);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Could not safely release an uncommitted attachment source',
        error,
        stackTrace,
      );
    }
  }
}

@immutable
class NewAttachmentTransactionRecord {
  static const currentVersion = 1;

  final int version;
  final String transactionId;
  final String originalPath;
  final String stagedPath;

  const NewAttachmentTransactionRecord({
    this.version = currentVersion,
    required this.transactionId,
    required this.originalPath,
    required this.stagedPath,
  });

  factory NewAttachmentTransactionRecord.fromJson(Map<String, dynamic> json) =>
      NewAttachmentTransactionRecord(
        version: json['version'] as int? ?? 0,
        transactionId: json['transactionId'] as String,
        originalPath: json['originalPath'] as String,
        stagedPath: json['stagedPath'] as String,
      );

  Map<String, dynamic> toJson() => {
    'version': version,
    'transactionId': transactionId,
    'originalPath': originalPath,
    'stagedPath': stagedPath,
  };
}

/// Local-only path journal. It never contains attachment bytes, note content,
/// or a PIN.
class NewAttachmentTransactionJournal {
  static String get preferenceKey =>
      FirebaseScopedPreferences.key('pending_new_attachment_transactions_v1');
  static Future<void> _tail = Future<void>.value();

  final SharedPreferences preferences;

  const NewAttachmentTransactionJournal(this.preferences);

  Future<List<NewAttachmentTransactionRecord>> load() async {
    final encoded = preferences.getString(preferenceKey);
    if (encoded == null || encoded.isEmpty) return const [];
    try {
      final values = jsonDecode(encoded) as List<dynamic>;
      return values
          .map(
            (value) => NewAttachmentTransactionRecord.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where(
            (record) =>
                record.version == NewAttachmentTransactionRecord.currentVersion,
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to read pending attachment transactions',
        error,
        stackTrace,
      );
      return const [];
    }
  }

  Future<void> put(NewAttachmentTransactionRecord record) => _mutate(() async {
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
    await _save(
      (await load())
          .where((record) => record.transactionId != transactionId)
          .toList(growable: false),
    );
  });

  static Future<void> _mutate(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(List<NewAttachmentTransactionRecord> records) async {
    if (records.isEmpty) {
      final removed = await preferences.remove(preferenceKey);
      if (!removed && preferences.containsKey(preferenceKey)) {
        throw StateError('Unable to clear pending attachment transactions');
      }
      return;
    }
    final saved = await preferences.setString(
      preferenceKey,
      jsonEncode(records.map((record) => record.toJson()).toList()),
    );
    if (!saved) {
      throw StateError('Unable to persist pending attachment transactions');
    }
  }
}

@immutable
class PendingAttachmentSourceCleanupRecord {
  static const currentVersion = 1;

  final int version;
  final String cleanupId;
  final String sourcePath;

  const PendingAttachmentSourceCleanupRecord({
    this.version = currentVersion,
    required this.cleanupId,
    required this.sourcePath,
  });

  factory PendingAttachmentSourceCleanupRecord.fromJson(
    Map<String, dynamic> json,
  ) => PendingAttachmentSourceCleanupRecord(
    version: json['version'] as int? ?? 0,
    cleanupId: json['cleanupId'] as String,
    sourcePath: json['sourcePath'] as String,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'cleanupId': cleanupId,
    'sourcePath': sourcePath,
  };
}

/// Local-only cleanup intent for caller-owned attachment sources. It contains
/// paths only, never attachment bytes, note content, or authentication data.
class PendingAttachmentSourceCleanupJournal {
  static String get preferenceKey =>
      FirebaseScopedPreferences.key('pending_attachment_source_cleanup_v1');
  static Future<void> _tail = Future<void>.value();

  final SharedPreferences preferences;

  const PendingAttachmentSourceCleanupJournal(this.preferences);

  Future<List<PendingAttachmentSourceCleanupRecord>> load() async {
    final encoded = preferences.getString(preferenceKey);
    if (encoded == null || encoded.isEmpty) return const [];
    try {
      final values = jsonDecode(encoded) as List<dynamic>;
      return values
          .map(
            (value) => PendingAttachmentSourceCleanupRecord.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .where(
            (record) =>
                record.version ==
                PendingAttachmentSourceCleanupRecord.currentVersion,
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to read pending attachment source cleanup records',
        error,
        stackTrace,
      );
      return const [];
    }
  }

  Future<void> put(PendingAttachmentSourceCleanupRecord record) =>
      _mutate(() async {
        final records = (await load()).toList(growable: true);
        final index = records.indexWhere(
          (candidate) => candidate.cleanupId == record.cleanupId,
        );
        if (index == -1) {
          records.add(record);
        } else {
          records[index] = record;
        }
        await _save(records);
      });

  Future<void> remove(String cleanupId) => _mutate(() async {
    await _save(
      (await load())
          .where((record) => record.cleanupId != cleanupId)
          .toList(growable: false),
    );
  });

  static Future<void> _mutate(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(List<PendingAttachmentSourceCleanupRecord> records) async {
    if (records.isEmpty) {
      final removed = await preferences.remove(preferenceKey);
      if (!removed && preferences.containsKey(preferenceKey)) {
        throw StateError(
          'Unable to clear pending attachment source cleanup records',
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
        'Unable to persist pending attachment source cleanup records',
      );
    }
  }
}

@immutable
class PreparedNewAttachmentFile {
  final NewAttachmentTransactionRecord record;

  const PreparedNewAttachmentFile({required this.record});

  String get originalPath => record.originalPath;
  String get stagedPath => record.stagedPath;
}

enum NewAttachmentPreparationFailure {
  sourceUnavailable,
  protection,
  verification,
}

class NewAttachmentPreparationException implements Exception {
  final NewAttachmentPreparationFailure failure;
  final String message;
  final Object? cause;

  const NewAttachmentPreparationException(
    this.failure,
    this.message, [
    this.cause,
  ]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class NewAttachmentTransactionService {
  final NoteLockFileOperations operations;
  final NewAttachmentTransactionJournal journal;

  const NewAttachmentTransactionService({
    required this.operations,
    required this.journal,
  });

  Future<PreparedNewAttachmentFile> prepare({
    required String sourcePath,
    required AttachmentSessionRead readForSession,
    required AttachmentSessionWrite writeForSession,
  }) async {
    if (sourcePath.isEmpty ||
        sourcePath.startsWith('http') ||
        sourcePath.startsWith('data:')) {
      throw const NewAttachmentPreparationException(
        NewAttachmentPreparationFailure.sourceUnavailable,
        'A local attachment source is required',
      );
    }
    final resolvedSourcePath = await operations.resolve(sourcePath);
    if (!await operations.exists(resolvedSourcePath)) {
      throw const NewAttachmentPreparationException(
        NewAttachmentPreparationFailure.sourceUnavailable,
        'The attachment source is unavailable',
      );
    }

    final extension = path.extension(sourcePath);
    final transactionId = operations.newId();
    final stagedPath = path.join(
      await operations.documentDirectory(),
      '${operations.newId()}${extension.isEmpty ? '.bin' : extension}',
    );
    final record = NewAttachmentTransactionRecord(
      transactionId: transactionId,
      originalPath: sourcePath,
      stagedPath: stagedPath,
    );

    try {
      await journal.put(record);
      final plaintext = await readForSession(resolvedSourcePath);
      if (plaintext.isEmpty) {
        throw const NewAttachmentPreparationException(
          NewAttachmentPreparationFailure.sourceUnavailable,
          'The attachment source is empty',
        );
      }
      final resolvedStagedPath = await operations.resolve(stagedPath);
      await writeForSession(resolvedStagedPath, plaintext);
      final verified = await readForSession(resolvedStagedPath);
      if (!listEquals(plaintext, verified)) {
        throw const NewAttachmentPreparationException(
          NewAttachmentPreparationFailure.verification,
          'The protected attachment failed verification',
        );
      }
      return PreparedNewAttachmentFile(record: record);
    } catch (error) {
      try {
        final cleaned = await _deleteStoredPathIfPresent(
          stagedPath,
          operations,
        );
        if (cleaned) {
          await journal.remove(transactionId);
        } else {
          AppLogger.log(
            'Staged attachment cleanup deferred for transaction $transactionId',
          );
        }
      } catch (cleanupError, stackTrace) {
        AppLogger.error(
          'Failed to roll back a staged attachment',
          cleanupError,
          stackTrace,
        );
      }
      if (error is NewAttachmentPreparationException) rethrow;
      throw NewAttachmentPreparationException(
        NewAttachmentPreparationFailure.protection,
        'Failed to prepare the attachment safely',
        error,
      );
    }
  }

  Future<void> rollback(PreparedNewAttachmentFile prepared) async {
    final cleaned = await _deleteStoredPathIfPresent(
      prepared.stagedPath,
      operations,
    );
    if (!cleaned) {
      throw StateError('Unable to remove the staged attachment');
    }
    await journal.remove(prepared.record.transactionId);
  }

  /// Finishes cleanup after SQLite references the staged path. Cleanup failure
  /// is intentionally retryable through the retained journal.
  Future<bool> finishCommitted(
    PreparedNewAttachmentFile prepared,
    Database database,
  ) async {
    final references = await _resolvedReferences(database, operations);
    final staged = await operations.resolve(prepared.stagedPath);
    if (!references.contains(staged)) return false;

    final original = await operations.resolve(prepared.originalPath);
    if (!references.contains(original) &&
        !await _deleteResolvedPathIfPresent(original, operations)) {
      return false;
    }
    await journal.remove(prepared.record.transactionId);
    return true;
  }

  static Future<Set<String>> _resolvedReferences(
    Database database,
    NoteLockFileOperations operations,
  ) async {
    final raw = await NoteFileReferenceService.databaseReferencedLocalPaths(
      database,
    );
    final resolved = <String>{};
    for (final filePath in raw) {
      resolved.add(await operations.resolve(filePath));
    }
    return resolved;
  }

  /// Deletes a caller-owned source only when no note or file-sync row retains
  /// it. A reference-query failure propagates so callers fail safe.
  static Future<bool> deleteSourceIfUnreferenced({
    required String sourcePath,
    required Database database,
    required NoteLockFileOperations operations,
  }) async {
    final references = await _resolvedReferences(database, operations);
    final resolvedSource = await operations.resolve(sourcePath);
    if (references.contains(resolvedSource)) return false;
    return _deleteResolvedPathIfPresent(resolvedSource, operations);
  }

  static Future<bool> _deleteStoredPathIfPresent(
    String storedPath,
    NoteLockFileOperations operations,
  ) async {
    final resolvedPath = await operations.resolve(storedPath);
    return _deleteResolvedPathIfPresent(resolvedPath, operations);
  }

  static Future<bool> _deleteResolvedPathIfPresent(
    String resolvedPath,
    NoteLockFileOperations operations,
  ) async {
    if (!await operations.exists(resolvedPath)) return true;
    final deleted = await operations.delete(resolvedPath);
    return deleted || !await operations.exists(resolvedPath);
  }
}

class PendingAttachmentSourceCleanupService {
  final NoteLockFileOperations operations;
  final PendingAttachmentSourceCleanupJournal journal;

  const PendingAttachmentSourceCleanupService({
    required this.operations,
    required this.journal,
  });

  /// Records cleanup intent before touching the source so transient failures
  /// remain recoverable on the next startup.
  Future<bool> scheduleAndCleanup({
    required String sourcePath,
    required Database database,
  }) async {
    final record = PendingAttachmentSourceCleanupRecord(
      cleanupId: operations.newId(),
      sourcePath: sourcePath,
    );
    await journal.put(record);
    return cleanupRecord(record: record, database: database);
  }

  Future<bool> cleanupRecord({
    required PendingAttachmentSourceCleanupRecord record,
    required Database database,
  }) async {
    final references =
        await NewAttachmentTransactionService._resolvedReferences(
          database,
          operations,
        );
    final resolvedSource = await operations.resolve(record.sourcePath);
    if (references.contains(resolvedSource)) {
      await journal.remove(record.cleanupId);
      return true;
    }

    final cleaned =
        await NewAttachmentTransactionService._deleteResolvedPathIfPresent(
          resolvedSource,
          operations,
        );
    if (!cleaned) return false;
    await journal.remove(record.cleanupId);
    return true;
  }
}

Future<bool> scheduleUncommittedAttachmentSourceCleanup(
  String sourcePath,
) async {
  final operations = await NoteLockFileOperations.platform();
  final cleanupService = PendingAttachmentSourceCleanupService(
    operations: operations,
    journal: PendingAttachmentSourceCleanupJournal(await AppState.prefs),
  );
  return cleanupService.scheduleAndCleanup(
    sourcePath: sourcePath,
    database: AppState.db,
  );
}

class NewAttachmentTransactionRecoveryService {
  NewAttachmentTransactionRecoveryService._();

  static Future<void> recoverPending({
    required Database database,
    required NoteLockFileOperations operations,
    required NewAttachmentTransactionJournal journal,
  }) async {
    for (final record in await journal.load()) {
      try {
        final references =
            await NewAttachmentTransactionService._resolvedReferences(
              database,
              operations,
            );
        final staged = await operations.resolve(record.stagedPath);
        final original = await operations.resolve(record.originalPath);

        if (references.contains(staged)) {
          if (!references.contains(original) &&
              !await NewAttachmentTransactionService._deleteResolvedPathIfPresent(
                original,
                operations,
              )) {
            continue;
          }
        } else if (!await NewAttachmentTransactionService._deleteResolvedPathIfPresent(
          staged,
          operations,
        )) {
          continue;
        }
        await journal.remove(record.transactionId);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to recover pending attachment transaction '
          '${record.transactionId}',
          error,
          stackTrace,
        );
      }
    }
  }
}

class PendingAttachmentSourceCleanupRecoveryService {
  PendingAttachmentSourceCleanupRecoveryService._();

  static Future<void> recoverPending({
    required Database database,
    required NoteLockFileOperations operations,
    required PendingAttachmentSourceCleanupJournal journal,
  }) async {
    final service = PendingAttachmentSourceCleanupService(
      operations: operations,
      journal: journal,
    );
    for (final record in await journal.load()) {
      try {
        await service.cleanupRecord(record: record, database: database);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to recover pending attachment source cleanup '
          '${record.cleanupId}',
          error,
          stackTrace,
        );
      }
    }
  }
}
