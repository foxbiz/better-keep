import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/attachment_repair_coordinator.dart';
import 'package:better_keep/services/downloaded_attachment_batch.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:better_keep/services/cloud_read.dart';
import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:better_keep/services/async_operation_coalescer.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/reminder_sync_codec.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/note_encryption.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_cloud_repository.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:better_keep/services/remote_pull_lifecycle.dart';
import 'package:better_keep/services/remote_attachment_payload.dart';
import 'package:better_keep/services/remote_content_apply_coordinator.dart';
import 'package:better_keep/services/remote_content_failure_state.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_document_revision.dart';
import 'package:better_keep/services/remote_local_id_resolver.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/retry_controller.dart';
import 'package:better_keep/services/sketch_preview_generator.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/services/staged_checkpoint.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Result of downloading a file
enum DownloadResult {
  /// File downloaded successfully
  success,

  /// Temporary failure (network, etc.) - should retry later
  temporaryFailure,

  /// Permanent failure (object-not-found) - file is gone, skip this attachment
  permanentFailure,

  /// A required local dependency is unavailable. Do not consume retry budget.
  deferredDependency,
}

enum AttachmentCiphertextKind { plaintext, passwordProtected, e2ee }

class SyncEncryptionUnavailable implements Exception {
  const SyncEncryptionUnavailable();

  @override
  String toString() => 'SyncEncryptionUnavailable: UMK is not available';
}

@visibleForTesting
Uint8List requireSyncEncryptionKey({
  required bool cryptoReady,
  required Uint8List? umk,
}) {
  if (!cryptoReady || umk == null) {
    throw const SyncEncryptionUnavailable();
  }
  return Uint8List.fromList(umk);
}

@visibleForTesting
void validateCapturedSyncEncryptionKey({
  required bool cryptoReady,
  required Uint8List captured,
  required Uint8List? current,
}) {
  if (!cryptoReady || current == null || current.length != captured.length) {
    throw const SyncEncryptionUnavailable();
  }
  for (var index = 0; index < captured.length; index++) {
    if (captured[index] != current[index]) {
      throw const SyncEncryptionUnavailable();
    }
  }
}

/// Explicit PIN protection takes precedence over the structural E2EE
/// heuristic. An E2EE-wrapped ENCP file does not expose the ENCP header until
/// its outer layer has been decrypted.
@visibleForTesting
AttachmentCiphertextKind classifyAttachmentCiphertext(Uint8List bytes) {
  if (isBytesPasswordEncrypted(bytes)) {
    return AttachmentCiphertextKind.passwordProtected;
  }
  if (FileEncryption.looksEncrypted(bytes)) {
    return AttachmentCiphertextKind.e2ee;
  }
  return AttachmentCiphertextKind.plaintext;
}

/// Result of downloading a file with path
class FileDownloadResult {
  final DownloadResult result;
  final String? localPath;
  final RemoteNoteFailureCategory? category;
  final String? code;

  FileDownloadResult(this.result, [this.localPath, this.category, this.code]);

  bool get isSuccess => result == DownloadResult.success;
  bool get isPermanentFailure => result == DownloadResult.permanentFailure;
  bool get isTemporaryFailure => result == DownloadResult.temporaryFailure;
  bool get isDeferred => result == DownloadResult.deferredDependency;
}

class AttachmentBatchDownloadResult {
  const AttachmentBatchDownloadResult.success(this.attachments)
    : failure = null;

  const AttachmentBatchDownloadResult.failure(this.failure)
    : attachments = null;

  final List<NoteAttachment>? attachments;
  final RemoteNoteApplyResult? failure;

  bool get isSuccess => failure == null;
}

bool _isRemoteStorageLocator(String value) =>
    value.startsWith('http://') ||
    value.startsWith('https://') ||
    value.startsWith('gs://');

class NoteSyncService {
  @visibleForTesting
  static Future<void> Function()? refreshOperationOverride;

  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  StreamSubscription<User?>? _userStreamSubscription;
  bool _initialized = false;
  int _sessionGeneration = 0;
  int _cloudGeneration = 0;
  final _initializationGate = AsyncInitializationGate();
  bool _resumingCachedSyncs = false;
  final InitialHydrationGate _initialHydration = InitialHydrationGate();
  final HydrationRetryController _listenerRetry = HydrationRetryController();
  final ExponentialBackoffRetryController _pullRetry =
      ExponentialBackoffRetryController();
  final NoteCloudRepository _cloudRepository = NoteCloudRepository();
  final RemoteContentRetryLedger _contentRetryLedger =
      RemoteContentRetryLedger();
  final Map<String, Timer> _contentRetryTimers = {};
  final _dependencyRechecks =
      AsyncOperationCoalescer<(Object, String, int, int), void>();
  late final RemoteContentApplyCoordinator _contentApplyCoordinator;
  final AsyncKeyedSerializer<String> _listenerBatchSerializer =
      AsyncKeyedSerializer();
  final AsyncKeyedSerializer<String> _syncOperationSerializer =
      AsyncKeyedSerializer();
  static const String _listenerBatchKey = 'note-listener';
  static const String _syncOperationKey = 'note-sync';

  Future<void> get initialHydration => _initialHydration.ready;

  bool _lastKnownCryptoReady = false;

  NoteSyncService._internal() {
    _contentApplyCoordinator = RemoteContentApplyCoordinator(
      _contentRetryLedger,
    );
  }

  factory NoteSyncService() => _instance;

  static final NoteSyncService _instance = NoteSyncService._internal();

  FirebaseFirestore get _firestore => FirebaseBackend.firestore;

  FirebaseStorage get _storage => FirebaseBackend.storage;
  final AttachmentStorageRepository _defaultAttachmentStorage =
      AttachmentStorageRepository();
  @visibleForTesting
  static AttachmentStorageRepository? attachmentStorageOverride;
  AttachmentStorageRepository get _attachmentStorage =>
      attachmentStorageOverride ?? _defaultAttachmentStorage;

  @visibleForTesting
  Future<FileDownloadResult> downloadFileForTesting(
    String source,
    Note note, {
    String? expectedContentHash,
  }) async {
    final batch = await _newDownloadBatch();
    try {
      return await _downloadFile(
        source,
        note,
        batch,
        expectedContentHash: expectedContentHash,
      );
    } finally {
      await batch.finish();
    }
  }

  Future<DownloadedAttachmentBatch> _newDownloadBatch() async {
    final database = AppState.db;
    final files = NewAttachmentTransactionService(
      operations: await NoteLockFileOperations.platform(),
      journal: NewAttachmentTransactionJournal(await AppState.prefs),
    );
    requireCloudOperation();
    if (!identical(database, AppState.db)) {
      throw const CloudOperationCancelled();
    }
    return DownloadedAttachmentBatch(database: database, files: files);
  }

  /// Cache service for managing pending remote syncs
  @visibleForTesting
  static RemoteSyncCacheService? remoteCacheOverride;
  RemoteSyncCacheService get _syncCache =>
      remoteCacheOverride ?? RemoteSyncCacheService();

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<SyncProgress> syncStatus = ValueNotifier(
    SyncProgress.idle,
  );

  /// Tracks sync progress: (syncedCount, totalCount)
  final ValueNotifier<(int, int)> syncProgress = ValueNotifier((0, 0));

  /// Tracks note IDs currently being synced (outgoing push)
  final ValueNotifier<Set<int>> syncingOutgoing = ValueNotifier({});

  /// Tracks note IDs currently being synced (incoming pull)
  final ValueNotifier<Set<int>> syncingIncoming = ValueNotifier({});

  /// Tracks detailed sync status per note (for debug mode display)
  /// Key: noteId, Value: status message
  final ValueNotifier<Map<int, SyncProgress>> noteStatus = ValueNotifier({});

  /// Tracks notes that failed to sync
  final ValueNotifier<Set<int>> syncFailed = ValueNotifier({});
  final ValueNotifier<Set<int>> syncDeferred = ValueNotifier({});
  final Set<int> _transientSyncFailures = {};

  /// Durable remote-content failures keyed by their resolved local note ID.
  final ValueNotifier<Map<int, RemoteContentRetryEntry>> contentFailures =
      ValueNotifier({});

  User? get currentUser => AuthService.currentUser;
  CollectionReference<Map<String, dynamic>> get _notesCollection =>
      _cloudRepository.notes(currentUser!.uid);

  void _setNoteStatus(int noteId, SyncProgress status) {
    noteStatus.value = {...noteStatus.value, noteId: status};
  }

  void _clearNoteStatus(int noteId) {
    noteStatus.value = Map.from(noteStatus.value)..remove(noteId);
  }

  void _markSyncFailed(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    _transientSyncFailures.add(noteId);
    _publishSyncFailures();
  }

  void _clearSyncFailed(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    _transientSyncFailures.remove(noteId);
    _publishSyncFailures();
  }

  void _publishSyncFailures() {
    syncFailed.value = combinedRemoteSyncFailureIds(
      transientFailures: _transientSyncFailures,
      contentFailures: contentFailures.value.values,
    );
    syncDeferred.value = remoteSyncDeferredIds(contentFailures.value.values);
  }

  void _setContentFailure(RemoteContentRetryEntry entry) {
    contentFailures.value = upsertRemoteContentFailure(
      contentFailures.value,
      entry,
    );
    if (entry.state == RemoteContentRetryState.deferred) {
      _clearNoteStatus(entry.localId);
    } else {
      _setNoteStatus(entry.localId, const SyncProgress(SyncPhase.failed));
    }
    _publishSyncFailures();
  }

  void _clearContentFailureForRemoteDocument(
    String remoteDocumentId, {
    int? resolvedLocalId,
  }) {
    final removedIds = contentFailures.value.entries
        .where((entry) => entry.value.remoteDocumentId == remoteDocumentId)
        .map((entry) => entry.key)
        .toList();
    if (resolvedLocalId != null) removedIds.add(resolvedLocalId);
    contentFailures.value = removeRemoteContentFailure(
      contentFailures.value,
      remoteDocumentId,
    );
    for (final localId in removedIds) {
      if (!_transientSyncFailures.contains(localId)) {
        _clearNoteStatus(localId);
      }
    }
    _publishSyncFailures();
  }

  void _clearTransientSyncFailures() {
    _transientSyncFailures.clear();
    _publishSyncFailures();
  }

  void _addSyncingOutgoing(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    syncingOutgoing.value = {...syncingOutgoing.value, noteId};
    _clearSyncFailed(noteId);
  }

  void _removeSyncingOutgoing(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    syncingOutgoing.value = {...syncingOutgoing.value}..remove(noteId);
    if (!contentFailures.value.containsKey(noteId)) {
      _clearNoteStatus(noteId);
    }
  }

  void _addSyncingIncoming(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    syncingIncoming.value = {...syncingIncoming.value, noteId};
  }

  void _removeSyncingIncoming(int noteId) {
    if (!cloudOperationIsCurrent()) return;
    syncingIncoming.value = {...syncingIncoming.value}..remove(noteId);
    if (!syncFailed.value.contains(noteId)) {
      _clearNoteStatus(noteId);
    }
  }

  /// Track the last user ID to detect login vs session restore
  String? _lastKnownUserId;

  bool Function() _captureSession({bool cloud = true}) {
    final current = AuthService.captureSession();
    final generation = _sessionGeneration;
    final cloudGeneration = _cloudGeneration;
    return () =>
        current() &&
        generation == _sessionGeneration &&
        (!cloud || cloudGeneration == _cloudGeneration);
  }

  Future<void> Function() _background(
    Future<void> Function() operation, {
    bool cloud = true,
  }) => bindBackgroundCloudOperation(
    _captureSession(cloud: cloud),
    operation,
    onError: (error, stack) {
      if (isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
      } else {
        syncStatus.value = const SyncProgress(SyncPhase.failed);
      }
      AppLogger.error('[SYNC] Background operation deferred', error, stack);
    },
  );

  void _onCloudStateChange() {
    if (AuthService.canSyncCloud) return;
    _cloudGeneration++;
    _syncTimer?.cancel();
    _pullRetry.cancel();
    _listenerRetry.cancel();
    unawaited(_stopRemoteListener());
    isSyncing.value = false;
    syncingOutgoing.value = {};
    syncingIncoming.value = {};
    syncStatus.value = SyncProgress.idle;
    for (final timer in _contentRetryTimers.values) {
      timer.cancel();
    }
    _contentRetryTimers.clear();
    noteStatus.value = {};
    _resumingCachedSyncs = false;
  }

  Future<void> init() => _initializationGate.run(() async {
    final current = _captureSession(cloud: false);
    try {
      await runCloudOperation(current, _initialize);
    } catch (_) {
      if (current()) await dispose();
      rethrow;
    }
  });

  Future<void> _initialize() async {
    // Prevent duplicate initialization and listener registration
    if (_initialized) return;
    _initialized = true;
    AuthService.cloudRecovery.state.addListener(_onCloudStateChange);

    AppLogger.log("[SYNC] SyncService initialized");

    final e2ee = E2EEService.instance;
    _lastKnownCryptoReady = e2ee.isCryptoReady;

    // Initialize the sync cache
    await _syncCache.init();
    requireCloudOperation();

    // Load last known user ID to detect login vs restore
    final prefs = await SharedPreferences.getInstance();
    requireCloudOperation();
    _lastKnownUserId = prefs.getString(
      FirebaseScopedPreferences.key('last_synced_user_id'),
    );

    if (currentUser != null) {
      // Review sessions are intentionally local-only.
      if (_isReviewSession) {
        AppLogger.log("[SYNC] Review session detected, skipping sync");
        return;
      }

      await _restoreContentRetryState(currentUser!.uid);

      // Sync if E2EE is ready or verifying in background
      // (verifyingInBackground means user can access notes while we verify)
      if (E2EEService.instance.isCryptoReady) {
        await recheckReadyDependencies();
        requireCloudOperation();
        // Check if there are pending syncs from previous session
        if (_syncCache.hasPendingSyncs) {
          final pendingCount = _syncCache.getPendingSyncs().length;
          AppLogger.log(
            "[SYNC] Found $pendingCount pending syncs from previous session, resuming...",
          );
          unawaited(_background(_resumePendingSyncs)());
        } else {
          final checkpoint = AppState.noteCloudSyncCheckpoint;
          if (checkpoint == null || checkpoint.requiresBootstrap) {
            AppLogger.log(
              "[SYNC] No durable note checkpoint, reconciling remote notes",
            );
            unawaited(_background(refresh)());
          } else {
            AppLogger.log("[SYNC] No pending syncs, starting fresh sync");
            unawaited(_background(_sync)());
          }
          await _startRemoteListener();
        }
      } else {
        AppLogger.log(
          "[SYNC] Skipping initial sync - E2EE status: ${E2EEService.instance.status.value}",
        );
      }
    }

    requireCloudOperation();
    // Listen for E2EE status changes to trigger sync when ready
    e2ee.status.addListener(_onE2EEReadinessChange);
    e2ee.deviceManager.hasUMK.addListener(_onE2EEReadinessChange);

    // Listen for subscription changes to start/stop sync when user upgrades/downgrades
    // Initialize with current subscription state
    _wasPreviouslyPaid = PlanService.instance.isPaid;
    PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);

    _userStreamSubscription = AuthService.userStream.listen((user) {
      if (!cloudOperationIsCurrent()) return;
      unawaited(
        _background(() async {
          if (user != null) {
            await _restoreContentRetryState(user.uid);
            if (!cloudOperationIsCurrent()) return;
            final isNewUser = _lastKnownUserId != user.uid;
            if (isNewUser) {
              // On login (new user or different user), clear lastSynced
              // Cache will be cleared by refresh() → startNewSync() when sync runs
              AppLogger.log(
                "[SYNC] New user login detected (was: $_lastKnownUserId, now: ${user.uid}), clearing sync state",
              );
              AppState.lastSynced = null;
              AppState.noteCloudSyncCheckpoint = null;

              // Save new user ID
              _lastKnownUserId = user.uid;
              final prefs = await SharedPreferences.getInstance();
              requireCloudOperation();
              await prefs.setString(
                FirebaseScopedPreferences.key('last_synced_user_id'),
                user.uid,
              );
              requireCloudOperation();

              // Only refresh if E2EE is ready - otherwise wait for E2EE status change
              // This prevents Firestore connections before E2EE initialization completes
              if (E2EEService.instance.isCryptoReady) {
                // Don't clear cache separately — refresh() handles it via startNewSync()
                // Calling clear() here races with concurrent sync from E2EE ready handler
                if (!isSyncing.value) {
                  unawaited(_background(refresh)()); // Full refresh on login.
                }
              } else {
                // E2EE not ready — clear cache now, refresh will run when E2EE becomes ready
                requireCloudOperation();
                await _syncCache.clear();
                AppLogger.log(
                  "[SYNC] Deferring refresh - E2EE not ready (status: ${E2EEService.instance.status.value})",
                );
              }
            } else {
              AppLogger.log(
                "[SYNC] Session restored for same user (${user.uid}), keeping sync state",
              );
            }
            // Only start remote listener if E2EE is ready
            if (E2EEService.instance.isCryptoReady) {
              await _startRemoteListener();
            }
          } else {
            await _stopRemoteListener();
            requireCloudOperation();
            await _syncCache.clear();
            for (final timer in _contentRetryTimers.values) {
              timer.cancel();
            }
            _contentRetryTimers.clear();
          }
        }, cloud: false)(),
      );
    });
  }

  /// Resume syncing from cached pending syncs
  Future<void> _resumePendingSyncs() {
    final current = _captureSession();
    return _syncOperationSerializer.run(_syncOperationKey, () async {
      if (!current()) return;
      await runCloudOperation(current, _resumePendingSyncsUnlocked);
    });
  }

  Future<void> _resumePendingSyncsUnlocked() async {
    if (currentUser == null) return;
    if (!_canReceiveSync) return;

    _resumingCachedSyncs = true;

    // Yield to ensure we don't update state during a build phase
    await Future.microtask(() {});
    if (currentUser == null || !_canReceiveSync) {
      _resumingCachedSyncs = false;
      return;
    }

    final pendingCount = _syncCache.getPendingSyncs().length;
    final cacheAge = _syncCache.metadata?.updatedAt != null
        ? DateTime.now().difference(_syncCache.metadata!.updatedAt).inMinutes
        : 0;
    var restoreListener = true;
    var scheduleReconciliation = false;
    var scheduleCachedResume = false;

    try {
      isSyncing.value = true;
      await _stopRemoteListener(cancelRetry: false);
      syncStatus.value = const SyncProgress(SyncPhase.resuming);
      AppLogger.log(
        "[SYNC] RESUME START: $pendingCount pending syncs from cache (age: ${cacheAge}min)",
      );

      // Refresh stale cache data from Firebase to ensure we have latest versions
      await _refreshStaleCacheData();

      await _processCachedSyncs();

      // Only show "Sync Complete" if there are no failed syncs
      final failedSyncs = _syncCache.getPendingSyncs();
      final metadata = _syncCache.metadata;
      final disposition = classifyRemoteSyncResume(
        metadata: metadata,
        hasRemainingEntries: _syncCache.hasPendingSyncs,
      );
      switch (disposition) {
        case RemoteSyncResumeDisposition.commitDurable:
          syncStatus.value = const SyncProgress(SyncPhase.complete);
          AppState.noteCloudSyncCheckpoint = CloudSyncCheckpoint(
            bootstrapped: true,
            cursor: metadata?.lastCursor,
          );
          requireCloudOperation();
          await _syncCache.clear();
          AppLogger.log(
            "[SYNC] RESUME COMPLETE: Cache cleared after successful sync",
          );
          break;
        case RemoteSyncResumeDisposition.reconcileLegacy:
          // A cache created by an older app has no exact safe cursor. Its
          // contents were applied, then a one-time reconciliation establishes
          // the new checkpoint without risking a skipped write.
          syncStatus.value = const SyncProgress(SyncPhase.restarting);
          requireCloudOperation();
          await _syncCache.clear();
          AppState.noteCloudSyncCheckpoint = null;
          scheduleReconciliation = true;
          restoreListener = false;
          AppLogger.log(
            "[SYNC] RESUME LEGACY: Applied cache; scheduling full reconciliation",
          );
          break;
        case RemoteSyncResumeDisposition.restartIncomplete:
          syncStatus.value = const SyncProgress(SyncPhase.restarting);
          final legacyCache =
              metadata?.cursorSchemaVersion !=
              CloudSyncCheckpoint.schemaVersion;
          requireCloudOperation();
          await _syncCache.clear();
          if (legacyCache) {
            AppState.noteCloudSyncCheckpoint = null;
          }
          scheduleReconciliation = true;
          restoreListener = false;
          AppLogger.log(
            "[SYNC] RESUME INCOMPLETE: Pagination did not finish; "
            "restarting from the last durable checkpoint",
          );
          break;
        case RemoteSyncResumeDisposition.retainPending:
          scheduleCachedResume = true;
          AppLogger.log(
            "[SYNC] RESUME PARTIAL: ${failedSyncs.length} notes failed, cache retained",
          );
          break;
      }
    } catch (e, stack) {
      if (!cloudOperationIsCurrent()) return;
      if (isCloudConnectionFailure(e)) {
        AuthService.cloudRecovery.connectionLost();
        syncStatus.value = SyncProgress.idle;
      } else {
        syncStatus.value = const SyncProgress(SyncPhase.failed);
      }
      AppLogger.log("[SYNC] RESUME FAILED: $e\n$stack");
      scheduleCachedResume =
          _syncCache.hasPendingSyncs &&
          _syncCache.metadata?.allPagesFetched == true;
    } finally {
      if (cloudOperationIsCurrent()) {
        isSyncing.value = false;
        _resumingCachedSyncs = false;
        if (scheduleReconciliation) {
          unawaited(Future<void>.microtask(_background(refresh)));
        } else {
          if (restoreListener) await _startRemoteListener();
          if (scheduleCachedResume && _canReceiveSync) {
            if (_canReceiveSync) {
              _pullRetry.schedule(
                _background(() async {
                  if (_initialized && currentUser != null && _canReceiveSync) {
                    await _resumePendingSyncs();
                  }
                }),
              );
            }
          }
        }
        Future.delayed(const Duration(seconds: 2), () {
          // Only clear status message if no failed syncs
          if (cloudOperationIsCurrent() &&
              !isSyncing.value &&
              syncFailed.value.isEmpty) {
            syncStatus.value = SyncProgress.idle;
          }
        });
      }
    }
  }

  /// Refresh stale cached data from Firebase
  /// Fetches only updated_at for cached notes to check if they've been updated
  Future<void> _refreshStaleCacheData() async {
    // Skip if cache is fresh (updated within last 5 minutes)
    if (!_syncCache.isCacheStale()) {
      AppLogger.log("[SYNC] REFRESH: Cache is fresh, skipping refresh");
      return;
    }

    final pendingSyncs = _syncCache.getPendingSyncs();
    if (pendingSyncs.isEmpty) return;

    AppLogger.log(
      "[SYNC] REFRESH START: Checking ${pendingSyncs.length} cached notes for updates from Firebase",
    );
    syncStatus.value = const SyncProgress(SyncPhase.checkingForUpdates);

    int updatedCount = 0;
    int deletedCount = 0;

    // Batch fetch remote docs to check for updates
    // Firestore allows up to 10 documents per whereIn query
    const batchSize = 10;
    final remoteDocIds = pendingSyncs.map((s) => s.remoteDocId).toList();

    for (var i = 0; i < remoteDocIds.length; i += batchSize) {
      final batch = remoteDocIds.skip(i).take(batchSize).toList();
      final batchNum = (i ~/ batchSize) + 1;
      final totalBatches = (remoteDocIds.length / batchSize).ceil();

      AppLogger.log(
        "[SYNC] REFRESH: Fetching batch $batchNum/$totalBatches (${batch.length} docs)",
      );

      try {
        // Use FieldPath.documentId() to query by document IDs
        final querySnapshot = await _notesCollection
            .where(FieldPath.documentId, whereIn: batch)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        requireCloudOperation();
        if (querySnapshot.metadata.isFromCache ||
            querySnapshot.metadata.hasPendingWrites) {
          throw const CloudVerificationUnavailable();
        }

        for (final doc in querySnapshot.docs) {
          final remoteData = doc.data();
          final cachedSync = _syncCache.getSync(doc.id);

          if (cachedSync == null) continue;

          // Check if remote data has been updated since we cached it
          final cachedUpdatedAt = cachedSync.remoteData['updated_at'];
          final remoteUpdatedAt = remoteData['updated_at'];

          if (cachedUpdatedAt != remoteUpdatedAt) {
            // Remote has newer data, update cache
            await _syncCache.updateRemoteData(doc.id, remoteData);
            updatedCount++;
            AppLogger.log(
              "[SYNC] REFRESH: Note ${doc.id} updated (cached: $cachedUpdatedAt -> remote: $remoteUpdatedAt)",
            );
          }
        }

        // Check for deleted notes (docs that no longer exist)
        final fetchedIds = querySnapshot.docs.map((doc) => doc.id).toSet();

        for (final docId in batch) {
          final cachedSync = pendingSyncs.cast<PendingRemoteSync?>().firstWhere(
            (s) => s?.remoteDocId == docId,
            orElse: () => null,
          );

          // Skip if no matching sync found in cache
          if (cachedSync == null) continue;

          if (!fetchedIds.contains(cachedSync.remoteDocId)) {
            // Note was deleted on remote, mark cache entry as deleted
            final updatedData = Map<String, dynamic>.from(
              cachedSync.remoteData,
            );
            updatedData['deleted'] = true;
            await _syncCache.updateRemoteData(
              cachedSync.remoteDocId,
              updatedData,
            );
            deletedCount++;
            AppLogger.log(
              "[SYNC] REFRESH: Note ${cachedSync.localId} deleted on remote",
            );
          }
        }
      } catch (e) {
        AppLogger.log("[SYNC] REFRESH ERROR: Batch $batchNum failed: $e");
        rethrow;
      }
    }

    AppLogger.log(
      "[SYNC] REFRESH COMPLETE: $updatedCount updated, $deletedCount deleted",
    );
  }

  void _onE2EEReadinessChange() {
    final e2ee = E2EEService.instance;
    final isNowReady = e2ee.isCryptoReady;
    final wasReady = _lastKnownCryptoReady;
    _lastKnownCryptoReady = isNowReady;

    AppLogger.log(
      '[SYNC] Crypto readiness changed from $wasReady to $isNowReady '
      '(status: ${e2ee.status.value})',
    );

    // Review sessions are intentionally local-only.
    if (_isReviewSession) {
      AppLogger.log("[SYNC] Review session detected, skipping sync");
      return;
    }

    // Trigger sync when E2EE becomes ready (from any non-ready state like pendingApproval)
    // Only trigger if we weren't already ready (to avoid duplicate syncs)
    if (isNowReady && !wasReady) {
      // E2EE just became ready - force a full sync to decrypt notes
      // This commonly happens after device approval or account recovery
      AppLogger.log(
        '[SYNC] Encryption key became available, triggering recovery sync',
      );

      // Schedule sync in a microtask to avoid blocking the listener callback
      // and to ensure proper async handling
      unawaited(
        Future<void>.microtask(
          _background(() async {
            // Wait for any in-progress sync to complete before starting recovery sync
            // This prevents race conditions and ensures clean state
            int waitAttempts = 0;
            const maxWaitAttempts = 10;
            while (isSyncing.value && waitAttempts < maxWaitAttempts) {
              AppLogger.log(
                "[SYNC] E2EE ready: Waiting for in-progress sync to complete (attempt ${waitAttempts + 1}/$maxWaitAttempts)",
              );
              await Future.delayed(const Duration(milliseconds: 500));
              requireCloudOperation();
              waitAttempts++;
            }

            // If sync is still running after waiting, skip — the in-progress sync
            // already has E2EE ready and will complete correctly
            if (isSyncing.value) {
              AppLogger.log(
                "[SYNC] E2EE ready: Sync still in progress after waiting, skipping redundant sync",
              );
              return;
            }

            await recheckReadyDependencies();
            requireCloudOperation();

            // Resume the smallest safe unit of work. A complete cached pagination
            // run must not be discarded merely because its key was unavailable.
            await _stopRemoteListener();
            requireCloudOperation();

            if (_syncCache.hasPendingSyncs) {
              await _resumePendingSyncs();
            } else {
              await refresh();
            }

            AppLogger.log("[SYNC] E2EE ready sync completed");
          }),
        ),
      );
    } else if (!isNowReady && wasReady) {
      // E2EE not ready - stop syncing encrypted content
      AppLogger.log('[SYNC] Encryption key unavailable, pausing remote sync');
      unawaited(_stopRemoteListener());
    }
  }

  /// Track the previous subscription state to detect upgrades
  bool _wasPreviouslyPaid = false;

  /// Called when subscription status changes
  void _onSubscriptionChange() {
    final isPaidNow = PlanService.instance.isPaid;
    AppLogger.log(
      "[SYNC] Subscription changed - isPaid: $isPaidNow (was: $_wasPreviouslyPaid)",
    );

    // User just upgraded to Pro
    if (isPaidNow && !_wasPreviouslyPaid) {
      AppLogger.log("[SYNC] User upgraded to Pro, enabling full sync");
      _wasPreviouslyPaid = true;

      // Trigger a full sync if E2EE is also ready
      if (currentUser != null && E2EEService.instance.isCryptoReady) {
        unawaited(_background(refresh)());
        unawaited(_background(_startRemoteListener)());
      }
    }
    // User downgraded or subscription expired
    else if (!isPaidNow && _wasPreviouslyPaid) {
      // Note: We keep the remote listener running for incoming sync
      // Only outgoing sync is disabled for non-Pro users
      AppLogger.log(
        "[SYNC] User no longer Pro, outgoing sync disabled but incoming sync continues",
      );
      _wasPreviouslyPaid = false;
    }
  }

  bool get _isReviewSession =>
      FirebaseBackend.isConfigured &&
      ReviewAccess.isAuthorizedSessionFor(currentUser);

  String get _incomingSyncState =>
      'backendConfigured=${FirebaseBackend.isConfigured}, '
      'cloud=${AuthService.cloudRecovery.state.value.name}, '
      'cryptoReady=${E2EEService.instance.isCryptoReady}, '
      'sessionInvalid=${AuthService.sessionInvalid.value}, review=$_isReviewSession';

  String get _pushSyncState =>
      '$_incomingSyncState, paid=${PlanService.instance.isPaid}';

  /// Check if we can receive/download sync (incoming):
  /// - E2EE must be ready
  /// - Not an authorized review session
  /// - Session must be valid
  /// Note: Pro subscription NOT required for receiving sync
  bool get _canReceiveSync {
    // If session is invalid (user deleted/disabled), disable all sync
    if (!AuthService.canSyncCloud) {
      return false;
    }

    // Review sessions skip sync entirely.
    if (_isReviewSession) {
      return false;
    }

    return E2EEService.instance.isCryptoReady;
  }

  /// Check if we can push/upload sync (outgoing):
  /// - Must have Pro subscription (cloud sync upload is a Pro feature)
  /// - E2EE must be ready
  /// - Not an authorized review session
  bool get _canPushSync {
    // Must be able to receive sync first
    if (!_canReceiveSync) {
      return false;
    }

    // Cloud sync upload requires Pro subscription
    if (!PlanService.instance.isPaid) {
      return false;
    }

    return true;
  }

  String _contentRetryKey(String userId, String remoteDocumentId) =>
      '$userId:$remoteDocumentId';

  Future<void> _restoreContentRetryState(String userId) async {
    for (final timer in _contentRetryTimers.values) {
      timer.cancel();
    }
    _contentRetryTimers.clear();
    final previousContentFailureIds = contentFailures.value.keys.toList();
    final entries = await _contentRetryLedger.listForUser(userId);
    requireCloudOperation();
    contentFailures.value = {for (final entry in entries) entry.localId: entry};
    for (final localId in previousContentFailureIds) {
      if (!contentFailures.value.containsKey(localId) &&
          !_transientSyncFailures.contains(localId)) {
        _clearNoteStatus(localId);
      }
    }
    _publishSyncFailures();
    for (final entry in entries) {
      if (entry.state != RemoteContentRetryState.deferred ||
          entry.isLocalAttachmentDependency) {
        _setNoteStatus(entry.localId, const SyncProgress(SyncPhase.failed));
      }
      if (entry.state == RemoteContentRetryState.waiting &&
          !entry.isLocalAttachmentDependency) {
        _scheduleContentRetry(entry);
      }
    }
  }

  Future<bool> _showContentFailureSummary(String userId) async {
    final failures = (await _contentRetryLedger.listForUser(userId)).where(
      (entry) =>
          entry.state != RemoteContentRetryState.deferred ||
          entry.isLocalAttachmentDependency,
    );
    requireCloudOperation();
    if (failures.isEmpty) return false;
    final attachmentCount = failures
        .where(
          (entry) => entry.category == RemoteNoteFailureCategory.attachment,
        )
        .length;
    final decryptionCount = failures
        .where(
          (entry) => entry.category == RemoteNoteFailureCategory.decryption,
        )
        .length;
    if (attachmentCount > 0 && decryptionCount == 0) {
      syncStatus.value = SyncProgress(
        SyncPhase.failed,
        failedCount: attachmentCount,
      );
    } else if (decryptionCount > 0 && attachmentCount == 0) {
      syncStatus.value = SyncProgress(
        SyncPhase.failed,
        failedCount: decryptionCount,
      );
    } else {
      syncStatus.value = SyncProgress(
        SyncPhase.failed,
        failedCount: failures.length,
      );
    }
    return true;
  }

  Future<bool> _hasEncryptionDependencies(String userId) async {
    final entries = await _contentRetryLedger.listForUser(userId);
    requireCloudOperation();
    return entries.any(
      (entry) =>
          entry.state == RemoteContentRetryState.deferred &&
          entry.isEncryptionDependency,
    );
  }

  void _scheduleContentRetry(RemoteContentRetryEntry entry) {
    if (!_canReceiveSync ||
        entry.isLocalAttachmentDependency ||
        entry.state != RemoteContentRetryState.waiting ||
        entry.nextRetryAt == null) {
      return;
    }
    final key = _contentRetryKey(entry.userId, entry.remoteDocumentId);
    _contentRetryTimers[key]?.cancel();
    final now = DateTime.now().toUtc();
    final delay = entry.nextRetryAt!.isAfter(now)
        ? entry.nextRetryAt!.difference(now)
        : Duration.zero;
    _contentRetryTimers[key] = Timer(delay, () {
      _contentRetryTimers.remove(key);
      unawaited(_runScheduledContentRetry(entry));
    });
  }

  Future<void> _runScheduledContentRetry(
    RemoteContentRetryEntry scheduled,
  ) async {
    final isCurrent = _captureSession();
    if (!_initialized ||
        !_canReceiveSync ||
        currentUser?.uid != scheduled.userId) {
      return;
    }
    try {
      await runCloudOperation(isCurrent, () async {
        final current = await _contentRetryLedger.get(
          scheduled.userId,
          scheduled.remoteDocumentId,
        );
        requireCloudOperation();
        if (current == null ||
            current.revision != scheduled.revision ||
            current.state != RemoteContentRetryState.waiting) {
          return;
        }
        final snapshot = await readCloudDocument(
          _notesCollection.doc(scheduled.remoteDocumentId),
          isCurrent: cloudOperationIsCurrent,
        );
        final data = snapshot.data();
        if (!snapshot.exists || data == null) {
          await _contentRetryLedger.clear(
            scheduled.userId,
            scheduled.remoteDocumentId,
          );
          requireCloudOperation();
          _clearContentFailureForRemoteDocument(
            scheduled.remoteDocumentId,
            resolvedLocalId: scheduled.localId,
          );
          return;
        }
        await _applyRemoteContentAutomatically(
          data,
          scheduled.remoteDocumentId,
        );
      });
    } catch (error, stack) {
      if (!isCurrent() || error is CloudOperationCancelled) return;
      if (isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
      }
      AppLogger.error('[SYNC] Content retry deferred', error, stack);
    }
  }

  Future<RemoteNoteApplyResult> _attemptRemoteApply(
    Map<String, dynamic> remoteData,
    String remoteDocumentId,
    int resolvedLocalId,
  ) async {
    final remoteLocalId = remoteData['local_id'];
    if (remoteLocalId is! int || remoteLocalId <= 0) {
      return const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-local-id',
      );
    }
    final isDeleted =
        remoteData['deleted'] == true || remoteData['deleted'] == 1;
    if (!isDeleted &&
        (!_hasValidRemoteDate(remoteData['updated_at']) ||
            !_hasValidRemoteDate(remoteData['created_at']))) {
      return const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-note-timestamps',
      );
    }
    try {
      return await _patchRemoteNote(
        remoteData,
        remoteDocumentId,
        resolvedLocalId,
      );
    } on RemoteAttachmentPayloadException catch (error, stack) {
      AppLogger.error(
        '[SYNC] Invalid attachment payload $remoteDocumentId (${error.code})',
        error,
        stack,
      );
      return RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        error.code,
      );
    } on FormatException catch (error, stack) {
      AppLogger.error(
        '[SYNC] Invalid remote note payload $remoteDocumentId',
        error,
        stack,
      );
      return const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-remote-note-payload',
      );
    } on TypeError catch (error, stack) {
      AppLogger.error(
        '[SYNC] Invalid remote note payload $remoteDocumentId',
        error,
        stack,
      );
      return const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-remote-note-payload',
      );
    } on ArgumentError catch (error, stack) {
      AppLogger.error(
        '[SYNC] Invalid remote note payload $remoteDocumentId',
        error,
        stack,
      );
      return const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-remote-note-payload',
      );
    } catch (error, stack) {
      if (error is CloudOperationCancelled || isCloudConnectionFailure(error)) {
        rethrow;
      }
      AppLogger.error(
        '[SYNC] Local apply failed for remote note $remoteDocumentId',
        error,
        stack,
      );
      return const RemoteNoteApplyResult.retryable(
        RemoteNoteFailureCategory.localApply,
        'local-note-apply-failed',
      );
    }
  }

  Future<void> _publishContentHandlingResult(
    String userId,
    String remoteDocumentId,
    RemoteContentHandlingResult result,
  ) async {
    final timerKey = _contentRetryKey(userId, remoteDocumentId);
    if (result.isApplied) {
      _contentRetryTimers.remove(timerKey)?.cancel();
      _clearContentFailureForRemoteDocument(
        remoteDocumentId,
        resolvedLocalId: result.localId,
      );
      return;
    }

    final entry = result.ledgerEntry!;
    _setContentFailure(entry);
    if (entry.state == RemoteContentRetryState.waiting) {
      _scheduleContentRetry(entry);
    } else {
      _contentRetryTimers.remove(timerKey)?.cancel();
    }
    await _showContentFailureSummary(userId);
  }

  Future<RemoteContentHandlingResult> _applyRemoteContentAutomatically(
    Map<String, dynamic> remoteData,
    String remoteDocumentId, {
    int? fallbackLocalId,
    String? deferredRevision,
  }) async {
    final user = currentUser;
    if (user == null) {
      throw StateError('Cannot apply remote content without a signed-in user');
    }
    final rawLocalId = remoteData['local_id'];
    final suggestedLocalId = rawLocalId is int && rawLocalId > 0
        ? rawLocalId
        : fallbackLocalId;
    final revision = remoteDocumentRevision(remoteData, remoteDocumentId);
    return _contentApplyCoordinator.handleAutomatic(
      userId: user.uid,
      remoteDocumentId: remoteDocumentId,
      revision: revision,
      deferredRevision: deferredRevision,
      resolveLocalId: (existing) => _resolveIncomingLocalId(
        remoteDocumentId,
        suggestedLocalId,
        reservation: existing,
      ),
      attempt: (resolvedLocalId) =>
          _attemptRemoteApply(remoteData, remoteDocumentId, resolvedLocalId),
      onHandled: (result) =>
          _publishContentHandlingResult(user.uid, remoteDocumentId, result),
    );
  }

  /// Compatibility entry point; all ready dependencies share a coalesced pass.
  Future<void> recheckLocalAttachmentDependencies() =>
      recheckReadyDependencies();

  /// Rechecks durable dependencies even behind the committed cursor. Content
  /// failures keep their budgets; a readiness transition is not required.
  Future<void> recheckReadyDependencies() {
    final user = currentUser;
    if (user == null || !_canReceiveSync || AppState.get('db') == null) {
      return Future.value();
    }
    final sessionCurrent = _captureSession();
    final database = AppState.db;
    bool current() =>
        sessionCurrent() && identical(AppState.get('db'), database);
    final key = (database, user.uid, _sessionGeneration, _cloudGeneration);
    return _dependencyRechecks.run(key, () async {
      try {
        await runCloudOperation(current, () async {
          final candidates = (await _contentRetryLedger.listForUser(user.uid))
              .where(
                (entry) =>
                    !entry.isExhausted &&
                    (entry.isLocalAttachmentDependency ||
                        (entry.state == RemoteContentRetryState.deferred &&
                            entry.isEncryptionDependency &&
                            E2EEService.instance.isCryptoReady)),
              )
              .toList();
          requireCloudOperation();
          for (final entry in candidates) {
            requireCloudOperation();
            if (!_canReceiveSync) return;
            final pending = await NoteSyncTrack.getByLocalId(entry.localId);
            requireCloudOperation();
            if (pending != null &&
                (pending.status != SyncStatus.synced ||
                    pending.action == SyncAction.delete)) {
              continue;
            }
            final snapshot = await readCloudDocument(
              _notesCollection.doc(entry.remoteDocumentId),
              isCurrent: cloudOperationIsCurrent,
            );
            requireCloudOperation();
            final data = snapshot.data();
            if (!snapshot.exists || data == null) {
              await _contentRetryLedger.clearIfRevision(entry);
              requireCloudOperation();
              await _restoreContentRetryState(user.uid);
              continue;
            }
            await _applyRemoteContentAutomatically(
              data,
              entry.remoteDocumentId,
              fallbackLocalId: entry.localId,
              deferredRevision: entry.revision,
            );
            requireCloudOperation();
          }
        });
      } catch (error, stack) {
        if (!current() || error is CloudOperationCancelled) return;
        if (!isCloudConnectionFailure(error)) {
          AppLogger.error('[SYNC] Dependency recheck deferred', error, stack);
        }
        rethrow;
      }
    });
  }

  Future<bool> retryFailedRemoteNote(String remoteDocumentId) {
    final current = _captureSession();
    return runCloudOperation(
      current,
      () => _retryFailedRemoteNote(remoteDocumentId),
    );
  }

  Future<bool> _retryFailedRemoteNote(String remoteDocumentId) async {
    final user = currentUser;
    if (user == null || !_canReceiveSync) return false;
    final existing = await _contentRetryLedger.get(user.uid, remoteDocumentId);
    try {
      final snapshot = await readCloudDocument(
        _notesCollection.doc(remoteDocumentId),
        isCurrent: cloudOperationIsCurrent,
      );
      final remoteData = snapshot.data();
      if (!snapshot.exists || remoteData == null) return false;
      final rawLocalId = remoteData['local_id'];
      final suggestedLocalId = rawLocalId is int && rawLocalId > 0
          ? rawLocalId
          : existing?.localId;
      final revision = remoteDocumentRevision(remoteData, remoteDocumentId);
      final result = await _contentApplyCoordinator.handleManual(
        userId: user.uid,
        remoteDocumentId: remoteDocumentId,
        revision: revision,
        resolveLocalId: (ledgerEntry) => _resolveIncomingLocalId(
          remoteDocumentId,
          suggestedLocalId,
          reservation: ledgerEntry,
        ),
        attempt: (resolvedLocalId) =>
            _attemptRemoteApply(remoteData, remoteDocumentId, resolvedLocalId),
        onHandled: (handled) =>
            _publishContentHandlingResult(user.uid, remoteDocumentId, handled),
      );
      return result.isApplied;
    } catch (error, stack) {
      if (!cloudOperationIsCurrent()) return false;
      if (isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
        return false;
      }
      AppLogger.error(
        '[SYNC] MANUAL CONTENT RETRY FAILED for $remoteDocumentId',
        error,
        stack,
      );
      if (existing != null) {
        _setContentFailure(existing);
      }
      return false;
    }
  }

  /// Start listening for real-time updates from Firebase
  Future<void> _startRemoteListener() {
    final current = _captureSession();
    if (!current() || !cloudOperationIsCurrent()) return Future.value();
    return runCloudOperation(current, _startRemoteListenerCurrent);
  }

  Future<void> _startRemoteListenerCurrent() async {
    await _stopRemoteListener(cancelRetry: false);
    requireCloudOperation();
    if (currentUser == null) return;
    if (_resumingCachedSyncs) {
      AppLogger.log(
        "[SYNC] LISTENER: Waiting for cached sync resume to finish",
      );
      return;
    }

    // Don't listen for remote changes if we can't decrypt them
    if (!_canReceiveSync) {
      AppLogger.log("[SYNC] LISTENER: Skipping - $_incomingSyncState");
      return;
    }

    final checkpoint = AppState.noteCloudSyncCheckpoint;
    if (checkpoint == null || checkpoint.requiresBootstrap) {
      AppLogger.log(
        "[SYNC] LISTENER: Waiting for durable checkpoint bootstrap",
      );
      return;
    }

    Query<Map<String, dynamic>> query = _notesCollection
        .orderBy(cloudSyncCommittedAtField)
        .orderBy(FieldPath.documentId);
    final cursor = checkpoint.cursor;
    if (cursor != null) {
      query = query.startAfter([cursor.timestamp, cursor.documentId]);
    }
    final hydrationGeneration = _initialHydration.startAttempt();

    _remoteListener = query
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (!cloudOperationIsCurrent()) return;
            _initialHydration.beginWork(
              hydrationGeneration,
              isFromCache: snapshot.metadata.isFromCache,
            );
            unawaited(
              _listenerBatchSerializer.run<void>(_listenerBatchKey, () async {
                var hydrationFailed = false;
                try {
                  if (!_initialHydration.isCurrent(hydrationGeneration) ||
                      _initialHydration.isFailed(hydrationGeneration)) {
                    return;
                  }
                  if (snapshot.docChanges.isEmpty) return;

                  // Filter only modified/added documents (not from local changes)
                  final changes = snapshot.docChanges.where(
                    (change) =>
                        !change.doc.metadata.hasPendingWrites &&
                        (change.type == DocumentChangeType.modified ||
                            change.type == DocumentChangeType.added),
                  );

                  if (changes.isEmpty) return;

                  AppLogger.log(
                    "[SYNC] REALTIME: Received ${changes.length} remote changes",
                  );

                  // Track processed note IDs to avoid duplicates in this batch
                  final Set<String> processedIds = {};
                  bool allSyncsSucceeded = true;
                  CloudSyncCursor? latestCursor;
                  int syncedCount = 0;
                  int skippedCount = 0;

                  for (final change in changes) {
                    final remoteData = change.doc.data();
                    if (remoteData == null) {
                      AppLogger.log(
                        "[SYNC] REALTIME: Remote data is null, skipping",
                      );
                      skippedCount++;
                      continue;
                    }

                    final remoteDocId = change.doc.id;
                    final documentCursor = CloudSyncCursor.fromDocument(
                      remoteData,
                      remoteDocId,
                    );
                    if (documentCursor == null) {
                      allSyncsSucceeded = false;
                      AppLogger.error(
                        '[SYNC] Quarantined malformed remote note $remoteDocId',
                        StateError(
                          '$cloudSyncCommittedAtField must be a Firestore timestamp',
                        ),
                      );
                      skippedCount++;
                      continue;
                    }
                    latestCursor = latestCursor == null
                        ? documentCursor
                        : latestCursor.max(documentCursor);

                    final remoteLocalId = remoteData['local_id'];
                    final suggestedLocalId =
                        remoteLocalId is int && remoteLocalId > 0
                        ? remoteLocalId
                        : null;
                    if (suggestedLocalId == null) {
                      AppLogger.error(
                        '[SYNC] Quarantined malformed remote note $remoteDocId',
                        StateError('local_id must be a positive integer'),
                      );
                    }
                    final localId = await _resolveIncomingLocalId(
                      remoteDocId,
                      suggestedLocalId,
                    );

                    // Skip if already processed in this batch
                    if (processedIds.contains(remoteDocId)) {
                      AppLogger.log(
                        "[SYNC] REALTIME: Note $localId already processed in this batch, skipping",
                      );
                      skippedCount++;
                      continue;
                    }
                    processedIds.add(remoteDocId);

                    // Check if this note is in the pending sync cache
                    // If so, update the cache with the new data
                    final wasInCache = await _syncCache.updateRemoteData(
                      remoteDocId,
                      remoteData,
                    );
                    if (wasInCache) {
                      AppLogger.log(
                        "[SYNC] REALTIME: Note $localId updated in cache, will process later",
                      );
                      skippedCount++;
                      // Don't process it now - it will be processed when the cache is processed
                      // But if it's currently in progress, it will be re-synced
                      continue;
                    }

                    // Check if this is a deleted note
                    final isDeleted =
                        remoteData['deleted'] == true ||
                        remoteData['deleted'] == 1;
                    final hasValidUpdatedAt =
                        isDeleted ||
                        _hasValidRemoteDate(remoteData['updated_at']);
                    final hasValidCreatedAt =
                        isDeleted ||
                        _hasValidRemoteDate(remoteData['created_at']);
                    if (!hasValidUpdatedAt) {
                      AppLogger.error(
                        '[SYNC] Quarantined malformed remote note $remoteDocId',
                        StateError('updated_at must be an ISO-8601 string'),
                      );
                    }
                    if (!hasValidCreatedAt) {
                      AppLogger.error(
                        '[SYNC] Quarantined malformed remote note $remoteDocId',
                        StateError('created_at must be an ISO-8601 string'),
                      );
                    }
                    if (suggestedLocalId == null ||
                        !hasValidUpdatedAt ||
                        !hasValidCreatedAt) {
                      _addSyncingIncoming(localId);
                      try {
                        final handled = await _applyRemoteContentAutomatically(
                          remoteData,
                          remoteDocId,
                          fallbackLocalId: localId,
                        );
                        if (handled.checkpointSafe) syncedCount++;
                      } finally {
                        _removeSyncingIncoming(localId);
                      }
                      continue;
                    }

                    if (isDeleted) {
                      AppLogger.log(
                        "[SYNC] REALTIME: Note $localId deleted, handling deletion",
                      );
                      _addSyncingIncoming(localId);
                      try {
                        await _handleRemoteDeletedNote(
                          localId,
                          remoteDocId: remoteDocId,
                        );
                        syncedCount++;
                      } finally {
                        _removeSyncingIncoming(localId);
                      }
                      continue;
                    }

                    // Check if there's a pending sync for this note - don't overwrite local changes
                    final pendingSync = await NoteSyncTrack.getByLocalId(
                      localId,
                    );
                    if (pendingSync != null &&
                        (pendingSync.status == SyncStatus.pending ||
                            pendingSync.status == SyncStatus.failed)) {
                      AppLogger.log(
                        "[SYNC] REALTIME: Note $localId has pending local changes, skipping",
                      );
                      skippedCount++;
                      continue;
                    }

                    final localNote =
                        await Note.findBySyncId(remoteDocId) ??
                        await Note.findById(localId);

                    if (localNote != null && remoteData['updated_at'] != null) {
                      final localUpdatedAt = localNote.updatedAt;
                      final updatedAtValue = remoteData['updated_at'];
                      final remoteUpdatedAt = updatedAtValue is String
                          ? DateTime.tryParse(updatedAtValue)
                          : null;
                      if (remoteUpdatedAt == null) {
                        allSyncsSucceeded = false;
                        AppLogger.error(
                          '[SYNC] Quarantined malformed remote note $remoteDocId',
                          StateError('updated_at must be an ISO-8601 string'),
                        );
                        skippedCount++;
                        continue;
                      }

                      // Always re-process notes stuck with decryption_failed content
                      final hasDecryptionError =
                          localNote.content == Note.decryptionFailedContent;

                      final equalTimestampBackgroundRepair =
                          !hasDecryptionError &&
                          localUpdatedAt != null &&
                          remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt) &&
                          await _needsEqualTimestampBackgroundRepair(
                            localNote,
                            remoteData,
                          );

                      if (!hasDecryptionError &&
                          localUpdatedAt != null &&
                          (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                              (remoteUpdatedAt.isAtSameMomentAs(
                                    localUpdatedAt,
                                  ) &&
                                  !equalTimestampBackgroundRepair))) {
                        AppLogger.log(
                          "[SYNC] REALTIME: Note $localId local is newer, skipping",
                        );
                        skippedCount++;
                        continue;
                      }
                    }

                    AppLogger.log(
                      "[SYNC] REALTIME: Patching note $localId from remote",
                    );
                    _addSyncingIncoming(localId);
                    try {
                      final handled = await _applyRemoteContentAutomatically(
                        remoteData,
                        remoteDocId,
                        fallbackLocalId: localId,
                      );
                      if (handled.checkpointSafe) {
                        syncedCount++;
                        AppLogger.log(
                          "[SYNC] REALTIME: Note $localId applied or durably queued",
                        );
                      }
                    } finally {
                      _removeSyncingIncoming(localId);
                    }
                  }

                  AppLogger.log(
                    "[SYNC] REALTIME COMPLETE: $syncedCount synced, $skippedCount skipped",
                  );

                  if (allSyncsSucceeded && latestCursor != null) {
                    final currentCheckpoint = AppState.noteCloudSyncCheckpoint;
                    if (_initialHydration.isCurrent(hydrationGeneration) &&
                        currentCheckpoint != null &&
                        !currentCheckpoint.requiresBootstrap) {
                      AppState.noteCloudSyncCheckpoint = currentCheckpoint
                          .advanceTo(latestCursor);
                    }
                  } else {
                    if (!allSyncsSucceeded) {
                      hydrationFailed = true;
                      AppLogger.log(
                        "[SYNC] REALTIME: Some syncs failed, not advancing checkpoint",
                      );
                    }
                  }
                } catch (error, stackTrace) {
                  if (!cloudOperationIsCurrent()) return;
                  if (isCloudConnectionFailure(error)) {
                    AuthService.cloudRecovery.connectionLost();
                  }
                  hydrationFailed = true;
                  AppLogger.error(
                    '[SYNC] REALTIME hydration attempt failed',
                    error,
                    stackTrace,
                  );
                } finally {
                  final outcome = _initialHydration.endWork(
                    hydrationGeneration,
                    failed: hydrationFailed,
                  );
                  switch (outcome) {
                    case HydrationWorkOutcome.retry:
                      unawaited(
                        Future<void>.microtask(
                          _background(
                            () => _restartRemoteListenerAfterFailure(
                              hydrationGeneration,
                            ),
                          ),
                        ),
                      );
                      break;
                    case HydrationWorkOutcome.ready:
                      _listenerRetry.succeeded();
                      break;
                    case HydrationWorkOutcome.stale:
                    case HydrationWorkOutcome.pending:
                      break;
                  }
                }
              }),
            );
          },
          onError: (error) {
            if (!cloudOperationIsCurrent()) return;
            if (isCloudConnectionFailure(error)) {
              AuthService.cloudRecovery.connectionLost();
            }
            AppLogger.error('[SYNC] REALTIME ERROR', error);
            _initialHydration.failAttempt(hydrationGeneration);
            unawaited(
              _background(
                () => _restartRemoteListenerAfterFailure(hydrationGeneration),
              )(),
            );
          },
        );

    AppLogger.log("[SYNC] LISTENER: Started real-time remote listener");
  }

  /// Stop listening for real-time updates
  Future<void> _restartRemoteListenerAfterFailure(int generation) async {
    if (!_initialHydration.isCurrent(generation)) return;
    await _stopRemoteListener(cancelRetry: false);
    requireCloudOperation();
    if (!_canReceiveSync) return;
    _listenerRetry.schedule(
      _background(() async {
        if (_initialized && currentUser != null && _canReceiveSync) {
          AppLogger.log('[SYNC] Restarting remote listener after failure');
          await _startRemoteListener();
        }
      }),
    );
  }

  bool _hasValidRemoteDate(Object? value) {
    return value == null ||
        (value is String && DateTime.tryParse(value) != null);
  }

  Future<void> _stopRemoteListener({bool cancelRetry = true}) async {
    if (cancelRetry) _listenerRetry.cancel();
    _initialHydration.invalidateAttempt();
    final listener = _remoteListener;
    _remoteListener = null;
    try {
      await listener?.cancel();
    } catch (e) {
      // Ignore errors when cancelling listener that wasn't fully initialized
      AppLogger.error(
        '[SYNC] Error stopping remote listener (safe to ignore)',
        e,
      );
    }
    await _listenerBatchSerializer.waitForIdle(_listenerBatchKey);
  }

  /// Dispose of all listeners and subscriptions.
  /// Call this when the app is shutting down or user logs out.
  Future<void> dispose() async {
    _sessionGeneration++;
    AuthService.cloudRecovery.state.removeListener(_onCloudStateChange);
    await _stopRemoteListener();
    _syncTimer?.cancel();
    _syncTimer = null;
    await _userStreamSubscription?.cancel();
    _userStreamSubscription = null;
    E2EEService.instance.status.removeListener(_onE2EEReadinessChange);
    E2EEService.instance.deviceManager.hasUMK.removeListener(
      _onE2EEReadinessChange,
    );
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    _initialized = false;
    _initializationGate.reset();
    _initialHydration.reset();
    _listenerRetry.cancel();
    _pullRetry.cancel();
    for (final timer in _contentRetryTimers.values) {
      timer.cancel();
    }
    _contentRetryTimers.clear();
    await _contentApplyCoordinator.waitForIdle();
    _transientSyncFailures.clear();
    contentFailures.value = {};
    syncingIncoming.value = {};
    syncingOutgoing.value = {};
    noteStatus.value = {};
    _publishSyncFailures();
  }

  Reference getNoteDocsRef(int noteId) {
    return _storage.ref().child('users/${currentUser!.uid}/notes/$noteId');
  }

  Future<void> sync([bool now = false]) async {
    _syncTimer?.cancel();

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[SYNC] Skipping sync request - $_pushSyncState");
      return;
    }

    if (now) {
      _syncTimer = null;
      await _sync();
      return;
    }

    _syncTimer = Timer(const Duration(seconds: 5), _background(_sync));
  }

  /// Retry remote content for a specific note that previously failed.
  /// Fetches the note from Firestore and re-processes it, bypassing the
  /// sync cache which may have already marked this note as completed.
  Future<bool> retryFailedRemoteNoteForLocalId(int noteId) async {
    if (currentUser == null) return false;
    if (!_canReceiveSync) {
      AppLogger.log("[SYNC] RETRY: Skipping - $_incomingSyncState");
      return false;
    }

    final syncTrack = await NoteSyncTrack.getByLocalId(noteId);
    final ledgerEntry = await _contentRetryLedger.getByLocalId(
      currentUser!.uid,
      noteId,
    );
    final remoteDocumentId =
        syncTrack?.remoteId ?? ledgerEntry?.remoteDocumentId;
    if (remoteDocumentId == null) {
      AppLogger.log(
        "[SYNC] RETRY: Note $noteId has no sync track or remote ID",
      );
      return false;
    }

    return retryFailedRemoteNote(remoteDocumentId);
  }

  /// Manual refresh - pushes local changes and pulls remote changes
  /// Used for pull-to-refresh and refresh button
  /// Note: Incoming sync (pull) works for all users, outgoing sync (push) requires Pro
  Future<void> refresh() async {
    await refreshWithOutcome();
  }

  Future<SyncRefreshOutcome> refreshWithOutcome({bool manual = false}) async {
    if (manual && refreshOperationOverride == null) {
      final accountCurrent = AuthService.captureSession();
      final state = await AuthService.cloudRecovery.check();
      if (!accountCurrent()) return SyncRefreshOutcome.deferred;
      if (state == CloudSessionState.unavailable) {
        return SyncRefreshOutcome.unavailable;
      }
      if (state != CloudSessionState.ready) return SyncRefreshOutcome.deferred;
      try {
        await init();
      } on CloudOperationCancelled {
        return SyncRefreshOutcome.deferred;
      }
      if (!accountCurrent()) return SyncRefreshOutcome.deferred;
    }
    if (refreshOperationOverride != null) {
      return _syncOperationSerializer.run(_syncOperationKey, _refreshUnlocked);
    }
    final current = _captureSession();
    return _syncOperationSerializer.run(_syncOperationKey, () async {
      if (!current()) return SyncRefreshOutcome.deferred;
      return runCloudOperation(current, () => _refreshUnlocked(manual: manual));
    });
  }

  Future<SyncRefreshOutcome> _refreshUnlocked({bool manual = false}) async {
    final override = refreshOperationOverride;
    if (override != null) {
      await override();
      return SyncRefreshOutcome.complete;
    }
    if (currentUser == null) return SyncRefreshOutcome.deferred;

    // Don't sync if E2EE is not ready (pending approval, revoked, etc.)
    if (!_canReceiveSync) {
      AppLogger.log("[SYNC] REFRESH: Skipping - $_incomingSyncState");
      return SyncRefreshOutcome.deferred;
    }

    await Future.microtask(() {});
    if (currentUser == null || !_canReceiveSync) {
      return SyncRefreshOutcome.deferred;
    }

    // Retain durable content failures; only transient operation failures are
    // cleared when the user explicitly starts another refresh.
    _clearTransientSyncFailures();

    try {
      await _restoreContentRetryState(currentUser!.uid);
      requireCloudOperation();
      isSyncing.value = true;
      syncStatus.value = const SyncProgress(SyncPhase.syncing);
      final currentLastSynced = AppState.lastSynced;
      AppLogger.log(
        "[SYNC] REFRESH START: Manual refresh triggered (lastSynced: ${currentLastSynced?.toIso8601String() ?? 'null'})",
      );

      // Only start listener if not already running
      // The listener is started on login/init and runs continuously
      if (_remoteListener == null) {
        await _startRemoteListener();
      }

      // Only push local changes if user has Pro subscription
      if (_canPushSync) {
        await _pushLocalChanges();
      } else {
        AppLogger.log("[SYNC] REFRESH: Skipping push - $_pushSyncState");
      }
      // Always pull remote changes (available to all users)
      await recheckReadyDependencies();
      requireCloudOperation();
      await _pullRemoteChanges();

      if (manual) {
        // Older revisions may already be behind the cloud cursor and have
        // exhausted their budget before a local persistence fix was installed.
        final failures = await _contentRetryLedger.listForUser(
          currentUser!.uid,
        );
        requireCloudOperation();
        for (final failure in failures) {
          if (failure.category == RemoteNoteFailureCategory.localApply &&
              failure.errorCode == 'local-note-apply-failed') {
            await retryFailedRemoteNote(failure.remoteDocumentId);
            requireCloudOperation();
          }
        }
      }

      // Only show "Refresh Complete" if there are no failed syncs
      final failedSyncs = _syncCache.getPendingSyncs();
      final hasContentFailures = await _showContentFailureSummary(
        currentUser!.uid,
      );
      requireCloudOperation();
      if (failedSyncs.isEmpty && !hasContentFailures) {
        if (await _hasEncryptionDependencies(currentUser!.uid)) {
          syncStatus.value = SyncProgress.idle;
          return SyncRefreshOutcome.deferred;
        }
        final uploadRestricted =
            !PlanService.instance.isPaid &&
            await NoteSyncTrack.count(pending: true) > 0;
        requireCloudOperation();
        if (uploadRestricted) {
          syncStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
          AppLogger.log(
            '[SYNC] REFRESH: Downloads complete; local uploads require Pro',
          );
          return SyncRefreshOutcome.uploadRestricted;
        }
        syncStatus.value = const SyncProgress(SyncPhase.complete);
        AppLogger.log("[SYNC] REFRESH COMPLETE: All syncs successful");
        return SyncRefreshOutcome.complete;
      } else {
        final activeFailures = failedSyncs.where(
          (s) =>
              s.remoteData['deleted'] != true && s.remoteData['deleted'] != 1,
        );
        AppLogger.log(
          "[SYNC] REFRESH PARTIAL: ${activeFailures.length} active notes pending (${failedSyncs.length - activeFailures.length} deleted), ${contentFailures.value.length} recorded content failures",
        );
      }
      return SyncRefreshOutcome.failed;
    } on CloudOperationCancelled {
      return SyncRefreshOutcome.deferred;
    } on SyncEncryptionUnavailable {
      syncStatus.value = SyncProgress.idle;
      AppLogger.log(
        '[SYNC] REFRESH DEFERRED: Encryption key unavailable; work retained',
      );
      return SyncRefreshOutcome.deferred;
    } on FirestoreDocumentFetchException catch (e, stack) {
      if (!cloudOperationIsCurrent()) return SyncRefreshOutcome.deferred;
      syncStatus.value = isCloudConnectionFailure(e)
          ? SyncProgress.idle
          : const SyncProgress(SyncPhase.failed);
      AppLogger.error('[SYNC] FIRESTORE DOCUMENT FETCH FAILED', e, stack);
      if (isCloudConnectionFailure(e)) {
        AuthService.cloudRecovery.connectionLost();
        return SyncRefreshOutcome.unavailable;
      }
      return SyncRefreshOutcome.failed;
    } catch (e, stack) {
      if (!cloudOperationIsCurrent()) return SyncRefreshOutcome.deferred;
      syncStatus.value = isCloudConnectionFailure(e)
          ? SyncProgress.idle
          : const SyncProgress(SyncPhase.failed);
      AppLogger.error('[SYNC] REFRESH FAILED', e, stack);
      if (isCloudConnectionFailure(e)) {
        AuthService.cloudRecovery.connectionLost();
        return SyncRefreshOutcome.unavailable;
      }
      return SyncRefreshOutcome.failed;
    } finally {
      if (cloudOperationIsCurrent()) {
        isSyncing.value = false;
        syncingOutgoing.value = {};
        Future.delayed(const Duration(seconds: 2), () {
          // Only clear status message if no failed syncs
          if (cloudOperationIsCurrent() &&
              !isSyncing.value &&
              syncFailed.value.isEmpty) {
            syncStatus.value = SyncProgress.idle;
          }
        });
      }
    }
  }

  Future<void> _sync() {
    final current = _captureSession();
    return _syncOperationSerializer.run(_syncOperationKey, () async {
      if (!current()) return;
      await runCloudOperation(current, _syncUnlocked);
    });
  }

  Future<void> _syncUnlocked() async {
    if (currentUser == null) return;

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[SYNC] Skipping sync - $_pushSyncState");
      return;
    }

    // Yield to ensure we don't update state during a build phase
    await Future.microtask(() {});

    // Check again after yielding or waiting behind another sync operation.
    if (currentUser == null || !_canPushSync) return;

    // Check if there are pending local changes before syncing
    final pendingSyncs = await NoteSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[SYNC] No local changes to sync");
      return;
    }

    try {
      isSyncing.value = true;
      syncStatus.value = const SyncProgress(SyncPhase.syncing);
      AppLogger.log(
        "[SYNC] PUSH START: ${pendingSyncs.length} local changes to sync",
      );

      await _pushLocalChangesWithPending(pendingSyncs);
      requireCloudOperation();

      await recheckReadyDependencies();
      requireCloudOperation();

      syncStatus.value = const SyncProgress(SyncPhase.complete);
      AppLogger.log("[SYNC] PUSH COMPLETE: Local changes synced");
    } on SyncEncryptionUnavailable {
      for (final pending in pendingSyncs) {
        _removeSyncingOutgoing(pending.localId);
      }
      syncStatus.value = SyncProgress.idle;
      AppLogger.log(
        '[SYNC] PUSH DEFERRED: Encryption key unavailable; local work retained',
      );
    } catch (e, stack) {
      if (!cloudOperationIsCurrent() || e is CloudOperationCancelled) return;
      if (isCloudConnectionFailure(e)) {
        AuthService.cloudRecovery.connectionLost();
        syncStatus.value = SyncProgress.idle;
        for (final pending in pendingSyncs) {
          _removeSyncingOutgoing(pending.localId);
        }
      } else {
        syncStatus.value = const SyncProgress(SyncPhase.failed);
      }
      AppLogger.error('[SYNC] PUSH FAILED', e, stack);
    } finally {
      if (cloudOperationIsCurrent()) {
        isSyncing.value = false;
        syncingOutgoing.value = {};
        // Clear message after delay
        Future.delayed(const Duration(seconds: 2), () {
          if (cloudOperationIsCurrent() && !isSyncing.value) {
            syncStatus.value = SyncProgress.idle;
          }
        });
      }
    }
  }

  /// Push local changes with already fetched pending syncs
  Future<void> _pushLocalChangesWithPending(
    List<NoteSyncTrack> pendingSyncs,
  ) async {
    if (pendingSyncs.isEmpty) return;
    syncStatus.value = const SyncProgress(SyncPhase.savingChanges);

    AppLogger.log(
      "[SYNC] PUSH: Starting push of ${pendingSyncs.length} local changes",
    );

    WriteBatch batch = _firestore.batch();
    int batchCount = 0;
    int pushedCount = 0;
    int failedCount = 0;
    bool deferredForEncryption = false;
    Uint8List? batchUMK;
    final List<Future<void> Function()> postCommitActions = [];

    for (final sync in pendingSyncs) {
      // Capture sync start time to detect modifications during sync
      final syncStartTime = DateTime.now();
      _addSyncingOutgoing(sync.localId);
      try {
        final umk = _captureRequiredUMK();
        if (sync.action == SyncAction.delete && sync.remoteId == null) {
          requireCloudOperation();
          await sync.deleteIfUnchanged();
          AppLogger.log(
            "[SYNC] PUSH: Note ${sync.localId} - deleted local track (no remote ID)",
          );
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        late final Map<String, dynamic>? remoteData;

        if (sync.remoteId != null) {
          final docSnapshot = await readCloudDocument(
            _notesCollection.doc(sync.remoteId),
            isCurrent: cloudOperationIsCurrent,
          );
          if (docSnapshot.exists) {
            remoteData = docSnapshot.data()!;
          } else {
            remoteData = null;
          }
        } else {
          remoteData = null;
        }

        if (remoteData != null && sync.action != SyncAction.delete) {
          final remoteUpdatedAtStr = remoteData['updated_at'] as String?;
          if (remoteUpdatedAtStr == null) {
            AppLogger.log(
              "[SYNC] PUSH: Note ${sync.localId} - remote has null updated_at, skipping",
            );
            _removeSyncingOutgoing(sync.localId);
            continue;
          }
          final remoteUpdatedAt = DateTime.parse(remoteUpdatedAtStr);

          // Check if there's a pending sync for this note - if so, don't overwrite local changes
          final hasPendingSync =
              sync.status == SyncStatus.pending ||
              sync.status == SyncStatus.failed;

          if (hasPendingSync) {
            // Local has pending changes, push them instead of pulling remote
            AppLogger.log(
              "[SYNC] PUSH: Note ${sync.localId} - pushing local (has pending changes)",
            );
          } else if (sync.updatedAt == null ||
              remoteUpdatedAt.isAfter(sync.updatedAt!)) {
            _addSyncingIncoming(sync.localId);
            try {
              await _applyRemoteContentAutomatically(
                remoteData,
                sync.remoteId!,
              );
              AppLogger.log(
                "[SYNC] PUSH: Note ${sync.localId} - patched from remote (remote newer)",
              );
            } finally {
              _removeSyncingIncoming(sync.localId);
            }
            _removeSyncingOutgoing(sync.localId);
            continue;
          }
        }

        final isRemoteDeleted =
            remoteData?['deleted'] == true || remoteData?['deleted'] == 1;

        // Handle case where remote note was deleted by another device
        // If we have a pending upload but remote is deleted, delete locally instead
        if (isRemoteDeleted && sync.action != SyncAction.delete) {
          AppLogger.log(
            "[SYNC] PUSH: Note ${sync.localId} - remote was deleted, deleting locally",
          );
          await _handleRemoteDeletedNote(sync.localId);

          // Confirm if note is deleted locally then delete the sync
          final localNote = await Note.findById(sync.localId);
          if (localNote == null) {
            requireCloudOperation();
            await sync.deleteIfUnchanged();
          }

          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        if (sync.action == SyncAction.delete) {
          if (sync.remoteId != null && remoteData != null && !isRemoteDeleted) {
            _ensureUMKAvailable(umk);
            batchUMK ??= umk;
            batch.set(_notesCollection.doc(sync.remoteId), {
              'local_id': sync.localId,
              'deleted_at': FieldValue.serverTimestamp(),
              'deleted': true,
              'updated_at': DateTime.now().toIso8601String(),
              cloudSyncCommittedAtField: FieldValue.serverTimestamp(),
            });
            postCommitActions.add(() async {
              await _deleteNoteStorage(sync.localId);
              requireCloudOperation();
              await sync.deleteIfUnchanged();
              _removeSyncingOutgoing(sync.localId);
            });
            batchCount++;
            pushedCount++;
          } else {
            // A tombstone or authoritative absence can follow a successful
            // document commit whose Storage cleanup was interrupted.
            if (sync.remoteId != null) await _deleteNoteStorage(sync.localId);
            requireCloudOperation();
            await sync.deleteIfUnchanged();
            _removeSyncingOutgoing(sync.localId);
          }
          continue;
        }

        final note = await Note.findById(sync.localId);

        if (note == null) {
          // Note was deleted locally but sync track still has upload action.
          // This can happen due to race conditions when notes are trashed and
          // deleted quickly - the delete action may be overwritten by the
          // trash update action due to concurrent notify() calls.
          // If we have a remoteId, we should sync the deletion to remote.
          if (sync.remoteId != null && !isRemoteDeleted) {
            final localId = sync.localId;
            _ensureUMKAvailable(umk);
            batchUMK ??= umk;
            batch.set(_notesCollection.doc(sync.remoteId), {
              'local_id': sync.localId,
              'deleted_at': FieldValue.serverTimestamp(),
              'deleted': true,
              'updated_at': DateTime.now().toIso8601String(),
              cloudSyncCommittedAtField: FieldValue.serverTimestamp(),
            });
            postCommitActions.add(() async {
              requireCloudOperation();
              await _deleteNoteStorage(sync.localId);
              requireCloudOperation();
              await sync.deleteIfUnchanged();
              AppLogger.log(
                "[SYNC] PUSH: Note ${sync.remoteId} deleted from remote (local note missing)",
              );
              _removeSyncingOutgoing(localId);
            });
            batchCount++;
            pushedCount++;
          } else {
            if (sync.remoteId != null) await _deleteNoteStorage(sync.localId);
            requireCloudOperation();
            await sync.deleteIfUnchanged();
            _removeSyncingOutgoing(sync.localId);
          }
          continue;
        }

        var noteData = note.toJson();
        ReminderSyncCodec.encode(note.reminder, noteData);

        // Ensure locally encrypted content is properly decrypted before sync
        // This handles edge cases where content might still be encrypted
        final content = noteData['content'] as String?;
        if (content != null && LocalDataEncryption.isEncrypted(content)) {
          AppLogger.log(
            "[SYNC] PUSH: Note ${sync.localId} - decrypting locally encrypted content",
          );
          final localEncryption = LocalDataEncryption.instance;
          noteData['content'] = await localEncryption.decryptString(content);
        }

        noteData['local_id'] = note.id;
        AppLogger.log(
          "Uploading attachments for note ${sync.localId} (has ${note.attachments.length} attachments)",
        );
        final attachmentsData = await _uploadAttachments(
          note.attachments,
          note,
          umk,
        );

        // If attachment upload failed, skip this note and mark as failed
        if (attachmentsData == null) {
          AppLogger.log(
            "[SYNC] PUSH: Note ${sync.localId} failed - attachment upload failed",
          );
          _markSyncFailed(sync.localId);
          _removeSyncingOutgoing(sync.localId);
          failedCount++;
          continue;
        }

        noteData['attachments'] = attachmentsData;
        noteData.remove('id');
        noteData.remove('remote_id');

        // Apply E2EE encryption if enabled
        noteData = await _encryptNoteData(noteData, umk);
        noteData[cloudSyncCommittedAtField] = FieldValue.serverTimestamp();
        _ensureUMKAvailable(umk);
        batchUMK ??= umk;

        final localId = sync.localId;
        final capturedSyncStartTime = syncStartTime;
        if (sync.remoteId != null) {
          // When note is encrypted, explicitly delete plaintext fields from
          // Firestore. SetOptions(merge: true) only adds/updates fields — it
          // won't remove fields absent from the payload. Without this, a note
          // that was previously stored unencrypted retains its old plaintext
          // alongside the new ciphertext.
          // Only applies to updates — new documents never have old plaintext.
          if (noteData.containsKey('e2ee_ciphertext')) {
            noteData['title'] = FieldValue.delete();
            noteData['content'] = FieldValue.delete();
            noteData['plain_text'] = FieldValue.delete();
          }
          batch.set(
            _notesCollection.doc(sync.remoteId),
            noteData,
            SetOptions(merge: true),
          );
          postCommitActions.add(() async {
            requireCloudOperation();
            final wasUnchanged = await sync.markSyncedIfUnchanged(
              capturedSyncStartTime,
            );
            if (wasUnchanged) {
              AppLogger.log("[SYNC] PUSH: Note $localId updated on remote");
            } else {
              AppLogger.log(
                "[SYNC] PUSH: Note $localId modified during sync, will re-sync",
              );
              // Trigger a new sync to push the changes made during this sync
              NoteSyncService().sync();
            }
            _removeSyncingOutgoing(localId);
          });
        } else {
          // For new documents, remove plaintext fields instead of using
          // FieldValue.delete() which is invalid without SetOptions(merge: true).
          if (noteData.containsKey('e2ee_ciphertext')) {
            noteData.remove('title');
            noteData.remove('content');
            noteData.remove('plain_text');
          }
          final stableId = note.syncId ?? const Uuid().v4();
          if (note.syncId != stableId) {
            note.syncId = stableId;
            requireCloudOperation();
            await AppState.db.update(
              Note.model,
              {'sync_id': stableId},
              where: 'id = ?',
              whereArgs: [note.id],
            );
          }
          final newDocRef = _notesCollection.doc(stableId);
          batch.set(newDocRef, noteData);
          // Save remoteId immediately to prevent duplicates if another sync runs
          // before the batch commits and markSynced is called
          requireCloudOperation();
          await sync.claimRemoteId(newDocRef.id);
          postCommitActions.add(() async {
            requireCloudOperation();
            final wasUnchanged = await sync.markSyncedIfUnchanged(
              capturedSyncStartTime,
            );
            if (wasUnchanged) {
              AppLogger.log(
                "[SYNC] PUSH: Note $localId created on remote (${newDocRef.id})",
              );
            } else {
              AppLogger.log(
                "[SYNC] PUSH: Note $localId modified during sync, will re-sync",
              );
              // Trigger a new sync to push the changes made during this sync
              NoteSyncService().sync();
            }
            _removeSyncingOutgoing(localId);
          });
        }

        batchCount++;
        pushedCount++;

        if (batchCount >= 400) {
          AppLogger.log("[SYNC] PUSH: Committing batch of 400 notes");
          _ensureUMKAvailable(batchUMK);
          requireCloudOperation();
          await batch.commit().timeout(const Duration(seconds: 10));
          requireCloudOperation();
          for (final action in postCommitActions) {
            try {
              await action();
            } catch (e) {
              AppLogger.error('[SYNC] PUSH: Post-commit action failed', e);
              rethrow;
            }
          }
          postCommitActions.clear();
          batch = _firestore.batch();
          batchCount = 0;
          batchUMK = null;
        }
      } on SyncEncryptionUnavailable {
        deferredForEncryption = true;
        AppLogger.log(
          '[SYNC] PUSH: Note ${sync.localId} deferred until encryption key is available',
        );
        _removeSyncingOutgoing(sync.localId);
      } catch (e) {
        if (e is CloudOperationCancelled || isCloudConnectionFailure(e)) {
          rethrow;
        }
        AppLogger.error('[SYNC] PUSH: Note ${sync.localId} error', e);
        _markSyncFailed(sync.localId);
        _removeSyncingOutgoing(sync.localId);
        failedCount++;
      }
    }

    if (batchCount > 0) {
      _ensureUMKAvailable(batchUMK!);
      requireCloudOperation();
      await batch.commit().timeout(const Duration(seconds: 10));
      requireCloudOperation();
      for (final action in postCommitActions) {
        try {
          await action();
        } catch (e) {
          AppLogger.error('[SYNC] PUSH: Post-commit action failed', e);
          rethrow;
        }
      }
    }

    if (failedCount > 0) {
      throw StateError('Some outgoing notes could not be synced');
    }
    if (deferredForEncryption) {
      throw const SyncEncryptionUnavailable();
    }

    AppLogger.log(
      "[SYNC] PUSH COMPLETE: $pushedCount pushed, $failedCount failed",
    );
  }

  Uint8List _captureRequiredUMK() {
    final e2ee = E2EEService.instance;
    return requireSyncEncryptionKey(
      cryptoReady: e2ee.isCryptoReady,
      umk: e2ee.deviceManager.getUMK(),
    );
  }

  void _ensureUMKAvailable(Uint8List captured) {
    requireCloudOperation();
    final e2ee = E2EEService.instance;
    final current = e2ee.deviceManager.getUMK();
    validateCapturedSyncEncryptionKey(
      cryptoReady: e2ee.isCryptoReady,
      captured: captured,
      current: current,
    );
  }

  Future<void> _deleteNoteStorage(int noteId) async {
    try {
      final ref = getNoteDocsRef(noteId);
      final listResult = await ref.listAll().timeout(
        const Duration(seconds: 10),
      );
      requireCloudOperation();
      await Future.wait(
        listResult.items.map((item) async {
          requireCloudOperation();
          try {
            await item.delete().timeout(const Duration(seconds: 10));
          } on FirebaseException catch (error) {
            if (error.code != 'object-not-found') rethrow;
          }
        }),
      );
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return;
      AppLogger.error('[SYNC] Error deleting storage for note $noteId', e);
      rethrow;
    } catch (e) {
      AppLogger.error('[SYNC] Error deleting storage for note $noteId', e);
      rethrow;
    }
  }

  Future<void> _pushLocalChanges() async {
    final pendingSyncs = await NoteSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) return;
    await _pushLocalChangesWithPending(pendingSyncs);
  }

  /// Pull remote changes with pagination and caching
  /// Fetches notes in pages, caches them, and processes from cache
  Future<void> _pullRemoteChanges() async {
    await runRemotePullWithListenerLifecycle<void>(
      stopListener: () => _stopRemoteListener(cancelRetry: false),
      restoreListener: _startRemoteListener,
      recoveryDisposition: () {
        final checkpoint = AppState.noteCloudSyncCheckpoint;
        if (checkpoint != null && !checkpoint.requiresBootstrap) {
          return RemotePullRecoveryDisposition.none;
        }
        if (_syncCache.hasPendingSyncs &&
            _syncCache.metadata?.allPagesFetched == true) {
          return RemotePullRecoveryDisposition.resumeCached;
        }
        return RemotePullRecoveryDisposition.restartFull;
      },
      scheduleCachedResume: () {
        if (_canReceiveSync) {
          _pullRetry.schedule(
            _background(() async {
              if (_initialized && currentUser != null && _canReceiveSync) {
                AppLogger.log(
                  '[SYNC] Retrying remaining cached note revisions',
                );
                await _resumePendingSyncs();
              }
            }),
          );
        }
      },
      scheduleFullPull: () {
        if (_canReceiveSync) {
          _pullRetry.schedule(
            _background(() async {
              if (_initialized && currentUser != null && _canReceiveSync) {
                AppLogger.log(
                  '[SYNC] Retrying full note pull after Firestore failure',
                );
                await refresh();
              }
            }),
          );
        }
      },
      pull: _performRemotePull,
    );
  }

  Future<void> _performRemotePull() async {
    syncStatus.value = const SyncProgress(SyncPhase.fetchingUpdates);
    final checkpointCommit = StagedCheckpoint<CloudSyncCheckpoint>(
      commit: (value) => AppState.noteCloudSyncCheckpoint = value,
    );

    final checkpoint = AppState.noteCloudSyncCheckpoint;
    final isBootstrap = checkpoint == null || checkpoint.requiresBootstrap;
    final safeCursor = isBootstrap
        ? await _captureBootstrapBoundary()
        : checkpoint.cursor;

    AppLogger.log(
      "[SYNC] PULL START: ${isBootstrap ? 'full reconciliation' : 'incremental cloud commit scan'}",
    );

    // The bootstrap cursor is the high-water mark captured before the full
    // scan. Concurrent writes after it are intentionally left for the next
    // incremental query/listener.
    requireCloudOperation();
    await _syncCache.startNewSync(safeCursor);
    await _fetchAndCacheRemoteNotes(
      checkpoint: checkpoint,
      isBootstrap: isBootstrap,
    );

    // Process all cached syncs
    await _processCachedSyncs();

    if (_syncCache.metadata?.syncComplete == true) {
      final committedCursor = _syncCache.lastCursor;
      checkpointCommit.stage(
        CloudSyncCheckpoint(bootstrapped: true, cursor: committedCursor),
      );
      AppLogger.log(
        "[SYNC] PULL COMPLETE: All remote changes synced successfully",
      );
      requireCloudOperation();
      await _syncCache.clear();
      requireCloudOperation();
      checkpointCommit.commit();
      AppLogger.log("[SYNC] Cache cleared after successful sync");
    } else {
      final failedSyncs = _syncCache.getPendingSyncs();
      final activeFailures = failedSyncs.where(
        (s) => s.remoteData['deleted'] != true && s.remoteData['deleted'] != 1,
      );
      final deletedFailures = failedSyncs.length - activeFailures.length;
      AppLogger.log(
        "[SYNC] PULL PARTIAL: ${activeFailures.length} active + $deletedFailures deleted notes pending, cache retained",
      );
    }
  }

  Future<CloudSyncCursor?> _captureBootstrapBoundary() async {
    final snapshot = await _getServerDocuments(
      () => _cloudRepository.captureBootstrapBoundary(
        currentUser!.uid,
        onRetry: _logFirestoreQueryRetry('capturing the bootstrap boundary'),
      ),
      operation: 'capturing the bootstrap boundary',
    );
    if (snapshot.docs.isEmpty) return null;

    final document = snapshot.docs.single;
    final cursor = CloudSyncCursor.fromDocument(document.data(), document.id);
    if (cursor == null) {
      throw StateError(
        'Invalid $cloudSyncCommittedAtField on note ${document.id}',
      );
    }
    return cursor;
  }

  FirestoreQueryRetryLogger _logFirestoreQueryRetry(String operation) {
    return (error, nextAttempt, delay) {
      AppLogger.log(
        '[SYNC] Firestore $operation failed transiently; '
        'retrying attempt $nextAttempt in ${delay.inMilliseconds}ms: '
        '$error',
      );
    };
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _getServerDocuments(
    Future<QuerySnapshot<Map<String, dynamic>>> Function() getDocuments, {
    required String operation,
  }) async {
    try {
      final snapshot = await getDocuments();
      requireCloudOperation();
      if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
        throw const CloudVerificationUnavailable();
      }
      _pullRetry.succeeded();
      return snapshot;
    } catch (error) {
      throw FirestoreDocumentFetchException(
        resource: 'note documents',
        operation: operation,
        cause: error,
      );
    }
  }

  /// Fetches either the one-time legacy reconciliation or exact committed
  /// changes after the durable cursor, then persists them before application.
  Future<void> _fetchAndCacheRemoteNotes({
    required CloudSyncCheckpoint? checkpoint,
    required bool isBootstrap,
  }) async {
    syncStatus.value = const SyncProgress(SyncPhase.fetchingUpdates);

    DocumentSnapshot<Map<String, dynamic>>? lastDocument;
    int pageIndex = 0;
    bool hasMore = true;
    int totalDocsFetched = 0;
    final Set<String> uniqueRemoteIds = {};

    AppLogger.log(
      "[SYNC] FETCH START: ${isBootstrap ? 'all legacy and current notes' : 'commits after durable cursor'}",
    );

    while (hasMore) {
      final querySnapshot = await _getServerDocuments(
        () => _cloudRepository.fetchPage(
          uid: currentUser!.uid,
          checkpoint: checkpoint,
          isBootstrap: isBootstrap,
          pageSize: RemoteSyncCacheService.pageSize,
          lastDocument: lastDocument,
          onRetry: _logFirestoreQueryRetry(
            'fetching note page ${pageIndex + 1}',
          ),
        ),
        operation: 'fetching note page ${pageIndex + 1}',
      );

      if (querySnapshot.docs.isEmpty) {
        hasMore = false;
        AppLogger.log("[SYNC] FETCH: No more documents to fetch");
        break;
      }

      final syncs = <String, PendingRemoteSync>{};
      CloudSyncCursor? maxCursor;

      for (final doc in querySnapshot.docs) {
        final remoteData = doc.data();
        final remoteLocalId = remoteData['local_id'];
        final suggestedLocalId = remoteLocalId is int && remoteLocalId > 0
            ? remoteLocalId
            : null;
        if (suggestedLocalId == null) {
          AppLogger.error(
            '[SYNC] Quarantined malformed remote note ${doc.id}',
            StateError('local_id must be a positive integer'),
          );
        }
        final localId = await _resolveIncomingLocalId(doc.id, suggestedLocalId);
        final updatedAtValue = remoteData['updated_at'];
        final updatedAtStr = updatedAtValue is String ? updatedAtValue : null;

        AppLogger.log(
          "[SYNC] FETCH: Note $localId (doc: ${doc.id}) updated_at: $updatedAtStr",
        );

        uniqueRemoteIds.add(doc.id);
        if (!isBootstrap) {
          final documentCursor = CloudSyncCursor.fromDocument(
            remoteData,
            doc.id,
          );
          if (documentCursor == null) {
            throw StateError(
              'Invalid $cloudSyncCommittedAtField on note ${doc.id}',
            );
          }
          maxCursor = maxCursor == null
              ? documentCursor
              : maxCursor.max(documentCursor);
        }

        syncs[doc.id] = PendingRemoteSync(
          localId: localId,
          remoteDocId: doc.id,
          remoteData: remoteData,
          fetchedAt: DateTime.now(),
        );
      }

      totalDocsFetched += querySnapshot.docs.length;

      // Determine if there are more pages
      hasMore = querySnapshot.docs.length >= RemoteSyncCacheService.pageSize;

      final page = PendingRemoteSyncPage(
        pageIndex: pageIndex,
        syncs: syncs,
        lastDocumentId: querySnapshot.docs.isNotEmpty
            ? querySnapshot.docs.last.id
            : null,
        hasMore: hasMore,
      );
      await _syncCache.addPage(page, maxCursor: maxCursor);

      // Update cursor for next page
      if (querySnapshot.docs.isNotEmpty) {
        lastDocument = querySnapshot.docs.last;
      }

      pageIndex++;

      AppLogger.log(
        "[SYNC] FETCH: Page $pageIndex - ${querySnapshot.docs.length} docs fetched (${syncs.length} unique in page), hasMore: $hasMore",
      );
    }

    await _syncCache.markAllPagesFetched();

    // Log fetch complete with deduplication info
    final dupCount = totalDocsFetched - uniqueRemoteIds.length;
    if (dupCount > 0) {
      AppLogger.log(
        "[SYNC] FETCH COMPLETE: $totalDocsFetched docs in ${_syncCache.metadata?.totalPages ?? 0} pages -> ${uniqueRemoteIds.length} unique notes ($dupCount duplicates)",
      );
    } else {
      AppLogger.log(
        "[SYNC] FETCH COMPLETE: ${uniqueRemoteIds.length} unique notes in ${_syncCache.metadata?.totalPages ?? 0} pages",
      );
    }
  }

  /// Process all cached pending syncs
  Future<void> _processCachedSyncs() async {
    final pendingSyncs = _syncCache.getPendingSyncs();
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[SYNC] PROCESS: No pending syncs to process");
      syncProgress.value = (0, 0);
      return;
    }

    final totalCount = pendingSyncs.length;
    int syncedCount = 0;
    int skippedCount = 0;
    int failedCount = 0;
    int deletedCount = 0; // Track deleted notes separately

    // Count deleted vs active notes for better logging
    final deletedNotes = pendingSyncs.where(
      (s) => s.remoteData['deleted'] == true || s.remoteData['deleted'] == 1,
    );
    final activeNotes = pendingSyncs.length - deletedNotes.length;

    syncProgress.value = (syncedCount, totalCount);
    syncStatus.value = const SyncProgress(SyncPhase.syncing);
    AppLogger.log(
      "[SYNC] PROCESS START: $totalCount cached syncs ($activeNotes active, ${deletedNotes.length} deleted)",
    );

    // Track processed note IDs to avoid duplicates
    final Set<String> processedIds = {};

    for (final pendingSync in pendingSyncs) {
      final remoteSuggestedId = pendingSync.localId;
      final remoteData = pendingSync.remoteData;
      final remoteDocId = pendingSync.remoteDocId;
      final processedRevision = remoteDocumentRevision(remoteData, remoteDocId);
      final localId = await _resolveIncomingLocalId(
        remoteDocId,
        remoteSuggestedId,
      );
      final remoteTrack = await NoteSyncTrack.getByRemoteId(remoteDocId);

      // Skip if already processed in this sync cycle
      if (processedIds.contains(remoteDocId)) {
        continue;
      }
      processedIds.add(remoteDocId);

      // Check if this is a deleted note FIRST
      final isDeleted =
          remoteData['deleted'] == true || remoteData['deleted'] == 1;
      final payloadLocalId = remoteData['local_id'];
      final hasValidCorePayload =
          payloadLocalId is int &&
          payloadLocalId > 0 &&
          (isDeleted ||
              (_hasValidRemoteDate(remoteData['updated_at']) &&
                  _hasValidRemoteDate(remoteData['created_at'])));

      if (!hasValidCorePayload) {
        _addSyncingIncoming(localId);
        try {
          requireCloudOperation();
          await _syncCache.updateSync(
            remoteDocId,
            pendingSync.copyWith(status: PendingRemoteSyncStatus.inProgress),
          );
          final handled = await _applyRemoteContentAutomatically(
            remoteData,
            remoteDocId,
            fallbackLocalId: localId,
          );
          if (handled.checkpointSafe) {
            if (!await _completeCachedRevision(
              remoteDocId,
              handled.revision,
              localId,
            )) {
              return;
            }
            syncedCount++;
            syncProgress.value = (syncedCount, totalCount);
          }
        } catch (error) {
          if (error is CloudOperationCancelled ||
              isCloudConnectionFailure(error)) {
            rethrow;
          }
          requireCloudOperation();
          await _syncCache.markFailed(remoteDocId, error.toString());
          failedCount++;
          AppLogger.error(
            '[SYNC] PROCESS: Malformed note $localId could not be delegated',
            error,
          );
        } finally {
          _removeSyncingIncoming(localId);
        }
        continue;
      }

      if (isDeleted) {
        // Handle deletion
        _addSyncingIncoming(localId);
        try {
          await _handleRemoteDeletedNote(localId, remoteDocId: remoteDocId);
          if (!await _completeCachedRevision(
            remoteDocId,
            processedRevision,
            localId,
          )) {
            return;
          }
          syncedCount++;
          deletedCount++; // Track deleted notes separately
          syncProgress.value = (syncedCount, totalCount);
        } finally {
          _removeSyncingIncoming(localId);
        }
        continue;
      }

      // Check if there's a pending sync for this note - don't overwrite local changes
      final localPendingSync =
          remoteTrack ?? await NoteSyncTrack.getByLocalId(localId);

      if (localPendingSync != null &&
          (localPendingSync.status == SyncStatus.pending ||
              localPendingSync.status == SyncStatus.failed)) {
        AppLogger.log(
          "[SYNC] PROCESS: Note $localId skipped - has pending local changes",
        );
        if (!await _completeCachedRevision(
          remoteDocId,
          processedRevision,
          localId,
        )) {
          return;
        }
        syncedCount++;
        skippedCount++;
        syncProgress.value = (syncedCount, totalCount);
        continue;
      }

      final localNote =
          await Note.findById(localId) ?? await Note.findBySyncId(remoteDocId);

      if (localNote != null && remoteData['updated_at'] != null) {
        final localUpdatedAt = localNote.updatedAt;
        final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

        // Always re-process notes stuck with decryption_failed content —
        // these were saved by a previous bug where failed decryption
        // permanently overwrote the local content with an error marker.
        final hasDecryptionError =
            localNote.content == Note.decryptionFailedContent;

        final equalTimestampBackgroundRepair =
            !hasDecryptionError &&
            localUpdatedAt != null &&
            remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt) &&
            await _needsEqualTimestampBackgroundRepair(localNote, remoteData);

        if (!hasDecryptionError &&
            localUpdatedAt != null &&
            (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                (remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt) &&
                    !equalTimestampBackgroundRepair))) {
          // Local is newer, skip
          if (!await _completeCachedRevision(
            remoteDocId,
            processedRevision,
            localId,
          )) {
            return;
          }
          syncedCount++;
          skippedCount++;
          syncProgress.value = (syncedCount, totalCount);
          continue;
        }
      }

      _addSyncingIncoming(localId);
      try {
        requireCloudOperation();
        await _syncCache.updateSync(
          remoteDocId,
          pendingSync.copyWith(status: PendingRemoteSyncStatus.inProgress),
        );

        final handled = await _applyRemoteContentAutomatically(
          remoteData,
          remoteDocId,
          fallbackLocalId: localId,
        );

        if (handled.checkpointSafe) {
          if (!await _completeCachedRevision(
            remoteDocId,
            handled.revision,
            localId,
          )) {
            return;
          }
          syncedCount++;
          syncProgress.value = (syncedCount, totalCount);
          AppLogger.log(
            "[SYNC] PROCESS: Note $localId applied or durably queued",
          );
        }
      } catch (e) {
        if (e is CloudOperationCancelled || isCloudConnectionFailure(e)) {
          rethrow;
        }
        requireCloudOperation();
        await _syncCache.markFailed(remoteDocId, e.toString());
        _markSyncFailed(localId);
        failedCount++;
        AppLogger.error('[SYNC] PROCESS: Note $localId error', e);
      } finally {
        _removeSyncingIncoming(localId);
      }
    }

    // Report final status
    final failedSyncs = _syncCache.getPendingSyncs();
    if (failedSyncs.isNotEmpty) {
      // Only show failure message if there are actual non-deleted failed notes
      final activeFailures = failedSyncs.where(
        (s) => s.remoteData['deleted'] != true && s.remoteData['deleted'] != 1,
      );
      if (activeFailures.isNotEmpty) {
        syncStatus.value = SyncProgress(
          SyncPhase.failed,
          failedCount: activeFailures.length,
        );
      }
    }

    // Calculate active synced (excluding deleted notes)
    final activeSynced = syncedCount - deletedCount;
    AppLogger.log(
      "[SYNC] PROCESS COMPLETE: $activeSynced active synced, $deletedCount deleted processed, $skippedCount skipped, $failedCount failed",
    );

    // Reset progress when done
    syncProgress.value = (0, 0);
  }

  Future<bool> _completeCachedRevision(
    String remoteDocumentId,
    String processedRevision,
    int localId,
  ) async {
    final removed = await _syncCache.completeIfCurrentRevision(
      remoteDocumentId,
      processedRevision,
    );
    if (removed) {
      _clearSyncFailed(localId);
      return true;
    }
    AppLogger.log(
      '[SYNC] PROCESS: A newer revision of $remoteDocumentId arrived while '
      'the cached revision was applying; processing the replacement now',
    );
    await _processCachedSyncs();
    return false;
  }

  /// Handle a note that was deleted on remote
  Future<void> _handleRemoteDeletedNote(
    int localId, {
    String? remoteDocId,
  }) async {
    final remoteTrack = remoteDocId == null
        ? null
        : await NoteSyncTrack.getByRemoteId(remoteDocId);
    final stableNote = remoteDocId == null
        ? null
        : await Note.findBySyncId(remoteDocId);
    final resolvedLocalId = remoteTrack?.localId ?? stableNote?.id ?? localId;
    final note = remoteDocId == null
        ? await Note.findById(resolvedLocalId)
        : stableNote ??
              (remoteTrack == null
                  ? null
                  : await Note.findById(remoteTrack.localId));
    if (note == null) {
      // Note doesn't exist locally, nothing to do
      return;
    }

    // Delete local files tracked for this note
    final trackedFiles = await FileSyncTrack.get(noteId: note.id!);
    final fs = await fileSystem();
    for (final trackedFile in trackedFiles) {
      try {
        if (await fs.exists(trackedFile.localPath)) {
          await fs.delete(trackedFile.localPath);
        }
        await trackedFile.delete();
      } catch (e) {
        AppLogger.error('Error deleting tracked file', e);
      }
    }

    // Delete the note sync track
    final syncTrack =
        remoteTrack ?? await NoteSyncTrack.getByLocalId(resolvedLocalId);
    if (syncTrack != null) {
      await syncTrack.delete();
    }

    requireCloudOperation();
    await note.delete(trackSync: false, origin: ModelChangeOrigin.remoteSync);
    AppLogger.log("Deleted local note from remote deletion: $resolvedLocalId");
  }

  Future<int> _resolveIncomingLocalId(
    String remoteDocId,
    int? suggestedLocalId, {
    RemoteContentRetryEntry? reservation,
  }) async {
    final tracked = await NoteSyncTrack.getByRemoteId(remoteDocId);
    final stableNote = await Note.findBySyncId(remoteDocId);

    Future<bool> isAvailable(int candidate) async {
      if (candidate <= 0) return false;
      if (await Note.findById(candidate) != null) return false;
      if (await NoteSyncTrack.getByLocalId(candidate) != null) return false;
      final user = currentUser;
      if (user == null) return true;
      final ledgerReservation = await _contentRetryLedger.getByLocalId(
        user.uid,
        candidate,
      );
      return ledgerReservation == null ||
          ledgerReservation.remoteDocumentId == remoteDocId;
    }

    return resolveRemoteLocalId(
      trackedLocalId: tracked?.localId,
      stableNoteLocalId: stableNote?.id,
      reservedLocalId: reservation?.localId,
      suggestedLocalId: suggestedLocalId,
      isAvailable: isAvailable,
      allocateCandidate: () => DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Patch a local note with remote data
  Future<RemoteNoteApplyResult> _patchRemoteNote(
    Map<String, dynamic> remoteData,
    String remoteDocId,
    int resolvedLocalId,
  ) async {
    final downloads = await _newDownloadBatch();
    try {
      return await _prepareRemoteNote(
        remoteData,
        remoteDocId,
        resolvedLocalId,
        downloads,
      );
    } finally {
      await downloads.finish();
    }
  }

  Future<RemoteNoteApplyResult> _prepareRemoteNote(
    Map<String, dynamic> remoteData,
    String remoteDocId,
    int resolvedLocalId,
    DownloadedAttachmentBatch downloads,
  ) async {
    final localId = resolvedLocalId;

    // Note: deleted notes should be handled by _handleRemoteDeletedNote
    // This method is only for patching non-deleted notes
    final isDeleted =
        remoteData['deleted'] == true || remoteData['deleted'] == 1;
    if (isDeleted) {
      await _handleRemoteDeletedNote(localId, remoteDocId: remoteDocId);
      return const RemoteNoteApplyResult.success();
    }

    // Check if note is encrypted but E2EE isn't ready
    // Don't save encrypted notes with null content - wait for E2EE to be ready
    final isEncrypted = remoteData.containsKey('e2ee_ciphertext');
    final e2ee = E2EEService.instance;
    if (isEncrypted && !e2ee.isCryptoReady) {
      AppLogger.log(
        "[SYNC] PROCESS: Note $localId FAILED - encrypted but E2EE not ready (status: ${e2ee.status.value})",
      );
      return const RemoteNoteApplyResult.deferred(
        RemoteNoteFailureCategory.decryption,
        'e2ee-not-ready',
      );
    }

    // Decrypt E2EE data if encrypted
    final reminderChanged =
        remoteData.containsKey('reminder') ||
        remoteData.containsKey('reminder_v2') ||
        remoteData.containsKey(ReminderSyncCodec.stateField);
    final updatedNoteData = await _decryptNoteData(remoteData);
    ReminderSyncCodec.decode(updatedNoteData);

    final tracked = await NoteSyncTrack.getByRemoteId(remoteDocId);
    final stableNote = await Note.findBySyncId(remoteDocId);
    final noteId = tracked?.localId ?? stableNote?.id ?? resolvedLocalId;
    final rows = await downloads.database.query(
      Note.model,
      where: 'id = ?',
      whereArgs: [noteId],
    );
    final expectedRow = rows.isEmpty ? null : rows.single;
    final tracks = await downloads.database.query(
      NoteSyncTrack.model,
      where: 'local_id = ?',
      whereArgs: [noteId],
    );
    final expectedSyncRow = tracks.isEmpty ? null : tracks.single;
    final note = expectedRow == null
        ? Note(id: noteId, syncId: remoteDocId)
        : await Note.fromJsonAsync(expectedRow);
    updatedNoteData['sync_id'] = remoteDocId;

    if (isEncrypted && updatedNoteData.containsKey('e2ee_ciphertext')) {
      // Decryption failed — E2EE reported ready but the actual decrypt returned
      // null (e.g., UMK was lost from secure storage, or ciphertext is corrupt).
      // Return false to keep the note in the sync cache for retry instead of
      // permanently saving error content that would block future re-sync
      // (because updatedAt would match the remote, causing the note to be skipped).
      AppLogger.log(
        "[SYNC] PROCESS: Note $localId - decryption failed, deferring for retry",
      );
      return const RemoteNoteApplyResult.retryable(
        RemoteNoteFailureCategory.decryption,
        'note-decryption-failed',
      );
    } else {
      final attachmentData = parseRemoteNoteAttachments(
        updatedNoteData['attachments'],
      );
      for (final attachment in attachmentData) {
        discardRemoteAttachmentPresentation(attachment);
      }
      _validateAttachmentLocators(attachmentData);
      final incomingNoteLocked = _isLockedValue(updatedNoteData['locked']);
      AppLogger.log(
        "Attachments found in remote data for note $localId: ${attachmentData.length}",
      );
      final attachmentDownload = await _downloadAttachments(
        attachmentData,
        note,
        downloads,
        incomingNoteLocked: incomingNoteLocked,
      );
      if (!attachmentDownload.isSuccess) {
        // Attachment download failed - log and skip this note
        AppLogger.log(
          "[SYNC] PROCESS: Note ${note.id} FAILED - attachment download failed (${attachmentData.length} attachments)",
        );
        return attachmentDownload.failure!;
      }

      updatedNoteData['attachments'] = attachmentDownload.attachments!;
    }
    final committed = await note.applyRemoteIfUnchanged(
      database: downloads.database,
      expectedRow: expectedRow,
      expectedSyncRow: expectedSyncRow,
      incoming: updatedNoteData,
      commitAttachments: downloads.commitMappings,
    );
    downloads.committed = committed == RemoteNoteCommitResult.applied;
    if (committed == RemoteNoteCommitResult.staleSession) {
      throw const CloudOperationCancelled();
    }
    if (committed == RemoteNoteCommitResult.localChanged) {
      return const RemoteNoteApplyResult.deferred(
        RemoteNoteFailureCategory.localApply,
        'local-note-changed',
      );
    }
    if (downloads.committed && cloudOperationIsCurrent()) {
      note.notifyWithOrigin(
        expectedRow == null ? 'created' : 'updated',
        ModelChangeOrigin.remoteSync,
      );
    }
    if (downloads.committed && reminderChanged && cloudOperationIsCurrent()) {
      ReminderCoordinator.instance.requestReconciliation();
    }

    return const RemoteNoteApplyResult.success();
  }

  /// Repairs rows written by the old missing-background fallback without
  /// turning equal timestamps into a general remote-wins rule.
  Future<bool> _needsEqualTimestampBackgroundRepair(
    Note localNote,
    Map<String, dynamic> remoteData,
  ) async {
    Map<String, dynamic> decoded;
    try {
      decoded = await _decryptNoteData(remoteData);
    } catch (_) {
      return false;
    }
    if (decoded.containsKey('e2ee_ciphertext')) return false;

    Object? rawAttachments = decoded['attachments'];
    if (rawAttachments is String) {
      try {
        rawAttachments = jsonDecode(rawAttachments);
      } catch (_) {
        return false;
      }
    }
    if (rawAttachments is! List) return false;

    for (var index = 0; index < rawAttachments.length; index++) {
      if (index >= localNote.attachments.length) break;
      final raw = rawAttachments[index];
      if (raw is! Map) continue;
      final remoteAttachment = NoteAttachment.fromJson(
        Map<String, dynamic>.from(raw),
      );
      final localAttachment = localNote.attachments[index];
      if (remoteAttachment.type != AttachmentType.sketch ||
          localAttachment.type != AttachmentType.sketch) {
        continue;
      }

      final remoteSketch = remoteAttachment.sketch!;
      final localSketch = localAttachment.sketch!;
      final remoteBackground = remoteSketch.backgroundImage;
      if (remoteBackground == null ||
          remoteBackground.isEmpty ||
          !_isRemoteStorageLocator(remoteBackground)) {
        continue;
      }

      final remoteStrokes = remoteSketch.strokesFilePath;
      final localStrokes = localSketch.strokesFilePath;
      if (remoteStrokes == null ||
          !_isRemoteStorageLocator(remoteStrokes) ||
          localStrokes == null ||
          localStrokes.isEmpty ||
          (remoteSketch.strokesContentHash != null &&
              localSketch.strokesContentHash != null &&
              remoteSketch.strokesContentHash !=
                  localSketch.strokesContentHash)) {
        continue;
      }
      final strokesTrack = await FileSyncTrack.getByLocalPath(localStrokes);
      if (strokesTrack?.remotePath != remoteStrokes) continue;

      final localBackground = localSketch.backgroundImage;
      if (localBackground == null || localBackground.isEmpty) return true;
      final fs = await fileSystem();
      if (await fs.exists(localBackground)) continue;
      final backgroundTrack = await FileSyncTrack.getByLocalPath(
        localBackground,
      );
      if (backgroundTrack?.remotePath == remoteBackground) return true;
    }
    return false;
  }

  /// Deletes orphaned attachment files (local only).
  /// Remote files are NOT deleted here to prevent race conditions between devices.
  /// Remote file cleanup happens only when the entire note is deleted.
  Future<void> _deleteOrphanedAttachments(Note note) async {
    final fs = await fileSystem();
    final trackedFiles = await FileSyncTrack.get(noteId: note.id!);
    for (final trackedFile in trackedFiles) {
      final isOrphaned = !note.attachments.any((att) {
        final files = switch (att.type) {
          AttachmentType.image => [att.image!.src],
          AttachmentType.sketch => [
            att.sketch!.strokesFilePath ?? '',
            att.sketch!.previewImage ?? '',
            att.sketch!.backgroundImage ?? '',
          ],
          AttachmentType.audio => [att.recording!.src],
        }.where((path) => path.isNotEmpty).toList();
        // Check both local and remote paths since attachments may have either
        return files.contains(trackedFile.localPath) ||
            files.contains(trackedFile.remotePath);
      });

      if (isOrphaned) {
        try {
          // Only delete local files - keep remote files intact to prevent
          // breaking sync for other devices. Remote cleanup happens on note deletion.
          if (await fs.exists(trackedFile.localPath)) {
            await fs.delete(trackedFile.localPath);
            AppLogger.log(
              "Deleted orphaned local file: ${trackedFile.localPath}",
            );
          }
          // Remove the sync track since the local file no longer exists
          // but preserve the remote file for other devices
          await trackedFile.delete();
        } catch (e) {
          AppLogger.log(
            "Error deleting orphaned attachment ${trackedFile.localPath}: $e",
          );
        }
      }
    }
  }

  /// Downloads attachments and returns the list of successfully downloaded attachments.
  /// Returns null if any attachment has a temporary failure (to retry later).
  /// Attachments with permanent failures (file doesn't exist) are skipped but don't block sync.
  Future<AttachmentBatchDownloadResult> _downloadAttachments(
    List<NoteAttachment> attachmentData,
    Note note,
    DownloadedAttachmentBatch downloads, {
    required bool incomingNoteLocked,
  }) async {
    final attachments = <NoteAttachment>[];

    for (final (index, attachment) in attachmentData.indexed) {
      AppLogger.log(
        "Processing attachment ${index + 1} for note ${note.id} "
        "(${attachment.type.name})",
      );
      final previousAttachment = index < note.attachments.length
          ? note.attachments[index]
          : null;
      final result = await _downloadAttachment(
        attachment,
        note,
        downloads,
        incomingNoteLocked: incomingNoteLocked,
        previousAttachment: previousAttachment,
      );

      switch (result.result) {
        case DownloadResult.success:
          attachments.add(attachment);
          break;
        case DownloadResult.permanentFailure:
          AppLogger.log(
            "Attachment permanently unavailable for note ${note.id}",
          );
          return AttachmentBatchDownloadResult.failure(
            RemoteNoteApplyResult.permanent(
              result.category ?? RemoteNoteFailureCategory.attachment,
              result.code ?? 'attachment-permanent-failure',
            ),
          );
        case DownloadResult.temporaryFailure:
          AppLogger.log(
            "Temporary failure downloading attachment for note ${note.id}, will retry later",
          );
          return AttachmentBatchDownloadResult.failure(
            RemoteNoteApplyResult.retryable(
              result.category ?? RemoteNoteFailureCategory.attachment,
              result.code ?? 'attachment-temporary-failure',
            ),
          );
        case DownloadResult.deferredDependency:
          return AttachmentBatchDownloadResult.failure(
            RemoteNoteApplyResult.deferred(
              result.category ?? RemoteNoteFailureCategory.decryption,
              result.code ?? 'attachment-dependency-unavailable',
            ),
          );
      }
    }

    // Don't delete orphans here - downloads create new local files
    // Orphan cleanup should only happen after uploads
    return AttachmentBatchDownloadResult.success(attachments);
  }

  void _validateAttachmentLocators(List<NoteAttachment> attachments) {
    for (final attachment in attachments) {
      final locators = switch (attachment.type) {
        AttachmentType.image => [attachment.image!.src],
        AttachmentType.audio => [attachment.recording!.src],
        AttachmentType.sketch => [
          attachment.sketch!.strokesFilePath,
          attachment.sketch!.backgroundImage,
        ],
      };
      if (attachment.type != AttachmentType.sketch &&
          locators.single!.trim().isEmpty) {
        throw const RemoteAttachmentPayloadException(
          'attachment-source-missing',
          'Attachment source must not be empty',
        );
      }
      for (final locator in locators.whereType<String>()) {
        if (!_isRemoteStorageLocator(locator)) continue;
        try {
          _attachmentStorage.parse(locator);
        } on StorageObjectLocatorException catch (error) {
          throw RemoteAttachmentPayloadException(error.code, error.message);
        }
      }
    }
  }

  /// Result of uploading attachments - contains data and success status
  /// Returns null if any required upload failed (attachment upload failure)
  Future<List<dynamic>?> _uploadAttachments(
    List<NoteAttachment> attachments,
    Note note,
    Uint8List umk,
  ) async {
    List<dynamic> attachmentData = [];
    bool hasFailure = false;

    for (final attachment in attachments) {
      // Skip sketch attachments without strokes (nothing to sync)
      if (attachment.type == AttachmentType.sketch) {
        final sketch = attachment.sketch!;
        // Need either strokesFilePath or inline strokes
        final hasStrokesFile =
            sketch.strokesFilePath != null &&
            sketch.strokesFilePath!.isNotEmpty;
        final hasStrokes = sketch.strokes.isNotEmpty;
        final hasEncryptedStrokes = sketch.hasEncryptedStrokes;

        if (!hasStrokesFile && !hasStrokes && !hasEncryptedStrokes) {
          AppLogger.log(
            "Skipping sketch attachment without strokes for note ${note.id}",
          );
          continue;
        }
      }

      // Get remote URLs for the attachment without modifying the original
      final result = await _getRemoteAttachmentJson(attachment, note, umk);

      if (result == null) {
        // Upload failed for this attachment (not just skipped)
        hasFailure = true;
        AppLogger.log(
          "Attachment upload failed for note ${note.id}, aborting sync",
        );
        break;
      }

      attachmentData.add(result);
    }

    if (hasFailure) {
      return null; // Signal that upload failed
    }

    unawaited(
      _deleteOrphanedAttachments(note).catchError((e) {
        AppLogger.error('Error deleting orphaned attachments', e);
      }),
    );
    return attachmentData;
  }

  /// Uploads attachment files and returns JSON with remote URLs
  /// Does NOT modify the original attachment - local note keeps local paths
  /// Returns null if upload fails (to signal sync should be aborted)
  ///
  /// For sketches: uploads strokesFilePath only (strokes data file).
  /// previewImage, thumbnail, and image are NOT uploaded - they are generated on device.
  /// For backward compatibility, still supports strokes in the JSON (legacy format).
  Future<Map<String, dynamic>?> _getRemoteAttachmentJson(
    NoteAttachment attachment,
    Note note,
    Uint8List umk,
  ) async {
    // Start with the current JSON representation
    final attachmentJson = attachment.toJson();
    removeLocalAttachmentPresentationFromRemoteJson(attachmentJson);

    // Handle sketch attachments differently - upload strokes file, not preview
    if (attachment.type == AttachmentType.sketch) {
      final sketch = attachment.sketch!;
      final data = attachmentJson['data'] as Map<String, dynamic>;

      // Upload strokes file if available
      if (sketch.strokesFilePath != null &&
          sketch.strokesFilePath!.isNotEmpty &&
          !_isRemoteStorageLocator(sketch.strokesFilePath!)) {
        final remoteUrl = await _uploadFile(
          sketch.strokesFilePath!,
          note,
          'strokes',
          umk,
        );
        if (remoteUrl != null) {
          data['strokesFilePath'] = remoteUrl;
          // Use the content hash already computed by _uploadFile and stored
          // in the FileSyncTrack record, avoiding a redundant file read.
          final uploadedSync = await FileSyncTrack.getByLocalPath(
            sketch.strokesFilePath!,
          );
          if (uploadedSync?.contentHash != null) {
            data['strokesContentHash'] = uploadedSync!.contentHash;
          }
          // Remove inline strokes since they're now in the file
          data.remove('strokes');
          data.remove('bgColor');
          data.remove('pagePattern');
        } else {
          // Strokes file upload failed - abort sync
          AppLogger.log(
            "Failed to upload strokes file for note ${note.id}, aborting sync",
          );
          return null;
        }
      }
      // If no strokesFilePath, keep strokes in JSON for backward compatibility

      // Upload background image if present (user-added background, not preview)
      if (sketch.backgroundImage != null &&
          sketch.backgroundImage!.isNotEmpty &&
          !_isRemoteStorageLocator(sketch.backgroundImage!)) {
        final bgSrc = sketch.backgroundImage!;
        final remoteBgUrl = await _uploadFile(bgSrc, note, 'bg', umk);
        if (remoteBgUrl != null) {
          data['backgroundImage'] = remoteBgUrl;
        } else {
          AppLogger.log(
            "Failed to upload background image for note ${note.id}, aborting sync",
          );
          return null;
        }
      }

      return attachmentJson;
    }

    // Upload image attachment
    if (attachment.type == AttachmentType.image) {
      final src = attachment.image?.src;
      if (src != null && src.isNotEmpty && !_isRemoteStorageLocator(src)) {
        final remoteUrl = await _uploadFile(src, note, 'main', umk);
        final data = attachmentJson['data'] as Map<String, dynamic>;
        if (remoteUrl != null) {
          data['src'] = remoteUrl;
        } else {
          AppLogger.log(
            "Failed to upload image for note ${note.id}, aborting sync",
          );
          return null;
        }
      }
      return attachmentJson;
    }

    // Handle audio attachments - upload as before
    final src = attachment.recording?.src;
    if (src != null && src.isNotEmpty && !_isRemoteStorageLocator(src)) {
      final remoteUrl = await _uploadFile(src, note, 'main', umk);
      final data = attachmentJson['data'] as Map<String, dynamic>;
      if (remoteUrl != null) {
        data['src'] = remoteUrl;
      } else {
        AppLogger.log(
          "Failed to upload audio for note ${note.id}, aborting sync",
        );
        return null;
      }
    }

    return attachmentJson;
  }

  /// Helper to upload a single file and return remote URL
  Future<String?> _uploadFile(
    String src,
    Note note,
    String suffix,
    Uint8List umk,
  ) async {
    if (_isRemoteStorageLocator(src)) {
      return null; // Already remote
    }

    String? remoteUrl;
    String? uploadContentHash;
    final FileSyncTrack? sync = await FileSyncTrack.getByLocalPath(src);

    if (sync != null && sync.remotePath != null) {
      // Check if the local file content has changed since last upload.
      // The strokes file is overwritten in-place when a sketch is edited,
      // so the path stays the same but content changes.
      final fs = await fileSystem();
      bool contentChanged = false;
      if (await fs.exists(src)) {
        try {
          final currentBytes = await readEncryptedBytes(src);
          final currentHash = FileSyncTrack.computeHash(currentBytes);
          if (sync.contentHash == null || sync.contentHash != currentHash) {
            contentChanged = true;
            AppLogger.log("Local file content changed since last upload: $src");
          }
        } catch (e) {
          // If we can't read the file (e.g., encryption key mismatch after
          // migration), treat as changed to trigger re-upload.
          contentChanged = true;
          AppLogger.error(
            'Failed to read local file for hash comparison: $src',
            e,
          );
        }
      }

      if (!contentChanged) {
        // Verify remote file still exists - it may have been incorrectly deleted
        final remoteExists = await _verifyRemoteFileExists(sync.remotePath!);
        if (remoteExists) {
          return sync.remotePath!;
        }
        // Remote file is missing, need to re-upload
        AppLogger.log(
          "Remote file missing for ${sync.localPath}, will re-upload",
        );
      }
    }

    final userStorageRef = getNoteDocsRef(note.id!);

    if (src.startsWith('data:')) {
      try {
        final commaIndex = src.indexOf(',');
        if (commaIndex == -1) {
          return null;
        }

        final base64Data = src.substring(commaIndex + 1);
        var bytes = Uint8List.fromList(base64Decode(base64Data));

        // Compute hash from plaintext bytes before encryption
        uploadContentHash = FileSyncTrack.computeHash(bytes);

        String extension = 'bin';
        final regex = RegExp(
          r'(?:image|audio|application)\/([a-zA-Z0-9+]+);base64',
        );
        final match = regex.firstMatch(src);
        if (match != null && match.groupCount >= 1) {
          extension = match.group(1)!;
        }
        final fileRef = userStorageRef.child(
          '${note.id}_${suffix}_${DateTime.now().millisecondsSinceEpoch}.$extension',
        );

        bytes = await FileEncryption.encryptBytes(bytes, umk);
        AppLogger.log("Encrypted data URI attachment");

        syncStatus.value = const SyncProgress(SyncPhase.uploadingMedia);
        _setNoteStatus(note.id!, const SyncProgress(SyncPhase.uploadingMedia));
        _ensureUMKAvailable(umk);
        await fileRef.putData(bytes).timeout(const Duration(seconds: 120));
        requireCloudOperation();
        remoteUrl = await fileRef.getDownloadURL().timeout(
          const Duration(seconds: 10),
        );
      } on SyncEncryptionUnavailable {
        rethrow;
      } catch (e) {
        if (e is CloudOperationCancelled || isCloudConnectionFailure(e)) {
          rethrow;
        }
        AppLogger.error('Error uploading data URI image', e);
        return null;
      }
    } else {
      final fs = await fileSystem();
      if (await fs.exists(src)) {
        final fileName = path.basename(src);
        final fileRef = userStorageRef.child(fileName);

        try {
          syncStatus.value = const SyncProgress(SyncPhase.uploadingMedia);
          _setNoteStatus(
            note.id!,
            const SyncProgress(SyncPhase.uploadingMedia),
          );

          final plainBytes = await readEncryptedBytes(src);
          uploadContentHash = FileSyncTrack.computeHash(plainBytes);
          final fileBytes = await FileEncryption.encryptBytes(plainBytes, umk);
          AppLogger.log("Encrypted attachment: $fileName");

          _ensureUMKAvailable(umk);
          await fileRef
              .putData(fileBytes)
              .timeout(const Duration(seconds: 120));
          remoteUrl = await fileRef.getDownloadURL().timeout(
            const Duration(seconds: 10),
          );
        } on SyncEncryptionUnavailable {
          rethrow;
        } catch (e) {
          if (e is CloudOperationCancelled || isCloudConnectionFailure(e)) {
            rethrow;
          }
          AppLogger.error('Error uploading $fileName', e);
          _markSyncFailed(note.id!);
          return null;
        }
      } else {
        AppLogger.log(
          "[SYNC] UPLOAD: Local file not found: $src for note ${note.id}",
        );
        return null;
      }
    }

    requireCloudOperation();
    if (sync == null) {
      final newSync = FileSyncTrack(
        localPath: src,
        remotePath: remoteUrl,
        contentHash: uploadContentHash,
        noteId: note.id!,
      );
      await newSync.save();
    } else {
      sync.remotePath = remoteUrl;
      sync.contentHash = uploadContentHash;
      await sync.save();
    }

    return remoteUrl;
  }

  /// Downloads attachment file and returns the download result
  /// Returns DownloadResult.success if downloaded, permanentFailure if file doesn't exist,
  /// or temporaryFailure for retryable errors
  ///
  /// For sketches: downloads strokesFilePath if available (new format),
  /// then regenerates preview from strokes. Falls back to legacy format
  /// (downloading previewImage or using inline strokes) for backward compatibility.
  Future<FileDownloadResult> _downloadAttachment(
    NoteAttachment attachment,
    Note note,
    DownloadedAttachmentBatch downloads, {
    required bool incomingNoteLocked,
    NoteAttachment? previousAttachment,
  }) async {
    // Handle sketch attachments with new strokes file format
    if (attachment.type == AttachmentType.sketch) {
      final sketch = attachment.sketch!;
      final incomingStrokesRemotePath = sketch.strokesFilePath;

      // Try to download strokes file (new format)
      if (sketch.strokesFilePath != null &&
          sketch.strokesFilePath!.isNotEmpty &&
          _isRemoteStorageLocator(sketch.strokesFilePath!)) {
        final result = await _downloadFile(
          sketch.strokesFilePath!,
          note,
          downloads,
          expectedContentHash: sketch.strokesContentHash,
        );
        if (result.isSuccess && result.localPath != null) {
          sketch.strokesFilePath = result.localPath;
          // Locked files remain password-encrypted until the first successful
          // unlock. Unlocked notes can hydrate immediately for preview render.
          if (!incomingNoteLocked) {
            final hydration = await SketchStrokesFileService.hydrate(sketch);
            if (hydration.hasStrokes) {
              AppLogger.log('Loaded strokes from file for note ${note.id}');
            }
          }
        } else if (result.result == DownloadResult.permanentFailure) {
          AppLogger.log('Strokes file not found for note ${note.id}');
          return result;
        } else {
          // Temporary failure - retry later
          return result;
        }
      }

      // Download the background before preview generation. Stroke points for
      // image sketches are stored in the background's intrinsic pixel space.
      var backgroundPermanentlyMissing = false;
      if (sketch.backgroundImage != null &&
          sketch.backgroundImage!.isNotEmpty &&
          _isRemoteStorageLocator(sketch.backgroundImage!)) {
        final result = await _downloadFile(
          sketch.backgroundImage!,
          note,
          downloads,
        );
        if (result.isSuccess && result.localPath != null) {
          sketch.backgroundImage = result.localPath;
        } else if (result.isTemporaryFailure || result.isDeferred) {
          return result;
        } else {
          backgroundPermanentlyMissing = true;
          AppLogger.log(
            'Sketch background permanently missing for note ${note.id}; '
            'preserving its image coordinate space and source marker',
          );
        }
      }

      if (backgroundPermanentlyMissing) {
        await _retainMatchingSketchPresentation(
          incoming: sketch,
          previousAttachment: previousAttachment,
          incomingStrokesRemotePath: incomingStrokesRemotePath,
        );
        return FileDownloadResult(DownloadResult.success);
      }

      final previewNeedsRegen =
          sketch.previewImage == null ||
          sketch.previewImage!.isEmpty ||
          _isRemoteStorageLocator(sketch.previewImage!);

      // Skip preview generation for locked notes - strokes are encrypted.
      if (previewNeedsRegen &&
          sketch.strokes.isNotEmpty &&
          !incomingNoteLocked) {
        final oldPreviewPath = sketch.previewImage;
        sketch.previewImage = null;
        sketch.blurredThumbnail = null;
        try {
          final success = await SketchPreviewGenerator.generatePreview(sketch);
          if (success) {
            AppLogger.log('Generated preview for note ${note.id} after sync');
            if (oldPreviewPath != null && oldPreviewPath.isNotEmpty) {
              UniversalImageCache.instance.invalidate(oldPreviewPath);
            }
          }
        } catch (e) {
          AppLogger.error('Error generating preview after sync', e);
        }
      }

      return FileDownloadResult(DownloadResult.success);
    }

    // Handle image attachments
    if (attachment.type == AttachmentType.image) {
      final src = attachment.image?.src;
      if (src != null && src.isNotEmpty && _isRemoteStorageLocator(src)) {
        final result = await _downloadFile(src, note, downloads);
        if (result.isSuccess && result.localPath != null) {
          attachment.image!.src = result.localPath!;
        } else {
          return result;
        }
      } else if (src != null &&
          src.isNotEmpty &&
          !_isRemoteStorageLocator(src)) {
        final fs = await fileSystem();
        if (!await fs.exists(src)) {
          return FileDownloadResult(
            DownloadResult.permanentFailure,
            null,
            RemoteNoteFailureCategory.attachment,
            'local-attachment-missing',
          );
        }
      } else {
        return FileDownloadResult(
          DownloadResult.permanentFailure,
          null,
          RemoteNoteFailureCategory.invalidPayload,
          'attachment-source-missing',
        );
      }
      return FileDownloadResult(DownloadResult.success);
    }

    // Handle audio attachments
    final src = attachment.recording?.src;
    if (src != null && src.isNotEmpty && _isRemoteStorageLocator(src)) {
      final result = await _downloadFile(src, note, downloads);
      if (result.isSuccess && result.localPath != null) {
        attachment.recording!.src = result.localPath!;
      } else {
        return result;
      }
    } else if (src != null && src.isNotEmpty && !_isRemoteStorageLocator(src)) {
      final fs = await fileSystem();
      if (!await fs.exists(src)) {
        return FileDownloadResult(
          DownloadResult.permanentFailure,
          null,
          RemoteNoteFailureCategory.attachment,
          'local-attachment-missing',
        );
      }
    } else {
      return FileDownloadResult(
        DownloadResult.permanentFailure,
        null,
        RemoteNoteFailureCategory.invalidPayload,
        'attachment-source-missing',
      );
    }

    return FileDownloadResult(DownloadResult.success);
  }

  Future<void> _retainMatchingSketchPresentation({
    required SketchData incoming,
    required NoteAttachment? previousAttachment,
    required String? incomingStrokesRemotePath,
  }) async {
    if (previousAttachment?.type != AttachmentType.sketch ||
        incomingStrokesRemotePath == null ||
        !_isRemoteStorageLocator(incomingStrokesRemotePath) ||
        incoming.strokesContentHash == null ||
        incoming.strokesContentHash!.isEmpty) {
      return;
    }
    final previous = previousAttachment!.sketch!;
    if (previous.strokesContentHash != incoming.strokesContentHash) return;

    final previousStrokesPath = previous.strokesFilePath;
    final previousPreview = previous.previewImage;
    if (previousStrokesPath == null ||
        previousStrokesPath.isEmpty ||
        previousPreview == null ||
        previousPreview.isEmpty ||
        _isRemoteStorageLocator(previousPreview)) {
      return;
    }
    final tracking = await FileSyncTrack.getByLocalPath(previousStrokesPath);
    final fs = await fileSystem();
    if (!canRetainLastGoodSketchPreview(
      incoming: incoming,
      previousAttachment: previousAttachment,
      incomingStrokesRemotePath: incomingStrokesRemotePath,
      trackedStrokesRemotePath: tracking?.remotePath,
      previewExists: await fs.exists(previousPreview),
    )) {
      return;
    }

    incoming.previewImage = previousPreview;
    incoming.blurredThumbnail = previous.blurredThumbnail;
  }

  @visibleForTesting
  static bool canRetainLastGoodSketchPreview({
    required SketchData incoming,
    required NoteAttachment? previousAttachment,
    required String? incomingStrokesRemotePath,
    required String? trackedStrokesRemotePath,
    required bool previewExists,
  }) {
    if (previousAttachment?.type != AttachmentType.sketch ||
        incomingStrokesRemotePath == null ||
        !_isRemoteStorageLocator(incomingStrokesRemotePath) ||
        incoming.strokesContentHash == null ||
        incoming.strokesContentHash!.isEmpty ||
        !previewExists) {
      return false;
    }
    final previous = previousAttachment!.sketch!;
    return previous.strokesContentHash == incoming.strokesContentHash &&
        previous.previewImage != null &&
        previous.previewImage!.isNotEmpty &&
        !_isRemoteStorageLocator(previous.previewImage!) &&
        trackedStrokesRemotePath == incomingStrokesRemotePath;
  }

  @visibleForTesting
  static bool isIncomingNoteLocked(Object? value) => _isLockedValue(value);

  static bool _isLockedValue(Object? value) => value == true || value == 1;

  /// Generated previews and privacy thumbnails are device-local derivatives.
  /// Remove them from outgoing JSON for every attachment type.
  @visibleForTesting
  static void removeLocalAttachmentPresentationFromRemoteJson(
    Map<String, dynamic> attachmentJson,
  ) {
    final data = attachmentJson['data'];
    if (data is! Map<String, dynamic>) return;

    data.remove('blurredThumbnail');
    if (attachmentJson['type'] == AttachmentType.sketch.name) {
      data.remove('previewImage');
    }
  }

  /// Ignore presentation derivatives left by older clients. A new device must
  /// show placeholders until it can safely generate local thumbnails.
  @visibleForTesting
  static void discardRemoteAttachmentPresentation(NoteAttachment attachment) {
    attachment.image?.blurredThumbnail = null;
    final sketch = attachment.sketch;
    if (sketch != null) {
      sketch.previewImage = null;
      sketch.blurredThumbnail = null;
    }
  }

  /// Helper to download a single file and return local path with result status.
  ///
  /// [expectedContentHash] is the SHA-256 hash of the plaintext file content
  /// from the remote metadata (e.g., attachment JSON in Firestore). When provided,
  /// it's compared against the locally cached file's hash to detect when the remote
  /// file was updated at the same URL (e.g., sketch re-uploaded to the same path).
  Future<FileDownloadResult> _downloadFile(
    String src,
    Note note,
    DownloadedAttachmentBatch downloads, {
    String? expectedContentHash,
    bool force = false,
  }) async {
    if (!_isRemoteStorageLocator(src)) {
      return FileDownloadResult(
        DownloadResult.permanentFailure,
        null,
        RemoteNoteFailureCategory.invalidPayload,
        'invalid-storage-locator',
      );
    }

    late final StorageObjectLocator locator;
    try {
      locator = _attachmentStorage.parse(src);
    } on StorageObjectLocatorException catch (error) {
      AppLogger.log('[SYNC] Attachment locator rejected: code=${error.code}');
      return FileDownloadResult(
        DownloadResult.permanentFailure,
        null,
        RemoteNoteFailureCategory.invalidPayload,
        error.code,
      );
    }
    final prepared = downloads.prepared(src);
    if (prepared != null) {
      if (expectedContentHash != null &&
          prepared.contentHash != expectedContentHash) {
        return FileDownloadResult(
          DownloadResult.temporaryFailure,
          null,
          RemoteNoteFailureCategory.attachment,
          'attachment-hash-mismatch',
        );
      }
      return FileDownloadResult(DownloadResult.success, prepared.localPath);
    }
    final fs = await fileSystem();
    final rows = await downloads.database.query(
      FileSyncTrack.model,
      where: 'remote_path = ?',
      whereArgs: [src],
      limit: 1,
    );
    final previous = rows.isEmpty ? null : rows.single;
    final sync = previous == null ? null : FileSyncTrack.fromJson(previous);

    // If we have a sync record, check if the local file actually exists and is valid
    if (sync != null) {
      // On iOS, the container UUID changes between runs - fix the stored path
      final fixedLocalPath = await FileUtils.fixPath(sync.localPath);
      if (!force && await fs.exists(fixedLocalPath)) {
        // Validate the file isn't corrupted (e.g., E2EE encrypted bytes saved by mistake)
        // Use readEncryptedBytes to strip local data encryption first,
        // then check if the underlying bytes are E2EE-encrypted
        try {
          final bytes = await readEncryptedBytes(fixedLocalPath);
          if (classifyAttachmentCiphertext(bytes) ==
              AttachmentCiphertextKind.e2ee) {
            // File appears E2EE-encrypted - it was saved incorrectly, re-download
            requireCloudOperation();
            // Keep the old bytes until a validated replacement is persisted.
            AppLogger.log(
              "Local file appears E2EE-encrypted, will re-download: $fixedLocalPath",
            );
          } else if (expectedContentHash != null &&
              sync.contentHash != expectedContentHash) {
            // Remote content was updated at the same URL (e.g., sketch edited
            // on another device). Delete stale cache and re-download.
            // Also triggers when sync.contentHash is null (pre-update records
            // that lack a hash) — re-downloading populates the hash for future
            // comparisons.
            // A remote revision must not destroy the downloaded revision.
            AppLogger.log(
              "Remote content changed (hash mismatch), re-downloading: $fixedLocalPath",
            );
          } else {
            // Update sync record if path changed (iOS container migration)
            if (fixedLocalPath != sync.localPath) {
              sync.localPath = fixedLocalPath;
              downloads.add(previous: previous, next: sync);
            }
            return FileDownloadResult(DownloadResult.success, fixedLocalPath);
          }
        } catch (e) {
          // If we can't read the file, re-download it
          AppLogger.log(
            "Failed to read local file, will re-download: $fixedLocalPath",
          );
          return FileDownloadResult(
            DownloadResult.deferredDependency,
            null,
            RemoteNoteFailureCategory.localApply,
            'local-attachment-unavailable',
          );
        }
      } else {
        // File was deleted, remove the stale sync record and re-download
        // Preserve the mapping until the missing local file is replaced.
        AppLogger.log("Local file missing, will re-download: $fixedLocalPath");
      }
    }

    // Use FileSystem interface for cross-platform compatibility
    final documentsDir = await fs.documentDir;
    final extension = path.extension(locator.fullPath);
    final localPath = path.join(documentsDir, '${Uuid().v4()}$extension');
    try {
      final downloadedBytes = await _attachmentStorage
          .download(src)
          .timeout(const Duration(seconds: 120));
      requireCloudOperation();
      if (downloadedBytes == null) {
        return FileDownloadResult(
          DownloadResult.temporaryFailure,
          null,
          RemoteNoteFailureCategory.attachment,
          'empty-storage-response',
        );
      }

      Uint8List bytes = downloadedBytes;

      // Decrypt if E2EE is enabled and file appears encrypted
      final e2ee = E2EEService.instance;
      final ciphertextKind = classifyAttachmentCiphertext(bytes);

      if (ciphertextKind == AttachmentCiphertextKind.e2ee) {
        if (!e2ee.isCryptoReady) {
          AppLogger.log(
            "Cannot decrypt attachment - E2EE not ready: $localPath",
          );
          // Fail download, will retry when E2EE is ready
          return FileDownloadResult(
            DownloadResult.deferredDependency,
            null,
            RemoteNoteFailureCategory.decryption,
            'e2ee-not-ready',
          );
        }

        final umk = e2ee.deviceManager.getUMK();
        if (umk == null) {
          AppLogger.log(
            "Cannot decrypt attachment - UMK not available: $localPath",
          );
          // Fail download, will retry when UMK is available
          return FileDownloadResult(
            DownloadResult.deferredDependency,
            null,
            RemoteNoteFailureCategory.decryption,
            'umk-unavailable',
          );
        }

        try {
          bytes = await FileEncryption.decryptBytes(bytes, umk);
          AppLogger.log("Decrypted attachment: $localPath");
        } catch (e) {
          AppLogger.log("Failed to decrypt attachment: $e - will retry later");
          // Fail download rather than save encrypted garbage
          return FileDownloadResult(
            DownloadResult.temporaryFailure,
            null,
            RemoteNoteFailureCategory.decryption,
            'attachment-decryption-failed',
          );
        }
      }

      // Use writeEncryptedBytes to apply local data encryption if enabled
      // This ensures files can be read with readEncryptedBytes elsewhere
      requireCloudOperation();
      if (expectedContentHash != null &&
          FileSyncTrack.computeHash(bytes) != expectedContentHash) {
        return FileDownloadResult(
          DownloadResult.temporaryFailure,
          null,
          RemoteNoteFailureCategory.attachment,
          'attachment-hash-mismatch',
        );
      }
      final staged = await downloads.files.prepareDownloaded(
        bytes: bytes,
        stagedPath: localPath,
        originalPath: sync?.localPath,
        readForSession: readEncryptedBytes,
        writeForSession: writeEncryptedBytes,
      );

      // Keep the mapping private until the note adopts this path.
      final newSync = FileSyncTrack(
        id: sync?.id,
        localPath: localPath,
        remotePath: src,
        contentHash: FileSyncTrack.computeHash(bytes),
        noteId: note.id!,
      );
      downloads.add(previous: previous, next: newSync, file: staged);
      requireCloudOperation();
      return FileDownloadResult(DownloadResult.success, localPath);
    } on NewAttachmentPreparationException {
      return FileDownloadResult(
        DownloadResult.deferredDependency,
        null,
        RemoteNoteFailureCategory.localApply,
        'local-attachment-unavailable',
      );
    } on FirebaseException catch (e) {
      if (isCloudConnectionFailure(e)) rethrow;
      AppLogger.log(
        'Failed to download attachment '
        '(${locator.diagnosticDescription}): ${e.code}',
      );
      // If object doesn't exist on remote, this is a permanent failure
      if (e.code == 'object-not-found') {
        return FileDownloadResult(
          DownloadResult.permanentFailure,
          null,
          RemoteNoteFailureCategory.attachment,
          e.code,
        );
      }
      const retryableCodes = {
        'unknown',
        'retry-limit-exceeded',
        'canceled',
        'cancelled',
      };
      return FileDownloadResult(
        retryableCodes.contains(e.code)
            ? DownloadResult.temporaryFailure
            : DownloadResult.permanentFailure,
        null,
        RemoteNoteFailureCategory.attachment,
        e.code,
      );
    } on StorageObjectLocatorException catch (e) {
      return FileDownloadResult(
        DownloadResult.permanentFailure,
        null,
        RemoteNoteFailureCategory.invalidPayload,
        e.code,
      );
    } catch (e) {
      if (e is CloudOperationCancelled || isCloudConnectionFailure(e)) rethrow;
      AppLogger.error(
        'Failed to download attachment (${locator.diagnosticDescription})',
        e,
      );
      return FileDownloadResult(
        DownloadResult.temporaryFailure,
        null,
        RemoteNoteFailureCategory.attachment,
        'attachment-download-exception',
      );
    }
  }

  /// Encrypts note data if E2EE is enabled.
  /// Encrypts title, content, and sensitive sketch data within attachments.
  Future<Map<String, dynamic>> _encryptNoteData(
    Map<String, dynamic> noteData,
    Uint8List umk,
  ) async {
    final e2ee = E2EEService.instance;

    final title = noteData['title'] as String?;
    final content = noteData['content'] as String?;

    final encrypted = await e2ee.noteEncryption.encryptNoteWithKey(
      title: title,
      content: content,
      umk: umk,
    );

    // Remove plaintext fields and add encrypted fields
    final result = Map<String, dynamic>.from(noteData);
    result.remove('title');
    result.remove('content');
    result.remove('plain_text');

    // Encrypt sensitive sketch data within attachments
    if (result['attachments'] != null) {
      result['attachments'] = await _encryptSketchDataInAttachments(
        result['attachments'],
        umk,
      );
    }

    result.addAll(encrypted.toFirestore());

    return result;
  }

  /// Encrypts sensitive sketch data (strokes, bgColor, pagePattern) inline within attachments.
  /// File URLs remain available for download; generated presentation fields
  /// are removed before this stage and remain local-only.
  Future<dynamic> _encryptSketchDataInAttachments(
    dynamic attachments,
    Uint8List umk,
  ) async {
    List<dynamic> attachmentList;
    if (attachments is String) {
      try {
        attachmentList = json.decode(attachments) as List;
      } catch (e) {
        return attachments;
      }
    } else if (attachments is List) {
      attachmentList = List.from(attachments);
    } else {
      return attachments;
    }

    final result = <Map<String, dynamic>>[];
    for (final att in attachmentList) {
      if (att is! Map<String, dynamic>) {
        // Skip malformed entries instead of force-casting
        AppLogger.log(
          "[SYNC] Skipping malformed attachment entry during encryption",
        );
        continue;
      }

      final type = att['type'] as String?;
      final data = att['data'] as Map<String, dynamic>?;

      if (type != 'sketch' || data == null) {
        // Non-sketch attachments pass through unchanged
        result.add(Map<String, dynamic>.from(att));
        continue;
      }

      // If using strokesFilePath (new format), the strokes file is already
      // encrypted during upload. Strip any residual inline sensitive fields
      // that may exist during format migration (strokes, bgColor, pagePattern).
      if (data['strokesFilePath'] != null) {
        final cleanedData = Map<String, dynamic>.from(data);
        cleanedData.remove('strokes');
        cleanedData.remove('bgColor');
        cleanedData.remove('pagePattern');
        result.add({...att, 'data': cleanedData});
        continue;
      }

      // Legacy format: encrypt inline strokes data
      // Extract sensitive sketch data to encrypt
      final sensitiveData = {
        if (data['strokes'] != null) 'strokes': data['strokes'],
        if (data['bgColor'] != null) 'bgColor': data['bgColor'],
        if (data['pagePattern'] != null) 'pagePattern': data['pagePattern'],
      };

      if (sensitiveData.isEmpty) {
        result.add(Map<String, dynamic>.from(att));
        continue;
      }

      // Encrypt the sensitive data
      final sensitiveJson = json.encode(sensitiveData);
      final encryptedData = await AuthenticatedCipher.encryptString(
        sensitiveJson,
        umk,
      );

      // Create new sketch data with encrypted fields
      final newData = <String, dynamic>{
        if (data['backgroundImage'] != null)
          'backgroundImage': data['backgroundImage'],
        if (data['aspectRatio'] != null) 'aspectRatio': data['aspectRatio'],
        // Encrypted sketch data
        'e2ee_sketch_ciphertext': encryptedData.ciphertext,
        'e2ee_sketch_nonce': encryptedData.nonce,
      };

      result.add({...att, 'data': newData});
    }

    return result;
  }

  /// Decrypts note data if it contains E2EE encrypted content.
  /// Also decrypts sketch data within attachments if encrypted.
  Future<Map<String, dynamic>> _decryptNoteData(
    Map<String, dynamic> noteData,
  ) async {
    final e2ee = E2EEService.instance;

    // Check if data is encrypted
    if (!noteData.containsKey('e2ee_ciphertext')) {
      return noteData;
    }

    if (!e2ee.isCryptoReady) {
      // Can't decrypt - return as-is (will show as locked/encrypted)
      return noteData;
    }

    try {
      final encryptedData = EncryptedNoteData.fromFirestore(noteData);
      final decrypted = await e2ee.noteEncryption.decryptNote(encryptedData);
      if (decrypted == null) return noteData;

      final result = Map<String, dynamic>.from(noteData);
      // Remove encrypted fields
      result.remove('e2ee_ciphertext');
      result.remove('e2ee_nonce');
      result.remove('e2ee_title_ciphertext');
      result.remove('e2ee_title_nonce');
      result.remove('e2ee_version');
      // Add decrypted fields
      result['title'] = decrypted.title;
      result['content'] = decrypted.content;
      result['plain_text'] = decrypted.plainText;

      // Decrypt sketch data within attachments
      if (result['attachments'] != null) {
        result['attachments'] = await _decryptSketchDataInAttachments(
          result['attachments'],
        );
      }

      return result;
    } catch (e) {
      AppLogger.error('E2EE: Failed to decrypt note', e);
      return noteData;
    }
  }

  /// Decrypts sensitive sketch data within attachments.
  /// Restores strokes, bgColor, pagePattern from encrypted fields.
  Future<dynamic> _decryptSketchDataInAttachments(dynamic attachments) async {
    final e2ee = E2EEService.instance;
    final umk = e2ee.deviceManager.getUMK();
    if (umk == null) return attachments;

    List<dynamic> attachmentList;
    if (attachments is String) {
      try {
        attachmentList = json.decode(attachments) as List;
      } catch (e) {
        return attachments;
      }
    } else if (attachments is List) {
      attachmentList = List.from(attachments);
    } else {
      return attachments;
    }

    final result = <Map<String, dynamic>>[];
    for (final att in attachmentList) {
      if (att is! Map<String, dynamic>) {
        // Skip malformed entries instead of force-casting
        AppLogger.log(
          "[SYNC] Skipping malformed attachment entry during decryption",
        );
        continue;
      }

      final type = att['type'] as String?;
      final data = att['data'] as Map<String, dynamic>?;

      if (type != 'sketch' || data == null) {
        // Non-sketch attachments pass through unchanged
        result.add(Map<String, dynamic>.from(att));
        continue;
      }

      // Check if sketch has encrypted data
      final ciphertext = data['e2ee_sketch_ciphertext'] as String?;
      final nonce = data['e2ee_sketch_nonce'] as String?;

      if (ciphertext == null || nonce == null) {
        // No encrypted data, pass through (backward compatibility)
        result.add(Map<String, dynamic>.from(att));
        continue;
      }

      try {
        // Decrypt the sensitive data
        final decryptedJson = await AuthenticatedCipher.decryptString(
          ciphertext,
          nonce,
          umk,
        );
        final sensitiveData =
            json.decode(decryptedJson) as Map<String, dynamic>;

        // Merge decrypted data back into sketch
        final newData = Map<String, dynamic>.from(data);
        newData.remove('e2ee_sketch_ciphertext');
        newData.remove('e2ee_sketch_nonce');
        newData.addAll(sensitiveData);

        result.add({...att, 'data': newData});
      } catch (e) {
        AppLogger.error('E2EE: Failed to decrypt sketch data', e);
        // Keep as-is on failure
        result.add(Map<String, dynamic>.from(att));
      }
    }

    return result;
  }

  /// Verifies that a remote file still exists in Firebase Storage.
  /// Returns true if the file exists, false if it doesn't or on error.
  Future<bool> _verifyRemoteFileExists(String remoteUrl) async {
    try {
      final ref = _attachmentStorage.reference(remoteUrl);
      await ref.getMetadata().timeout(const Duration(seconds: 10));
      requireCloudOperation();
      return true;
    } on StorageObjectLocatorException catch (error) {
      AppLogger.log('Remote attachment locator is invalid: code=${error.code}');
      return false;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') {
        return false;
      }
      // For other errors (network issues, etc.), assume file exists to avoid unnecessary re-uploads
      AppLogger.error('Error verifying remote file exists', e);
      rethrow;
    } catch (e) {
      AppLogger.error('Error verifying remote file', e);
      rethrow;
    }
  }

  /// Re-downloads a file from its remote URL if the local file is missing or corrupted.
  /// Returns the local path if successful, null otherwise.
  /// This is useful for recovering images that fail to load.
  Future<String?> redownloadFile(String localPath) async {
    final current = _captureSession();
    if (!_canReceiveSync) return null;
    try {
      return await runCloudOperation(current, () async {
        final fixedPath = await FileUtils.fixPath(localPath);
        final sync =
            await FileSyncTrack.getByLocalPath(localPath) ??
            await FileSyncTrack.getByLocalPath(fixedPath);
        requireCloudOperation();
        if (sync?.remotePath == null) return null;
        return _repairAttachmentReference(
          sync!.remotePath!,
          sync.noteId,
          oldPath: sync.localPath,
          force: true,
        );
      });
    } catch (error, stack) {
      if (current() && isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
      }
      if (error is! CloudOperationCancelled) {
        AppLogger.error('Attachment repair deferred', error, stack);
      }
      return null;
    }
  }

  /// Retries a remote attachment whose first download never created a local
  /// tracking row (for example, a temporarily missing sketch background).
  Future<String?> retryRemoteAttachmentDownload(
    String remotePath,
    Note note,
  ) async {
    if (!_isRemoteStorageLocator(remotePath)) {
      return null;
    }
    final current = _captureSession();
    if (!_canReceiveSync) return null;
    try {
      if (note.id == null) return null;
      return await runCloudOperation(
        current,
        () => _repairAttachmentReference(remotePath, note.id!),
      );
    } catch (error, stack) {
      if (current() && isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
      }
      if (error is! CloudOperationCancelled) {
        AppLogger.error('Attachment retry deferred', error, stack);
      }
      return null;
    }
  }

  Future<String?> _repairAttachmentReference(
    String source,
    int noteId, {
    String? oldPath,
    bool force = false,
  }) async {
    final downloads = await _newDownloadBatch();
    final repairs = AttachmentRepairCoordinator.instance.capture(
      downloads.database,
    );
    try {
      final rows = await downloads.database.query(
        Note.model,
        where: 'id = ?',
        whereArgs: [noteId],
      );
      if (rows.isEmpty) return null;
      final expectedRow = rows.single;
      final note = await Note.fromJsonAsync(expectedRow);
      final result = await _downloadFile(source, note, downloads, force: force);
      if (!result.isSuccess || result.localPath == null) return null;
      final replacement = result.localPath!;
      final fixedOldPath = oldPath == null
          ? null
          : await FileUtils.fixPath(oldPath);
      final replacements = {
        for (final value in [source, oldPath, fixedOldPath].whereType<String>())
          if (value != replacement) value: replacement,
      };
      if (!replaceAttachmentPaths(note.attachments, replacements)) {
        return null;
      }
      final attachments = await note.serializeAttachmentsForLocalStorage();
      await repairs.run(noteId, () async {
        downloads.committed = await downloads.database.transaction((txn) async {
          requireCloudOperation();
          final rows = await txn.query(
            Note.model,
            where: 'id = ?',
            whereArgs: [noteId],
          );
          if (rows.isEmpty || !mapEquals(rows.single, expectedRow)) {
            return false;
          }
          if (!await downloads.commitMappings(txn)) return false;
          await Note.updateAttachmentsIfUnchanged(
            id: noteId,
            expectedUpdatedAt: expectedRow['updated_at'],
            expectedAttachments: expectedRow['attachments'],
            attachments: attachments,
            database: txn,
          );
          requireCloudOperation();
          return true;
        });
        if (downloads.committed && cloudOperationIsCurrent()) {
          repairs.committed(noteId, replacements);
          note.notifyWithOrigin('updated', ModelChangeOrigin.remoteSync);
        }
      });
      if (!downloads.committed) return null;
      return replacement;
    } finally {
      await downloads.finish();
    }
  }
}
