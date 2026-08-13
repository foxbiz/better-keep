import 'dart:async';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/remote_pull_lifecycle.dart';
import 'package:better_keep/services/retry_controller.dart';
import 'package:better_keep/services/staged_checkpoint.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

class LabelSyncService {
  @visibleForTesting
  static Future<void> Function()? refreshOperationOverride;

  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  StreamSubscription<User?>? _userStreamSubscription;
  bool _initialized = false;
  final InitialHydrationGate _initialHydration = InitialHydrationGate();
  final HydrationRetryController _listenerRetry = HydrationRetryController();
  final ExponentialBackoffRetryController _pullRetry =
      ExponentialBackoffRetryController();
  final AsyncKeyedSerializer<String> _listenerBatchSerializer =
      AsyncKeyedSerializer();
  final AsyncKeyedSerializer<String> _labelApplySerializer =
      AsyncKeyedSerializer();
  final AsyncKeyedSerializer<String> _syncOperationSerializer =
      AsyncKeyedSerializer();
  static const String _listenerBatchKey = 'label-listener';
  static const String _syncOperationKey = 'label-sync';

  Future<void> get initialHydration => _initialHydration.ready;

  LabelSyncService._internal();

  factory LabelSyncService() => _instance;

  static final LabelSyncService _instance = LabelSyncService._internal();

  FirebaseFirestore get _firestore => FirebaseBackend.firestore;

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<SyncProgress> syncStatus = ValueNotifier(
    SyncProgress.idle,
  );

  /// Tracks label IDs currently being synced (outgoing push)
  final ValueNotifier<Set<int>> syncingOutgoing = ValueNotifier({});

  /// Tracks label IDs currently being synced (incoming pull)
  final ValueNotifier<Set<int>> syncingIncoming = ValueNotifier({});

  /// Tracks labels that failed to sync
  final ValueNotifier<Set<int>> syncFailed = ValueNotifier({});

  User? get currentUser => AuthService.currentUser;
  DocumentReference<Map<String, dynamic>> get _userRef =>
      _firestore.collection('users').doc(currentUser!.uid);
  CollectionReference<Map<String, dynamic>> get _labelsCollection =>
      _userRef.collection('labels');

  void _markSyncFailed(int labelId) {
    syncFailed.value = {...syncFailed.value, labelId};
  }

  void _clearSyncFailed(int labelId) {
    syncFailed.value = {...syncFailed.value}..remove(labelId);
  }

  void _addSyncingOutgoing(int labelId) {
    syncingOutgoing.value = {...syncingOutgoing.value, labelId};
    _clearSyncFailed(labelId);
  }

  void _removeSyncingOutgoing(int labelId) {
    syncingOutgoing.value = {...syncingOutgoing.value}..remove(labelId);
  }

  void _addSyncingIncoming(int labelId) {
    syncingIncoming.value = {...syncingIncoming.value, labelId};
    _clearSyncFailed(labelId);
  }

  void _removeSyncingIncoming(int labelId) {
    syncingIncoming.value = {...syncingIncoming.value}..remove(labelId);
  }

  bool get _isReviewSession => ReviewAccess.isAuthorizedSessionFor(currentUser);

  /// Check if we can receive/download sync (incoming):
  /// - Not an authorized review session
  /// - Session must be valid
  /// Note: Pro subscription NOT required for receiving sync
  bool get _canReceiveSync {
    // If session is invalid (user deleted/disabled), disable all sync
    if (AuthService.sessionInvalid.value) {
      return false;
    }

    if (_isReviewSession || !E2EEService.instance.isCryptoReady) {
      return false;
    }
    return true;
  }

  /// Check if we can push/upload sync (outgoing):
  /// - Must have Pro subscription (cloud sync upload is a Pro feature)
  /// - Not an authorized review session
  bool get _canPushSync {
    if (!_canReceiveSync) {
      return false;
    }
    // Cloud sync upload requires Pro subscription
    if (!PlanService.instance.isPaid) {
      return false;
    }
    return true;
  }

  /// Track the previous subscription state to detect upgrades
  bool _wasPreviouslyPaid = false;

  Future<void> init() async {
    // Prevent duplicate initialization and listener registration
    if (_initialized) return;
    _initialized = true;

    AppLogger.log("[LABEL_SYNC] LabelSyncService initialized");

    final e2ee = E2EEService.instance;
    _lastKnownCryptoReady = e2ee.isCryptoReady;

    // Initialize with current subscription state
    _wasPreviouslyPaid = PlanService.instance.isPaid;

    // Listen for subscription changes
    PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);

    if (currentUser != null) {
      // Review sessions are intentionally local-only.
      if (_isReviewSession) {
        AppLogger.log("[LABEL_SYNC] Skipping sync - review session");
        return;
      }
      // Only start sync if E2EE is ready - otherwise wait for E2EE status change listener
      if (E2EEService.instance.isCryptoReady) {
        final checkpoint = AppState.labelCloudSyncCheckpoint;
        if (checkpoint == null || checkpoint.requiresBootstrap) {
          unawaited(refresh());
        } else {
          // Push sync requires Pro, but start listener for incoming sync
          if (_canPushSync) {
            unawaited(_sync());
          }
          await _startRemoteListener();
        }
      } else {
        AppLogger.log(
          "[LABEL_SYNC] Deferring sync - E2EE not ready (status: ${E2EEService.instance.status.value})",
        );
      }
    }

    // Listen for E2EE status changes to trigger sync when ready
    e2ee.status.addListener(_onE2EEReadinessChange);
    e2ee.deviceManager.hasUMK.addListener(_onE2EEReadinessChange);

    _userStreamSubscription = AuthService.userStream.listen((user) async {
      if (user != null) {
        // Review sessions are intentionally local-only.
        if (_isReviewSession) {
          AppLogger.log("[LABEL_SYNC] Skipping sync - review session");
          return;
        }
        AppState.lastLabelSynced = null;
        // Ensure system labels exist immediately on login
        // (before remote sync which may take time or fail)
        Label.fixLabels();
        // Only sync if E2EE is ready - otherwise wait for E2EE status change
        if (E2EEService.instance.isCryptoReady) {
          await _startRemoteListener();
          unawaited(refresh());
        } else {
          AppLogger.log(
            "[LABEL_SYNC] Deferring sync on login - E2EE not ready (status: ${E2EEService.instance.status.value})",
          );
        }
      } else {
        await _stopRemoteListener();
      }
    });
  }

  bool _lastKnownCryptoReady = false;

  /// Called when E2EE status changes - trigger sync when E2EE becomes ready
  void _onE2EEReadinessChange() {
    final e2ee = E2EEService.instance;
    final isNowReady = e2ee.isCryptoReady;
    final wasReady = _lastKnownCryptoReady;
    _lastKnownCryptoReady = isNowReady;

    AppLogger.log(
      '[LABEL_SYNC] Crypto readiness changed from $wasReady to $isNowReady',
    );

    // Review sessions are intentionally local-only.
    if (_isReviewSession) {
      AppLogger.log("[LABEL_SYNC] Review session detected, skipping sync");
      return;
    }

    // Trigger sync when E2EE becomes ready
    if (isNowReady && !wasReady && currentUser != null) {
      AppLogger.log("[LABEL_SYNC] E2EE just became ready, triggering sync");
      Future.microtask(() async {
        await _stopRemoteListener();
        await refresh();
      });
    } else if (!isNowReady && wasReady) {
      unawaited(_stopRemoteListener());
    }
  }

  /// Called when subscription status changes
  void _onSubscriptionChange() {
    final isPaidNow = PlanService.instance.isPaid;
    AppLogger.log(
      "[LABEL_SYNC]Subscription changed - isPaid: $isPaidNow (was: $_wasPreviouslyPaid)",
    );

    // User just upgraded to Pro
    if (isPaidNow && !_wasPreviouslyPaid) {
      AppLogger.log("[LABEL_SYNC]User upgraded to Pro, enabling full sync");
      _wasPreviouslyPaid = true;

      if (currentUser != null) {
        unawaited(_startRemoteListener());
        unawaited(refresh());
      }
    }
    // User downgraded or subscription expired
    else if (!isPaidNow && _wasPreviouslyPaid) {
      // Note: We keep the remote listener running for incoming sync
      // Only outgoing sync is disabled for non-Pro users
      AppLogger.log(
        "[LABEL_SYNC]User no longer Pro, outgoing sync disabled but incoming sync continues",
      );
      _wasPreviouslyPaid = false;
    }
  }

  /// Start listening for real-time updates from Firebase
  Future<void> _startRemoteListener() async {
    await _stopRemoteListener(cancelRetry: false);
    if (currentUser == null || !_canReceiveSync) return;

    final checkpoint = AppState.labelCloudSyncCheckpoint;
    if (checkpoint == null || checkpoint.requiresBootstrap) {
      AppLogger.log(
        "[LABEL_SYNC] Listener waiting for durable checkpoint bootstrap",
      );
      return;
    }

    Query<Map<String, dynamic>> query = _labelsCollection
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

                  final changes = snapshot.docChanges.where(
                    (change) =>
                        !change.doc.metadata.hasPendingWrites &&
                        (change.type == DocumentChangeType.modified ||
                            change.type == DocumentChangeType.added),
                  );

                  if (changes.isEmpty) return;

                  AppLogger.log(
                    "[LABEL_SYNC] Received ${changes.length} remote changes via real-time listener",
                  );

                  final Set<String> processedIds = {};
                  var allChangesSucceeded = true;
                  CloudSyncCursor? latestCursor;

                  for (final change in changes) {
                    final remoteData = change.doc.data();
                    if (remoteData == null) {
                      AppLogger.log(
                        "[LABEL_SYNC] Remote data is null, skipping",
                      );
                      continue;
                    }

                    final remoteDocId = change.doc.id;
                    final documentCursor = CloudSyncCursor.fromDocument(
                      remoteData,
                      remoteDocId,
                    );
                    if (documentCursor == null) {
                      allChangesSucceeded = false;
                      AppLogger.error(
                        '[LABEL_SYNC] Quarantined malformed label $remoteDocId',
                        StateError(
                          '$cloudSyncCommittedAtField must be a Firestore timestamp',
                        ),
                      );
                      continue;
                    }
                    latestCursor = latestCursor == null
                        ? documentCursor
                        : latestCursor.max(documentCursor);
                    AppLogger.log(
                      "[LABEL_SYNC] Processing remote change for doc $remoteDocId",
                    );

                    if (processedIds.contains(remoteDocId)) {
                      AppLogger.log(
                        "[LABEL_SYNC] Already processed $remoteDocId in this batch, skipping",
                      );
                      continue;
                    }
                    processedIds.add(remoteDocId);

                    final isDeleted =
                        remoteData['deleted'] == true ||
                        remoteData['deleted'] == 1;

                    final remoteName = remoteData['name'];
                    if (!isDeleted &&
                        (remoteName is! String ||
                            !_hasValidRemoteDate(remoteData['created_at']) ||
                            !_hasValidRemoteDate(remoteData['updated_at']))) {
                      allChangesSucceeded = false;
                      AppLogger.error(
                        '[LABEL_SYNC] Quarantined malformed label $remoteDocId',
                        StateError(
                          'name and ISO-8601 timestamps are required when present',
                        ),
                      );
                      continue;
                    }

                    // Find existing sync track by remoteId
                    final existingSyncTrack =
                        await LabelSyncTrack.getByRemoteId(remoteDocId);
                    final stableLabel = await Label.findBySyncId(remoteDocId);
                    final localId =
                        existingSyncTrack?.localId ?? stableLabel?.id;

                    if (isDeleted) {
                      AppLogger.log(
                        "[LABEL_SYNC] Label doc $remoteDocId is deleted, handling deletion",
                      );
                      if (localId != null) {
                        _addSyncingIncoming(localId);
                        try {
                          await _handleRemoteDeletedLabelByRemoteId(
                            remoteDocId,
                          );
                        } finally {
                          _removeSyncingIncoming(localId);
                        }
                      } else {
                        await _handleRemoteDeletedLabelByRemoteId(remoteDocId);
                      }
                      continue;
                    }

                    if (existingSyncTrack != null &&
                        (existingSyncTrack.status == LabelSyncStatus.pending ||
                            existingSyncTrack.status ==
                                LabelSyncStatus.failed)) {
                      AppLogger.log(
                        "[LABEL_SYNC] Skipping real-time update for doc $remoteDocId - has pending local changes",
                      );
                      continue;
                    }

                    Label? localLabel;
                    if (localId != null) {
                      localLabel = await Label.findById(localId);
                    }

                    if (localLabel != null &&
                        remoteData['updated_at'] != null) {
                      final localUpdatedAt = localLabel.updatedAt;
                      final updatedAtValue = remoteData['updated_at'];
                      final remoteUpdatedAt = updatedAtValue is String
                          ? DateTime.tryParse(updatedAtValue)
                          : null;
                      if (remoteUpdatedAt == null) {
                        allChangesSucceeded = false;
                        AppLogger.error(
                          '[LABEL_SYNC] Quarantined malformed label $remoteDocId',
                          StateError('updated_at must be an ISO-8601 string'),
                        );
                        continue;
                      }

                      if (localUpdatedAt != null &&
                          (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                              remoteUpdatedAt.isAtSameMomentAs(
                                localUpdatedAt,
                              ))) {
                        AppLogger.log(
                          "[LABEL_SYNC] Skipping doc $remoteDocId - local is same or newer (local: $localUpdatedAt, remote: $remoteUpdatedAt)",
                        );
                        continue;
                      }
                    }

                    AppLogger.log(
                      "[LABEL_SYNC] Patching label from remote doc $remoteDocId",
                    );
                    if (localId != null) {
                      _addSyncingIncoming(localId);
                    }
                    try {
                      await _patchRemoteLabel(remoteData, remoteDocId);
                      AppLogger.log(
                        "[LABEL_SYNC] Patched local label from real-time update: $remoteDocId",
                      );
                    } finally {
                      if (localId != null) {
                        _removeSyncingIncoming(localId);
                      }
                    }
                  }

                  if (allChangesSucceeded && latestCursor != null) {
                    final currentCheckpoint = AppState.labelCloudSyncCheckpoint;
                    if (_initialHydration.isCurrent(hydrationGeneration) &&
                        currentCheckpoint != null &&
                        !currentCheckpoint.requiresBootstrap) {
                      AppState.labelCloudSyncCheckpoint = currentCheckpoint
                          .advanceTo(latestCursor);
                    }
                  } else if (!allChangesSucceeded) {
                    hydrationFailed = true;
                    AppLogger.log(
                      "[LABEL_SYNC] Some changes failed; checkpoint not advanced",
                    );
                  }
                } catch (error, stackTrace) {
                  hydrationFailed = true;
                  AppLogger.error(
                    '[LABEL_SYNC] Hydration attempt failed',
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
                          () => _restartRemoteListenerAfterFailure(
                            hydrationGeneration,
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
            AppLogger.error('LabelSync: Remote listener error', error);
            _initialHydration.failAttempt(hydrationGeneration);
            unawaited(_restartRemoteListenerAfterFailure(hydrationGeneration));
          },
        );

    AppLogger.log("[LABEL_SYNC] Started real-time remote listener");
  }

  Future<void> _restartRemoteListenerAfterFailure(int generation) async {
    if (!_initialHydration.isCurrent(generation)) return;
    await _stopRemoteListener(cancelRetry: false);
    _listenerRetry.schedule(() async {
      if (_initialized && currentUser != null && _canReceiveSync) {
        AppLogger.log('[LABEL_SYNC] Restarting remote listener after failure');
        await _startRemoteListener();
      }
    });
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
        'LabelSync: Error stopping remote listener (safe to ignore)',
        e,
      );
    }
    await _listenerBatchSerializer.waitForIdle(_listenerBatchKey);
  }

  /// Dispose of all listeners and subscriptions.
  /// Call this when the app is shutting down or user logs out.
  Future<void> dispose() async {
    await _stopRemoteListener();
    _syncTimer?.cancel();
    _syncTimer = null;
    await _userStreamSubscription?.cancel();
    _userStreamSubscription = null;
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    E2EEService.instance.status.removeListener(_onE2EEReadinessChange);
    E2EEService.instance.deviceManager.hasUMK.removeListener(
      _onE2EEReadinessChange,
    );
    _initialized = false;
    _initialHydration.reset();
    _listenerRetry.cancel();
    _pullRetry.cancel();
    await _labelApplySerializer.waitForAll();
    // Reset so the ready→ready transition is detected correctly on re-login
    _lastKnownCryptoReady = false;
  }

  Future<void> sync([bool now = false]) async {
    _syncTimer?.cancel();

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[LABEL_SYNC]Skipping sync - push sync not allowed");
      return;
    }

    if (now) {
      _syncTimer = null;
      await _sync();
      return;
    }

    _syncTimer = Timer(const Duration(seconds: 5), () async {
      await _sync();
    });
  }

  Future<void> refresh() =>
      _syncOperationSerializer.run(_syncOperationKey, _refreshUnlocked);

  Future<void> _refreshUnlocked() async {
    final override = refreshOperationOverride;
    if (override != null) {
      await override();
      return;
    }
    if (currentUser == null) return;

    if (!_canReceiveSync) {
      AppLogger.log(
        '[LABEL_SYNC] Skipping refresh - incoming sync unavailable',
      );
      return;
    }

    await Future.microtask(() {});
    if (currentUser == null || !_canReceiveSync) {
      AppLogger.log(
        '[LABEL_SYNC] Skipping refresh - incoming sync became unavailable',
      );
      return;
    }

    try {
      isSyncing.value = true;
      syncStatus.value = const SyncProgress(SyncPhase.checkingForUpdates);
      AppLogger.log("[LABEL_SYNC] Manual refresh started...");

      // Note: _startRemoteListener() is NOT called here.
      // The listener is managed by init(), _onE2EEReadinessChange(), and
      // _onSubscriptionChange() to avoid racing with _pullRemoteChanges()
      // — both would process the same remote docs and create duplicate labels.

      // Only push local changes if user has Pro subscription
      if (_canPushSync) {
        await _pushLocalChanges();
      } else {
        AppLogger.log("[LABEL_SYNC]Skipping push - Pro subscription required");
      }
      if (!_canReceiveSync) {
        syncStatus.value = SyncProgress.idle;
        AppLogger.log(
          '[LABEL_SYNC] Deferring pull - incoming sync became unavailable',
        );
        return;
      }
      // Always pull remote changes (available to all users)
      await _pullRemoteChanges();

      syncStatus.value = const SyncProgress(SyncPhase.complete);
      AppLogger.log("[LABEL_SYNC] Manual refresh complete");
    } on FirestoreDocumentFetchException catch (e, stack) {
      syncStatus.value = const SyncProgress(SyncPhase.failed);
      AppLogger.error('LabelSync: Firestore document fetch failed', e, stack);
    } catch (e, stack) {
      syncStatus.value = const SyncProgress(SyncPhase.failed);
      AppLogger.error('LabelSync: Refresh Failed', e, stack);
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        if (!isSyncing.value) syncStatus.value = SyncProgress.idle;
      });
    }
  }

  Future<void> _sync() =>
      _syncOperationSerializer.run(_syncOperationKey, _syncUnlocked);

  Future<void> _syncUnlocked() async {
    if (currentUser == null) return;

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[LABEL_SYNC]Skipping _sync - push sync not allowed");
      return;
    }

    await Future.microtask(() {});
    if (currentUser == null || !_canPushSync) return;

    final pendingSyncs = await LabelSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[LABEL_SYNC] No local changes to sync");
      return;
    }

    try {
      isSyncing.value = true;
      syncStatus.value = const SyncProgress(SyncPhase.syncing);
      AppLogger.log(
        "[LABEL_SYNC] Syncing ${pendingSyncs.length} local changes...",
      );

      await _pushLocalChangesWithPending(pendingSyncs);

      syncStatus.value = const SyncProgress(SyncPhase.complete);
      AppLogger.log("[LABEL_SYNC] Sync Complete");
    } catch (e, stack) {
      syncStatus.value = const SyncProgress(SyncPhase.failed);
      AppLogger.error('LabelSync: Sync Failed', e, stack);
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        if (!isSyncing.value) syncStatus.value = SyncProgress.idle;
      });
    }
  }

  Future<void> _pushLocalChangesWithPending(
    List<LabelSyncTrack> pendingSyncs,
  ) async {
    if (pendingSyncs.isEmpty) return;
    syncStatus.value = const SyncProgress(SyncPhase.savingChanges);

    WriteBatch batch = _firestore.batch();
    int batchCount = 0;
    final List<Future<void> Function()> postCommitActions = [];

    for (final sync in pendingSyncs) {
      final syncStartTime = DateTime.now();
      _addSyncingOutgoing(sync.localId);
      try {
        if (sync.action == LabelSyncAction.delete && sync.remoteId == null) {
          await sync.delete();
          AppLogger.log(
            "[LABEL_SYNC] Deleted local sync track for label without remote ID: ${sync.localId}",
          );
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        late final Map<String, dynamic>? remoteData;

        if (sync.remoteId != null) {
          final docSnapshot = await _labelsCollection.doc(sync.remoteId).get();
          if (docSnapshot.exists) {
            remoteData = docSnapshot.data()!;
          } else {
            remoteData = null;
          }
        } else {
          remoteData = null;
        }

        if (remoteData != null) {
          final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

          final hasPendingSync =
              sync.status == LabelSyncStatus.pending ||
              sync.status == LabelSyncStatus.failed;

          if (hasPendingSync) {
            AppLogger.log(
              "[LABEL_SYNC] Skipping remote patch for label ${sync.localId} - has pending local changes",
            );
          } else if (sync.updatedAt == null ||
              remoteUpdatedAt.isAfter(sync.updatedAt!)) {
            await _patchRemoteLabel(remoteData, sync.remoteId!);
            AppLogger.log(
              "[LABEL_SYNC] Patched local label from remote changes: ${sync.remoteId}",
            );
            _removeSyncingOutgoing(sync.localId);
            continue;
          }
        }

        final isRemoteDeleted =
            remoteData?['deleted'] == true || remoteData?['deleted'] == 1;
        if (sync.action == LabelSyncAction.delete && !isRemoteDeleted) {
          if (remoteData == null) {
            await sync.delete();
            AppLogger.log(
              "[LABEL_SYNC] Remote document doesn't exist, cleaning up sync track for: ${sync.localId}",
            );
            _removeSyncingOutgoing(sync.localId);
            continue;
          }
          if (sync.remoteId != null) {
            final localId = sync.localId;
            batch.set(_labelsCollection.doc(sync.remoteId), {
              'local_id': sync.localId,
              'deleted_at': FieldValue.serverTimestamp(),
              'deleted': true,
              'updated_at': DateTime.now().toIso8601String(),
              cloudSyncCommittedAtField: FieldValue.serverTimestamp(),
            });
            postCommitActions.add(() async {
              await sync.delete();
              AppLogger.log(
                "[LABEL_SYNC] Deleted remote label: ${sync.remoteId}",
              );
              _removeSyncingOutgoing(localId);
            });
            batchCount++;
          } else {
            await sync.delete();
            _removeSyncingOutgoing(sync.localId);
          }
          continue;
        }

        final label = await Label.findById(sync.localId);

        if (label == null) {
          await sync.delete();
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        final labelData = <String, dynamic>{
          'local_id': label.id,
          'name': label.name,
          'created_at': label.createdAt?.toIso8601String(),
          'updated_at': label.updatedAt?.toIso8601String(),
          cloudSyncCommittedAtField: FieldValue.serverTimestamp(),
        };

        final localId = sync.localId;
        final capturedSyncStartTime = syncStartTime;
        if (sync.remoteId != null) {
          batch.set(
            _labelsCollection.doc(sync.remoteId),
            labelData,
            SetOptions(merge: true),
          );
          postCommitActions.add(() async {
            final wasUnchanged = await sync.markSyncedIfUnchanged(
              capturedSyncStartTime,
            );
            if (wasUnchanged) {
              AppLogger.log(
                "[LABEL_SYNC] Updated remote label: ${sync.remoteId}",
              );
            } else {
              AppLogger.log(
                "[LABEL_SYNC] Label ${sync.localId} was modified during sync, triggering re-sync",
              );
              LabelSyncService().sync();
            }
            _removeSyncingOutgoing(localId);
          });
        } else {
          final stableId = label.syncId ?? const Uuid().v4();
          if (label.syncId != stableId) {
            label.syncId = stableId;
            await AppState.db.update(
              Label.model,
              {'sync_id': stableId},
              where: 'id = ?',
              whereArgs: [label.id],
            );
          }
          final newDocRef = _labelsCollection.doc(stableId);
          batch.set(newDocRef, labelData);
          await sync.claimRemoteId(newDocRef.id);
          postCommitActions.add(() async {
            final wasUnchanged = await sync.markSyncedIfUnchanged(
              capturedSyncStartTime,
            );
            if (wasUnchanged) {
              AppLogger.log(
                "[LABEL_SYNC] Created remote label: ${newDocRef.id}",
              );
            } else {
              AppLogger.log(
                "[LABEL_SYNC] Label ${sync.localId} was modified during sync, triggering re-sync",
              );
              LabelSyncService().sync();
            }
            _removeSyncingOutgoing(localId);
          });
        }

        batchCount++;

        if (batchCount >= 400) {
          await batch.commit();
          for (final action in postCommitActions) {
            await action();
          }
          postCommitActions.clear();
          batch = _firestore.batch();
          batchCount = 0;
        }
      } catch (e) {
        AppLogger.error("[LABEL_SYNC] Error syncing label ${sync.localId}: $e");
        _markSyncFailed(sync.localId);
        _removeSyncingOutgoing(sync.localId);
      }
    }

    if (batchCount > 0) {
      await batch.commit();
      for (final action in postCommitActions) {
        await action();
      }
    }
  }

  Future<void> _pushLocalChanges() async {
    final pendingSyncs = await LabelSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) return;
    await _pushLocalChangesWithPending(pendingSyncs);
  }

  Future<void> _pullRemoteChanges() async {
    await runRemotePullWithListenerLifecycle<void>(
      stopListener: () => _stopRemoteListener(cancelRetry: false),
      restoreListener: _startRemoteListener,
      recoveryDisposition: () {
        final checkpoint = AppState.labelCloudSyncCheckpoint;
        return checkpoint != null && !checkpoint.requiresBootstrap
            ? RemotePullRecoveryDisposition.none
            : RemotePullRecoveryDisposition.restartFull;
      },
      scheduleCachedResume: () {},
      scheduleFullPull: () {
        _pullRetry.schedule(() async {
          if (_initialized && currentUser != null && _canReceiveSync) {
            AppLogger.log(
              '[LABEL_SYNC] Retrying full label pull after Firestore failure',
            );
            await refresh();
          }
        });
      },
      pull: _performRemotePull,
    );
  }

  Future<void> _performRemotePull() async {
    syncStatus.value = const SyncProgress(SyncPhase.fetchingUpdates);
    final checkpointCommit = StagedCheckpoint<CloudSyncCheckpoint>(
      commit: (value) => AppState.labelCloudSyncCheckpoint = value,
    );

    final checkpoint = AppState.labelCloudSyncCheckpoint;
    final isBootstrap = checkpoint == null || checkpoint.requiresBootstrap;
    final bootstrapBoundary = isBootstrap
        ? await _captureBootstrapBoundary()
        : null;

    final Set<String> processedDocIds = {};
    CloudSyncCursor? committedCursor = isBootstrap
        ? bootstrapBoundary
        : checkpoint.cursor;
    DocumentSnapshot<Map<String, dynamic>>? lastDocument;
    var hasMore = true;

    while (hasMore) {
      Query<Map<String, dynamic>> query;
      if (isBootstrap) {
        query = _labelsCollection.orderBy(FieldPath.documentId).limit(100);
      } else {
        query = _labelsCollection
            .orderBy(cloudSyncCommittedAtField)
            .orderBy(FieldPath.documentId)
            .limit(100);
        if (lastDocument == null && checkpoint.cursor != null) {
          final cursor = checkpoint.cursor!;
          query = query.startAfter([cursor.timestamp, cursor.documentId]);
        }
      }

      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }

      final querySnapshot = await _getServerDocuments(
        query,
        operation: 'fetching a label page',
      );
      if (querySnapshot.docs.isEmpty) break;
      hasMore = querySnapshot.docs.length == 100;

      for (final docSnapshot in querySnapshot.docs) {
        final remoteData = docSnapshot.data();
        final remoteDocId = docSnapshot.id;

        if (!processedDocIds.add(remoteDocId)) {
          continue;
        }

        if (!isBootstrap) {
          final documentCursor = CloudSyncCursor.fromDocument(
            remoteData,
            remoteDocId,
          );
          if (documentCursor == null) {
            throw StateError(
              'Invalid $cloudSyncCommittedAtField on label $remoteDocId',
            );
          }
          committedCursor = committedCursor == null
              ? documentCursor
              : committedCursor.max(documentCursor);
        }

        final isDeleted =
            remoteData['deleted'] == true || remoteData['deleted'] == 1;
        final remoteName = remoteData['name'];
        if (!isDeleted &&
            (remoteName is! String ||
                !_hasValidRemoteDate(remoteData['created_at']) ||
                !_hasValidRemoteDate(remoteData['updated_at']))) {
          throw StateError('Malformed remote label $remoteDocId');
        }

        final existingSyncTrack = await LabelSyncTrack.getByRemoteId(
          remoteDocId,
        );
        final stableLabel = await Label.findBySyncId(remoteDocId);
        final localId = existingSyncTrack?.localId ?? stableLabel?.id;

        if (isDeleted) {
          if (localId != null) {
            _addSyncingIncoming(localId);
            try {
              await _handleRemoteDeletedLabelByRemoteId(remoteDocId);
            } finally {
              _removeSyncingIncoming(localId);
            }
          } else {
            await _handleRemoteDeletedLabelByRemoteId(remoteDocId);
          }
          continue;
        }

        if (existingSyncTrack != null &&
            (existingSyncTrack.status == LabelSyncStatus.pending ||
                existingSyncTrack.status == LabelSyncStatus.failed)) {
          AppLogger.log(
            "[LABEL_SYNC] Skipping pull for doc $remoteDocId - has pending local changes",
          );
          continue;
        }

        final localLabel = localId == null
            ? null
            : await Label.findById(localId);
        if (localLabel != null && remoteData['updated_at'] != null) {
          final localUpdatedAt = localLabel.updatedAt;
          final remoteUpdatedAt = DateTime.parse(
            remoteData['updated_at'] as String,
          );

          if (localUpdatedAt != null &&
              (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                  remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt))) {
            continue;
          }
        }

        if (localId != null) {
          _addSyncingIncoming(localId);
        }
        try {
          await _patchRemoteLabel(remoteData, remoteDocId);
          AppLogger.log(
            "[LABEL_SYNC] Patched local label from remote doc: $remoteDocId",
          );
        } finally {
          if (localId != null) {
            _removeSyncingIncoming(localId);
          }
        }
      }

      lastDocument = querySnapshot.docs.last;
    }

    await Label.fixLabels();

    checkpointCommit.stage(
      CloudSyncCheckpoint(bootstrapped: true, cursor: committedCursor),
    );
    checkpointCommit.commit();
  }

  Future<CloudSyncCursor?> _captureBootstrapBoundary() async {
    final snapshot = await _getServerDocuments(
      _labelsCollection
          .orderBy(cloudSyncCommittedAtField, descending: true)
          .orderBy(FieldPath.documentId, descending: true)
          .limit(1),
      operation: 'capturing the label bootstrap boundary',
    );
    if (snapshot.docs.isEmpty) return null;

    final document = snapshot.docs.single;
    final cursor = CloudSyncCursor.fromDocument(document.data(), document.id);
    if (cursor == null) {
      throw StateError(
        'Invalid $cloudSyncCommittedAtField on label ${document.id}',
      );
    }
    return cursor;
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _getServerDocuments(
    Query<Map<String, dynamic>> query, {
    required String operation,
  }) async {
    try {
      final snapshot = await retryTransientFirestoreOperation(
        () => query.get(const GetOptions(source: Source.server)),
        onRetry: (error, nextAttempt, delay) {
          AppLogger.log(
            '[LABEL_SYNC] Firestore $operation failed transiently; '
            'retrying attempt $nextAttempt in ${delay.inMilliseconds}ms: '
            '$error',
          );
        },
      );
      _pullRetry.succeeded();
      return snapshot;
    } catch (error) {
      throw FirestoreDocumentFetchException(
        resource: 'label documents',
        operation: operation,
        cause: error,
      );
    }
  }

  Future<void> _handleRemoteDeletedLabelByRemoteId(String remoteDocId) async {
    final syncTrack = await LabelSyncTrack.getByRemoteId(remoteDocId);
    final label =
        await Label.findBySyncId(remoteDocId) ??
        (syncTrack == null ? null : await Label.findById(syncTrack.localId));
    if (label != null) {
      await label.delete(sync: false, origin: ModelChangeOrigin.remoteSync);
    }
    await syncTrack?.delete();
    AppLogger.log(
      "[LABEL_SYNC] Deleted local label from remote deletion by remoteId: $remoteDocId",
    );
  }

  Future<void> _patchRemoteLabel(
    Map<String, dynamic> remoteData,
    String remoteDocId,
  ) => _labelApplySerializer.run(
    remoteDocId,
    () => _patchRemoteLabelInner(remoteData, remoteDocId),
  );

  Future<void> _patchRemoteLabelInner(
    Map<String, dynamic> remoteData,
    String remoteDocId,
  ) async {
    final isDeleted =
        remoteData['deleted'] == true || remoteData['deleted'] == 1;
    if (isDeleted) {
      await _handleRemoteDeletedLabelByRemoteId(remoteDocId);
      return;
    }

    // First, try to find existing label by remoteId (sync track)
    LabelSyncTrack? existingSyncTrack = await LabelSyncTrack.getByRemoteId(
      remoteDocId,
    );
    Label? label;

    if (existingSyncTrack != null) {
      label = await Label.findById(existingSyncTrack.localId);
    }

    label ??= await Label.findBySyncId(remoteDocId);

    // Fallback: find by name. If found, also link the sync track so
    // future syncs won't create a duplicate for this remote doc.
    if (label == null) {
      label = await Label.findByName(remoteData['name'] as String);
      if (label != null && existingSyncTrack == null) {
        // Link this existing local label to the remote doc
        existingSyncTrack = await LabelSyncTrack.getByLocalId(label.id!);
      }
    }

    if (label == null) {
      // Create new label - let SQLite auto-generate the ID
      label = Label(
        name: remoteData['name'] as String,
        syncId: remoteDocId,
        createdAt: remoteData['created_at'] != null
            ? DateTime.parse(remoteData['created_at'])
            : null,
        updatedAt: remoteData['updated_at'] != null
            ? DateTime.parse(remoteData['updated_at'])
            : null,
      );

      // Save without triggering sync (we're pulling from remote)
      final newId = await label.save(
        sync: false,
        origin: ModelChangeOrigin.remoteSync,
      );
      label.id = newId;
    } else {
      // Update existing label
      label.name = remoteData['name'] as String;
      label.syncId = remoteDocId;
      label.updatedAt = remoteData['updated_at'] != null
          ? DateTime.parse(remoteData['updated_at'])
          : DateTime.now();

      await AppState.db.update(
        Label.model,
        label.toJson(),
        where: "id = ?",
        whereArgs: [label.id],
      );
      label.notifyWithOrigin("updated", ModelChangeOrigin.remoteSync);
    }

    // Update or create sync track using the label's actual local ID
    LabelSyncTrack? syncTrack =
        existingSyncTrack ?? await LabelSyncTrack.getByLocalId(label.id!);
    if (syncTrack == null) {
      syncTrack = LabelSyncTrack(
        localId: label.id!,
        remoteId: remoteDocId,
        action: LabelSyncAction.upload,
        status: LabelSyncStatus.synced,
      );
    } else {
      if (syncTrack.remoteId != remoteDocId) {
        await syncTrack.claimRemoteId(remoteDocId);
      }
      syncTrack.status = LabelSyncStatus.synced;
    }
    await syncTrack.save();

    AppLogger.log(
      "[LABEL_SYNC] Patched label ${label.id} from remote doc $remoteDocId",
    );
  }

  /// Queue a label for sync when created or updated
  Future<void> queueSync(Label label) async {
    if (currentUser == null) return;

    LabelSyncTrack? existing = await LabelSyncTrack.getByLocalId(label.id!);

    if (existing != null) {
      await existing.setAction(LabelSyncAction.upload);
    } else {
      final syncTrack = LabelSyncTrack(
        localId: label.id!,
        action: LabelSyncAction.upload,
        status: LabelSyncStatus.pending,
      );
      await syncTrack.save();
    }

    AppLogger.log("[LABEL_SYNC] Queued label ${label.id} for sync");
    sync();
  }

  /// Queue a label for deletion
  Future<void> queueDelete(int labelId) async {
    if (currentUser == null) return;

    LabelSyncTrack? existing = await LabelSyncTrack.getByLocalId(labelId);

    if (existing != null) {
      await existing.setAction(LabelSyncAction.delete);
    } else {
      final syncTrack = LabelSyncTrack(
        localId: labelId,
        action: LabelSyncAction.delete,
        status: LabelSyncStatus.pending,
      );
      await syncTrack.save();
    }

    AppLogger.log("[LABEL_SYNC] Queued label $labelId for deletion");
    sync();
  }
}
