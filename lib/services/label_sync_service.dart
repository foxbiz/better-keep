import 'external_sync/firebase_sync_migration.dart';

import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/services/external_sync/firebase_sync_version.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_version.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';

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

class LabelSyncService {
  @visibleForTesting
  static Future<void> Function()? refreshOperationOverride;

  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  StreamSubscription<User?>? _userStreamSubscription;
  bool _initialized = false;
  int _sessionGeneration = 0;
  int _cloudGeneration = 0;
  final _initializationGate = AsyncInitializationGate();
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
    if (!cloudOperationIsCurrent()) return;
    syncFailed.value = {...syncFailed.value, labelId};
  }

  void _clearSyncFailed(int labelId) {
    if (!cloudOperationIsCurrent()) return;
    syncFailed.value = {...syncFailed.value}..remove(labelId);
  }

  void _addSyncingOutgoing(int labelId) {
    if (!cloudOperationIsCurrent()) return;
    syncingOutgoing.value = {...syncingOutgoing.value, labelId};
    _clearSyncFailed(labelId);
  }

  void _removeSyncingOutgoing(int labelId) {
    if (!cloudOperationIsCurrent()) return;
    syncingOutgoing.value = {...syncingOutgoing.value}..remove(labelId);
  }

  void _addSyncingIncoming(int labelId) {
    if (!cloudOperationIsCurrent()) return;
    syncingIncoming.value = {...syncingIncoming.value, labelId};
    _clearSyncFailed(labelId);
  }

  void _removeSyncingIncoming(int labelId) {
    if (!cloudOperationIsCurrent()) return;
    syncingIncoming.value = {...syncingIncoming.value}..remove(labelId);
  }

  bool get _isReviewSession =>
      FirebaseBackend.isConfigured &&
      ReviewAccess.isAuthorizedSessionFor(currentUser);

  String get _incomingSyncState =>
      'backendConfigured=${FirebaseBackend.isConfigured}, '
      'cloud=${AuthService.cloudRecovery.state.value.name}, '
      'provider=${FirebaseSyncPreference.instance.selectedProvider ?? 'unconfirmed'}, '
      'firebaseAllowed=${FirebaseBackend.isConfigured && FirebaseSyncPreference.instance.allowsSync(currentUser?.uid)}, '
      'cryptoReady=${E2EEService.instance.isCryptoReady}, '
      'sessionInvalid=${AuthService.sessionInvalid.value}, review=$_isReviewSession';

  String get _pushSyncState =>
      '$_incomingSyncState, paid=${PlanService.instance.entitlements.realtimeCloudSync}';

  /// Check if we can receive/download sync (incoming):
  /// - Not an authorized review session
  /// - Session must be valid
  /// Note: Pro subscription NOT required for receiving sync
  bool get _canReceiveSync {
    // If session is invalid (user deleted/disabled), disable all sync
    if (!AuthService.canSyncCloud ||
        !FirebaseSyncPreference.instance.allowsSync(currentUser?.uid)) {
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
    if (!PlanService.instance.entitlements.realtimeCloudSync) {
      return false;
    }
    return true;
  }

  /// Track the previous subscription state to detect upgrades
  bool _wasPreviouslyPaid = false;

  bool Function() _captureSession({bool cloud = true}) {
    final current = AuthService.captureSession();
    final generation = _sessionGeneration;
    final cloudGeneration = _cloudGeneration;
    return () =>
        generation == _sessionGeneration &&
        (!cloud || cloudGeneration == _cloudGeneration) &&
        current();
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
      AppLogger.error(
        '[LABEL_SYNC] Background operation deferred',
        error,
        stack,
      );
    },
  );

  bool _lastFirebaseSyncAllowed = false;
  void _onSyncSelectionChange() {
    final allowed = FirebaseSyncPreference.instance.allowsSync(
      currentUser?.uid,
    );
    if (allowed == _lastFirebaseSyncAllowed) return;
    _lastFirebaseSyncAllowed = allowed;
    if (!_canReceiveSync) {
      _onCloudStateChange();
      return;
    }
    unawaited(
      _background(() async {
        await init();
        requireCloudOperation();
        await resumeCloudSync();
      })(),
    );
  }

  void _onCloudStateChange() {
    if (AuthService.canSyncCloud &&
        FirebaseSyncPreference.instance.allowsSync(currentUser?.uid)) {
      return;
    }
    _cloudGeneration++;
    _syncTimer?.cancel();
    _pullRetry.cancel();
    _listenerRetry.cancel();
    unawaited(_stopRemoteListener());
    isSyncing.value = false;
    syncingOutgoing.value = {};
    syncingIncoming.value = {};
    syncStatus.value = SyncProgress.idle;
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
    _lastFirebaseSyncAllowed = FirebaseSyncPreference.instance.allowsSync(
      currentUser?.uid,
    );
    FirebaseSyncPreference.instance.addListener(_onSyncSelectionChange);

    AppLogger.log("[LABEL_SYNC] LabelSyncService initialized");

    final e2ee = E2EEService.instance;
    _lastKnownCryptoReady = e2ee.isCryptoReady;

    // Initialize with current subscription state
    _wasPreviouslyPaid = PlanService.instance.entitlements.realtimeCloudSync;

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
          unawaited(_background(refresh)());
        } else {
          // Push sync requires Pro, but start listener for incoming sync
          if (_canPushSync) {
            unawaited(_background(_sync)());
          }
          await _startRemoteListener();
        }
      } else {
        AppLogger.log(
          "[LABEL_SYNC] Deferring sync - E2EE not ready (status: ${E2EEService.instance.status.value})",
        );
      }
    }

    requireCloudOperation();
    // Listen for E2EE status changes to trigger sync when ready
    e2ee.status.addListener(_onE2EEReadinessChange);
    e2ee.deviceManager.hasUMK.addListener(_onE2EEReadinessChange);

    _userStreamSubscription = AuthService.userStream.listen((user) {
      if (!cloudOperationIsCurrent()) return;
      unawaited(
        _background(() async {
          if (user != null) {
            // Review sessions are intentionally local-only.
            if (_isReviewSession) {
              AppLogger.log("[LABEL_SYNC] Skipping sync - review session");
              return;
            }
            AppState.lastLabelSynced = null;
            // Ensure system labels exist immediately on login
            // (before remote sync which may take time or fail)
            await Label.fixLabels();
            requireCloudOperation();
            // Only sync if E2EE is ready - otherwise wait for E2EE status change
            if (E2EEService.instance.isCryptoReady) {
              await _startRemoteListener();
              unawaited(_background(refresh)());
            } else {
              AppLogger.log(
                "[LABEL_SYNC] Deferring sync on login - E2EE not ready (status: ${E2EEService.instance.status.value})",
              );
            }
          } else {
            await _stopRemoteListener();
          }
        }, cloud: false)(),
      );
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
      unawaited(
        Future<void>.microtask(
          _background(() async {
            await _stopRemoteListener();
            requireCloudOperation();
            await refresh();
          }),
        ),
      );
    } else if (!isNowReady && wasReady) {
      unawaited(_stopRemoteListener());
    }
  }

  /// Called when subscription status changes
  void _onSubscriptionChange() {
    final isPaidNow = PlanService.instance.entitlements.realtimeCloudSync;
    AppLogger.log(
      "[LABEL_SYNC]Subscription changed - isPaid: $isPaidNow (was: $_wasPreviouslyPaid)",
    );

    // User just upgraded to Pro
    if (isPaidNow && !_wasPreviouslyPaid) {
      AppLogger.log("[LABEL_SYNC]User upgraded to Pro, enabling full sync");
      _wasPreviouslyPaid = true;

      if (currentUser != null) {
        unawaited(_background(_startRemoteListener)());
        unawaited(_background(refresh)());
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
  Future<void> _startRemoteListener() {
    final current = _captureSession();
    if (!current() || !cloudOperationIsCurrent()) return Future.value();
    return runCloudOperation(current, _startRemoteListenerCurrent);
  }

  Future<void> _startRemoteListenerCurrent() async {
    await _stopRemoteListener(cancelRetry: false);
    requireCloudOperation();
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
                  if (!cloudOperationIsCurrent()) return;
                  if (isCloudConnectionFailure(error)) {
                    AuthService.cloudRecovery.connectionLost();
                  }
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
            AppLogger.error('LabelSync: Remote listener error', error);
            _initialHydration.failAttempt(hydrationGeneration);
            unawaited(
              _background(
                () => _restartRemoteListenerAfterFailure(hydrationGeneration),
              )(),
            );
          },
        );

    AppLogger.log("[LABEL_SYNC] Started real-time remote listener");
  }

  Future<void> _restartRemoteListenerAfterFailure(int generation) async {
    if (!_initialHydration.isCurrent(generation)) return;
    await _stopRemoteListener(cancelRetry: false);
    requireCloudOperation();
    if (!_canReceiveSync) return;
    _listenerRetry.schedule(
      _background(() async {
        if (_initialized && currentUser != null && _canReceiveSync) {
          AppLogger.log(
            '[LABEL_SYNC] Restarting remote listener after failure',
          );
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
        'LabelSync: Error stopping remote listener (safe to ignore)',
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
    FirebaseSyncPreference.instance.removeListener(_onSyncSelectionChange);
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
    _initializationGate.reset();
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
      AppLogger.log("[LABEL_SYNC] Skipping sync - $_pushSyncState");
      return;
    }

    if (now) {
      _syncTimer = null;
      await _sync();
      return;
    }

    _syncTimer = Timer(const Duration(seconds: 5), _background(_sync));
  }

  Future<void> resumeCloudSync() async {
    if (!_canReceiveSync) return;
    await _startRemoteListener();
    await refresh();
  }

  Future<void> refresh() async {
    await refreshWithOutcome();
  }

  Future<SyncRefreshOutcome> refreshWithOutcome() {
    if (refreshOperationOverride != null) {
      return _syncOperationSerializer.run(_syncOperationKey, _refreshUnlocked);
    }
    final current = _captureSession();
    return _syncOperationSerializer.run(_syncOperationKey, () async {
      if (!current()) return SyncRefreshOutcome.deferred;
      return runCloudOperation(current, _refreshUnlocked);
    });
  }

  Future<SyncRefreshOutcome> _refreshUnlocked() async {
    final override = refreshOperationOverride;
    if (override != null) {
      await override();
      return SyncRefreshOutcome.complete;
    }
    if (currentUser == null) return SyncRefreshOutcome.deferred;

    if (!_canReceiveSync) {
      AppLogger.log('[LABEL_SYNC] Skipping refresh - $_incomingSyncState');
      return SyncRefreshOutcome.deferred;
    }

    await Future.microtask(() {});
    if (currentUser == null || !_canReceiveSync) {
      AppLogger.log('[LABEL_SYNC] Skipping refresh - $_incomingSyncState');
      return SyncRefreshOutcome.deferred;
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
        AppLogger.log("[LABEL_SYNC] Skipping push - $_pushSyncState");
      }
      if (!_canReceiveSync) {
        syncStatus.value = SyncProgress.idle;
        AppLogger.log(
          '[LABEL_SYNC] Deferring pull - incoming sync became unavailable',
        );
        return SyncRefreshOutcome.deferred;
      }
      // Always pull remote changes (available to all users)
      await _pullRemoteChanges();

      requireCloudOperation();
      final uploadRestricted =
          syncFailed.value.isEmpty &&
          !PlanService.instance.entitlements.realtimeCloudSync &&
          await LabelSyncTrack.count(pending: true) > 0;
      requireCloudOperation();
      if (uploadRestricted) {
        syncStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
        return SyncRefreshOutcome.uploadRestricted;
      }
      syncStatus.value = syncFailed.value.isEmpty
          ? const SyncProgress(SyncPhase.complete)
          : const SyncProgress(SyncPhase.failed);
      return syncFailed.value.isEmpty
          ? SyncRefreshOutcome.complete
          : SyncRefreshOutcome.failed;
    } on CloudOperationCancelled {
      return SyncRefreshOutcome.deferred;
    } catch (error, stack) {
      if (!cloudOperationIsCurrent()) return SyncRefreshOutcome.deferred;
      if (isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
        syncStatus.value = SyncProgress.idle;
        return SyncRefreshOutcome.unavailable;
      }
      syncStatus.value = const SyncProgress(SyncPhase.failed);
      AppLogger.error('LabelSync: Refresh failed', error, stack);
      return SyncRefreshOutcome.failed;
    } finally {
      if (cloudOperationIsCurrent()) {
        isSyncing.value = false;
        syncingOutgoing.value = {};
        Future.delayed(const Duration(seconds: 2), () {
          if (cloudOperationIsCurrent() && !isSyncing.value) {
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
      AppLogger.log("[LABEL_SYNC] Skipping _sync - $_pushSyncState");
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
      requireCloudOperation();

      syncStatus.value = const SyncProgress(SyncPhase.complete);
      AppLogger.log("[LABEL_SYNC] Sync Complete");
    } catch (e, stack) {
      if (!cloudOperationIsCurrent() || e is CloudOperationCancelled) return;
      if (isCloudConnectionFailure(e)) {
        AuthService.cloudRecovery.connectionLost();
        syncStatus.value = SyncProgress.idle;
      } else {
        syncStatus.value = const SyncProgress(SyncPhase.failed);
      }
      AppLogger.error('LabelSync: Sync Failed', e, stack);
    } finally {
      if (cloudOperationIsCurrent()) {
        isSyncing.value = false;
        syncingOutgoing.value = {};
        Future.delayed(const Duration(seconds: 2), () {
          if (cloudOperationIsCurrent() && !isSyncing.value) {
            syncStatus.value = SyncProgress.idle;
          }
        });
      }
    }
  }

  Future<void> _pushLocalChangesWithPending(
    List<LabelSyncTrack> pendingSyncs,
  ) async {
    if (pendingSyncs.isEmpty) return;
    syncStatus.value = const SyncProgress(SyncPhase.savingChanges);

    Object? pushFailure;
    for (final sync in pendingSyncs) {
      final started = DateTime.now();
      _addSyncingOutgoing(sync.localId);
      try {
        final captured = await AppState.db.transaction((txn) async {
          requireCloudOperation();
          final rows = await txn.query(
            Label.model,
            where: 'id = ?',
            whereArgs: [sync.localId],
          );
          final row = rows.isEmpty ? null : rows.single;
          final remoteId = sync.remoteId ?? row?['sync_id'] as String?;
          if (remoteId == null) return null;
          final version =
              await SyncMutationJournal.current(
                txn,
                SyncEntityKind.label,
                remoteId,
              ) ??
              FirebaseSyncVersion.read(SyncEntityKind.label, remoteId, {
                ...?row,
                'updated_at':
                    // This is the originating device's local database, not
                    // an ambiguous remote wall clock. Normalize before binding.
                    DateTime.tryParse(row?['updated_at']?.toString() ?? '')
                        ?.toUtc()
                        .toIso8601String() ??
                    sync.updatedAt?.toUtc().toIso8601String(),
                if (row == null) 'deleted': true,
              });
          if (version.deleted != (row == null)) {
            throw StateError('Label version does not match content');
          }
          return (row: row, version: version);
        });
        if (captured == null) {
          await sync.deleteIfUnchanged();
          continue;
        }
        final version = captured.version;
        final row = captured.row;
        final payload = FirebaseSyncVersion.bind({
          'local_id': sync.localId,
          if (row != null) ...{
            'name': row['name'],
            'is_system': row['is_system'] ?? 0,
            'created_at': DateTime.tryParse(row['created_at']?.toString() ?? '')
                ?.toUtc()
                .toIso8601String(),
          },
        }, version);
        payload[cloudSyncCommittedAtField] = FieldValue.serverTimestamp();
        if (version.deleted) {
          payload['deleted_at'] = FieldValue.serverTimestamp();
        }
        if (sync.remoteId == null) await sync.claimRemoteId(version.entityId);
        final winner = await FirebaseSyncMigration.retry(
          _labelsCollection.doc(version.entityId),
          SyncEntityKind.label,
          requireCloudOperation,
          () => _firestore.runTransaction<Map<String, dynamic>?>((txn) async {
            requireCloudOperation();
            final ref = _labelsCollection.doc(version.entityId);
            final snapshot = await txn.get(ref);
            if (snapshot.metadata.isFromCache ||
                snapshot.metadata.hasPendingWrites) {
              throw const CloudVerificationUnavailable();
            }
            requireCloudOperation();
            final data = snapshot.data();
            if (data != null) {
              final current = FirebaseSyncVersion.read(
                SyncEntityKind.label,
                version.entityId,
                data,
              );
              final comparison = current.compareTo(version);
              if (comparison > 0) return data;
              if (comparison == 0) return null;
            }
            txn.set(ref, payload);
            return null;
          }, timeout: const Duration(seconds: 10)),
        );
        requireCloudOperation();
        if (winner != null) {
          await _patchRemoteLabel(winner, version.entityId);
        } else if (version.deleted) {
          await sync.deleteIfUnchanged();
        } else if (!await sync.markSyncedIfUnchanged(started)) {
          LabelSyncService().sync();
        }
      } catch (error) {
        if (error is CloudOperationCancelled ||
            isCloudConnectionFailure(error)) {
          rethrow;
        }
        pushFailure = error;
        AppLogger.error(
          '[LABEL_SYNC] Could not publish label ${sync.localId}',
          error,
        );
        _markSyncFailed(sync.localId);
      } finally {
        _removeSyncingOutgoing(sync.localId);
      }
    }
    if (pushFailure != null) throw pushFailure;
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
        if (_canReceiveSync) {
          _pullRetry.schedule(
            _background(() async {
              if (_initialized && currentUser != null && _canReceiveSync) {
                AppLogger.log(
                  '[LABEL_SYNC] Retrying full label pull after Firestore failure',
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

    checkpointCommit.stage(
      CloudSyncCheckpoint(bootstrapped: true, cursor: committedCursor),
    );
    requireCloudOperation();
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
        () {
          requireCloudOperation();
          return query
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 10));
        },
        shouldRetry: (error) =>
            isTransientFirestoreFailure(error) &&
            !isCloudConnectionFailure(error),
        onRetry: (error, nextAttempt, delay) {
          AppLogger.log(
            '[LABEL_SYNC] Firestore $operation failed transiently; '
            'retrying attempt $nextAttempt in ${delay.inMilliseconds}ms: '
            '$error',
          );
        },
      );
      requireCloudOperation();
      if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
        throw const CloudVerificationUnavailable();
      }
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

  Future<void> _patchRemoteLabel(Map<String, dynamic> data, String remoteId) =>
      _labelApplySerializer.run(
        remoteId,
        () => _applyRemoteLabel(data, remoteId),
      );

  Future<void> _applyRemoteLabel(
    Map<String, dynamic> data,
    String remoteId,
  ) async {
    data = await FirebaseSyncMigration.resolve(
      _labelsCollection.doc(remoteId),
      SyncEntityKind.label,
      data,
      requireCloudOperation,
    );
    final version = FirebaseSyncVersion.read(
      SyncEntityKind.label,
      remoteId,
      data,
    );
    Label? changed;
    String? event;
    await AppState.db.transaction((txn) async {
      requireCloudOperation();
      final current = await SyncMutationJournal.current(
        txn,
        SyncEntityKind.label,
        remoteId,
      );
      if (current != null && version.compareTo(current) <= 0) return;
      final rows = await txn.query(
        Label.model,
        where: 'sync_id = ?',
        whereArgs: [remoteId],
      );
      var tracks = await txn.query(
        LabelSyncTrack.model,
        where: 'remote_id = ?',
        whereArgs: [remoteId],
      );
      if (tracks.isEmpty && rows.isNotEmpty) {
        tracks = await txn.query(
          LabelSyncTrack.model,
          where: 'local_id = ? AND (remote_id IS NULL OR remote_id = ?)',
          whereArgs: [rows.single['id'], remoteId],
        );
      }
      // Stable identities are never reassigned merely because names match.
      var id = rows.isNotEmpty
          ? rows.single['id'] as int
          : tracks.isNotEmpty
          ? tracks.single['local_id'] as int
          : null;
      if (rows.isNotEmpty && current == null) {
        final time = DateTime.tryParse(
          rows.single['updated_at']?.toString() ?? '',
        );
        if (time != null &&
            time.toUtc().microsecondsSinceEpoch > version.modifiedAtMicros) {
          return;
        }
      }
      await SyncMutationJournal.withoutCapture(txn, () async {
        if (version.deleted) {
          if (rows.isNotEmpty) {
            changed = Label.fromJson(rows.single);
            event = 'deleted';
            await txn.delete(
              Label.model,
              where: 'sync_id = ?',
              whereArgs: [remoteId],
            );
          }
          await txn.delete(
            LabelSyncTrack.model,
            where: 'remote_id = ? OR (local_id = ? AND remote_id IS NULL)',
            whereArgs: [remoteId, id],
          );
        } else {
          final row = <String, Object?>{
            'sync_id': remoteId,
            'name': data['name'],
            'is_system': data['is_system'] == 1 ? 1 : 0,
            'created_at': FirebaseSyncVersion.timestamp(data['created_at'])
                ?.toIso8601String(),
            'updated_at': DateTime.fromMicrosecondsSinceEpoch(
              version.modifiedAtMicros,
              isUtc: true,
            ).toIso8601String(),
          };
          if (data['name'] is! String || row['created_at'] == null) {
            throw const FormatException('Invalid label payload');
          }
          if (rows.isEmpty) {
            // Let SQLite allocate an ID if the historical track's ID is occupied.
            if (id != null &&
                (await txn.query(
                  Label.model,
                  where: 'id = ?',
                  whereArgs: [id],
                )).isNotEmpty) {
              id = null;
            }
            id = await txn.insert(Label.model, {'id': ?id, ...row});
            event = 'created';
          } else {
            await txn.update(
              Label.model,
              row,
              where: 'id = ?',
              whereArgs: [id],
            );
            event = 'updated';
          }
          changed = Label.fromJson({'id': id, ...row});
          final track = tracks.isEmpty ? null : tracks.single;
          final ack = <String, Object?>{
            'local_id': id,
            'remote_id': remoteId,
            'action': LabelSyncAction.upload.name,
            'status': LabelSyncStatus.synced.name,
            'created_at': track?['created_at'] ?? row['updated_at'],
            'updated_at': row['updated_at'],
          };
          if (track == null) {
            await txn.insert(LabelSyncTrack.model, ack);
          } else {
            await txn.update(
              LabelSyncTrack.model,
              ack,
              where: 'id = ?',
              whereArgs: [track['id']],
            );
          }
        }
        await SyncMutationJournal.received(
          txn,
          version,
          id?.toString() ?? current?.localId ?? '',
        );
      });
      requireCloudOperation();
    });
    if (changed != null && cloudOperationIsCurrent()) {
      changed!.notifyWithOrigin(event!, ModelChangeOrigin.remoteSync);
    }
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
      requireCloudOperation();
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
      requireCloudOperation();
      await syncTrack.save();
    }

    AppLogger.log("[LABEL_SYNC] Queued label $labelId for deletion");
    sync();
  }
}
