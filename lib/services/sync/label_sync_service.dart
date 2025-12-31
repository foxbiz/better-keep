import 'dart:async';
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/sync/label_sync_track.dart';
import 'package:better_keep/services/auth/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:better_keep/config.dart' show demoAccountEmail;

class LabelSyncService {
  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  StreamSubscription<User?>? _userStreamSubscription;
  bool _initialized = false;
  LabelSyncService._internal();

  factory LabelSyncService() => _instance;

  static final LabelSyncService _instance = LabelSyncService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: DefaultFirebaseOptions.databaseId,
  );

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<String> statusMessage = ValueNotifier("");

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

  /// Check if the current user is the demo account (for Google Play review testing).
  bool get _isDemoAccount {
    final email = currentUser?.email;
    return email != null &&
        email.toLowerCase() == demoAccountEmail.toLowerCase();
  }

  /// Check if we can receive/download sync (incoming):
  /// - Not a demo account
  /// - Session must be valid
  /// Note: Pro subscription NOT required for receiving sync
  bool get _canReceiveSync {
    // If session is invalid (user deleted/disabled), disable all sync
    if (AuthService.sessionInvalid.value) {
      return false;
    }

    if (_isDemoAccount) {
      return false;
    }
    return true;
  }

  /// Check if we can push/upload sync (outgoing):
  /// - Must have Pro subscription (cloud sync upload is a Pro feature)
  /// - Not a demo account
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

  void init() {
    // Prevent duplicate initialization and listener registration
    if (_initialized) return;
    _initialized = true;

    AppLogger.log("[LABEL_SYNC] LabelSyncService initialized");

    // Initialize with current subscription state
    _wasPreviouslyPaid = PlanService.instance.isPaid;

    // Listen for subscription changes
    PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);

    if (currentUser != null) {
      // Skip sync for demo accounts
      if (_isDemoAccount) {
        AppLogger.log("[LABEL_SYNC]Skipping sync - demo account");
        return;
      }
      // Only start sync if E2EE is ready - otherwise wait for E2EE status change listener
      if (E2EEService.instance.isReady) {
        // Push sync requires Pro, but start listener for incoming sync
        if (_canPushSync) {
          _sync();
        }
        _startRemoteListener();
      } else {
        AppLogger.log(
          "[LABEL_SYNC] Deferring sync - E2EE not ready (status: ${E2EEService.instance.status.value})",
        );
      }
    }

    // Listen for E2EE status changes to trigger sync when ready
    E2EEService.instance.status.addListener(_onE2EEStatusChange);

    _userStreamSubscription = AuthService.userStream.listen((user) {
      if (user != null) {
        // Skip sync for demo accounts
        if (_isDemoAccount) {
          AppLogger.log("[LABEL_SYNC]Skipping sync - demo account");
          return;
        }
        AppState.lastLabelSynced = null;
        // Only sync if E2EE is ready - otherwise wait for E2EE status change
        if (E2EEService.instance.isReady) {
          refresh();
          _startRemoteListener();
        } else {
          AppLogger.log(
            "[LABEL_SYNC] Deferring sync on login - E2EE not ready (status: ${E2EEService.instance.status.value})",
          );
        }
      } else {
        _stopRemoteListener();
      }
    });
  }

  /// Track last known E2EE status to detect transitions
  E2EEStatus? _lastKnownE2EEStatus;

  /// Called when E2EE status changes - trigger sync when E2EE becomes ready
  void _onE2EEStatusChange() {
    final status = E2EEService.instance.status.value;
    final previousStatus = _lastKnownE2EEStatus;
    _lastKnownE2EEStatus = status;

    AppLogger.log(
      "[LABEL_SYNC] E2EE status changed from $previousStatus to $status",
    );

    // Skip sync for demo accounts
    if (_isDemoAccount) {
      AppLogger.log("[LABEL_SYNC] Demo account detected, skipping sync");
      return;
    }

    // Check if we're transitioning TO a ready state from a non-ready state
    final isNowReady =
        status == E2EEStatus.ready ||
        status == E2EEStatus.verifyingInBackground;
    final wasReady =
        previousStatus == E2EEStatus.ready ||
        previousStatus == E2EEStatus.verifyingInBackground;

    // Trigger sync when E2EE becomes ready
    if (isNowReady && !wasReady && currentUser != null) {
      AppLogger.log("[LABEL_SYNC] E2EE just became ready, triggering sync");
      Future.microtask(() async {
        AppState.lastLabelSynced = null;
        _stopRemoteListener();
        _startRemoteListener();
        await refresh();
      });
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
        refresh();
        _startRemoteListener();
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
  void _startRemoteListener() {
    _stopRemoteListener();
    if (currentUser == null) return;

    DateTime? lastSynced = AppState.lastLabelSynced;
    Query<Map<String, dynamic>> query = _labelsCollection;
    if (lastSynced != null) {
      query = query.where(
        'updated_at',
        isGreaterThan: lastSynced.toIso8601String(),
      );
    }

    _remoteListener = query.snapshots().listen(
      (snapshot) async {
        if (snapshot.docChanges.isEmpty) return;

        final changes = snapshot.docChanges.where(
          (change) =>
              change.type == DocumentChangeType.modified ||
              change.type == DocumentChangeType.added,
        );

        if (changes.isEmpty) return;

        AppLogger.log(
          "[LABEL_SYNC] Received ${changes.length} remote changes via real-time listener",
        );

        final Set<String> processedIds = {};

        for (final change in changes) {
          final remoteData = change.doc.data();
          if (remoteData == null) {
            AppLogger.log("[LABEL_SYNC] Remote data is null, skipping");
            continue;
          }

          final remoteDocId = change.doc.id;
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
              remoteData['deleted'] == true || remoteData['deleted'] == 1;

          // Find existing sync track by remoteId
          final existingSyncTrack = await LabelSyncTrack.getByRemoteId(
            remoteDocId,
          );
          final localId = existingSyncTrack?.localId;

          if (isDeleted) {
            AppLogger.log(
              "[LABEL_SYNC] Label doc $remoteDocId is deleted, handling deletion",
            );
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
              "[LABEL_SYNC] Skipping real-time update for doc $remoteDocId - has pending local changes",
            );
            continue;
          }

          Label? localLabel;
          if (localId != null) {
            localLabel = await Label.findById(localId);
          }

          if (localLabel != null && remoteData['updated_at'] != null) {
            final localUpdatedAt = localLabel.updatedAt;
            final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

            if (localUpdatedAt != null &&
                (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                    remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt))) {
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

        AppState.lastLabelSynced = DateTime.now();
      },
      onError: (error) {
        AppLogger.error('LabelSync: Remote listener error', error);
      },
    );

    AppLogger.log("[LABEL_SYNC] Started real-time remote listener");
  }

  void _stopRemoteListener() {
    try {
      _remoteListener?.cancel();
    } catch (e) {
      // Ignore errors when cancelling listener that wasn't fully initialized
      AppLogger.error(
        'LabelSync: Error stopping remote listener (safe to ignore)',
        e,
      );
    }
    _remoteListener = null;
  }

  /// Dispose of all listeners and subscriptions.
  /// Call this when the app is shutting down or user logs out.
  void dispose() {
    _stopRemoteListener();
    _syncTimer?.cancel();
    _syncTimer = null;
    _userStreamSubscription?.cancel();
    _userStreamSubscription = null;
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    E2EEService.instance.status.removeListener(_onE2EEStatusChange);
    _initialized = false;
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

  Future<void> refresh() async {
    if (isSyncing.value || currentUser == null) return;

    // Don't sync if demo account
    if (_isDemoAccount) {
      AppLogger.log("[LABEL_SYNC]Skipping refresh - demo account");
      return;
    }

    await Future.microtask(() {});
    if (isSyncing.value || currentUser == null) return;

    try {
      isSyncing.value = true;
      statusMessage.value = "Refreshing labels...";
      AppLogger.log("[LABEL_SYNC] Manual refresh started...");

      _startRemoteListener();

      // Only push local changes if user has Pro subscription
      if (_canPushSync) {
        await _pushLocalChanges();
      } else {
        AppLogger.log("[LABEL_SYNC]Skipping push - Pro subscription required");
      }
      // Always pull remote changes (available to all users)
      await _pullRemoteChanges();

      statusMessage.value = "Label Refresh Complete";
      AppLogger.log("[LABEL_SYNC] Manual refresh complete");
    } catch (e, stack) {
      statusMessage.value = "Label Refresh Failed";
      AppLogger.error('LabelSync: Refresh Failed', e, stack);
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        if (!isSyncing.value) statusMessage.value = "";
      });
    }
  }

  Future<void> _sync() async {
    if (isSyncing.value || currentUser == null) return;

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[LABEL_SYNC]Skipping _sync - push sync not allowed");
      return;
    }

    await Future.microtask(() {});
    if (isSyncing.value || currentUser == null) return;

    final pendingSyncs = await LabelSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[LABEL_SYNC] No local changes to sync");
      return;
    }

    try {
      isSyncing.value = true;
      statusMessage.value = "Syncing labels...";
      AppLogger.log(
        "[LABEL_SYNC] Syncing ${pendingSyncs.length} local changes...",
      );

      await _pushLocalChangesWithPending(pendingSyncs);

      statusMessage.value = "Label Sync Complete";
      AppLogger.log("[LABEL_SYNC] Sync Complete");
    } catch (e, stack) {
      statusMessage.value = "Label Sync Failed";
      AppLogger.error('LabelSync: Sync Failed', e, stack);
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        if (!isSyncing.value) statusMessage.value = "";
      });
    }
  }

  Future<void> _pushLocalChangesWithPending(
    List<LabelSyncTrack> pendingSyncs,
  ) async {
    if (pendingSyncs.isEmpty) return;
    statusMessage.value = "Pushing label changes...";

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
          final newDocRef = _labelsCollection.doc();
          batch.set(newDocRef, labelData);
          sync.remoteId = newDocRef.id;
          await sync.save();
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
    statusMessage.value = "Pulling label changes...";

    DateTime? lastSynced = AppState.lastLabelSynced;
    Query query = _labelsCollection;
    if (lastSynced != null) {
      query = query.where(
        'updated_at',
        isGreaterThan: lastSynced.toIso8601String(),
      );
    }

    final querySnapshot = await query.get();

    final Set<String> processedDocIds = {};
    DateTime? maxRemoteUpdatedAt;

    for (final docSnapshot in querySnapshot.docs) {
      final remoteData = docSnapshot.data() as Map<String, dynamic>?;

      if (remoteData == null) {
        continue;
      }

      final remoteDocId = docSnapshot.id;

      if (processedDocIds.contains(remoteDocId)) {
        continue;
      }
      processedDocIds.add(remoteDocId);

      // Track max remote timestamp for accurate lastLabelSynced
      if (remoteData['updated_at'] != null) {
        final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);
        if (maxRemoteUpdatedAt == null ||
            remoteUpdatedAt.isAfter(maxRemoteUpdatedAt)) {
          maxRemoteUpdatedAt = remoteUpdatedAt;
        }
      }

      final isDeleted =
          remoteData['deleted'] == true || remoteData['deleted'] == 1;

      // Find existing sync track by remoteId
      final existingSyncTrack = await LabelSyncTrack.getByRemoteId(remoteDocId);
      final localId = existingSyncTrack?.localId;

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

      Label? localLabel;
      if (localId != null) {
        localLabel = await Label.findById(localId);
      }

      if (localLabel != null && remoteData['updated_at'] != null) {
        final localUpdatedAt = localLabel.updatedAt;
        final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

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
          "[LABEL_SYNC]Patched local label from remote doc: $remoteDocId",
        );
      } finally {
        if (localId != null) {
          _removeSyncingIncoming(localId);
        }
      }
    }
    // Use max remote timestamp to avoid missing labels created during sync
    if (maxRemoteUpdatedAt != null) {
      AppState.lastLabelSynced = maxRemoteUpdatedAt;
    } else if (processedDocIds.isNotEmpty) {
      AppState.lastLabelSynced = DateTime.now();
    }
  }

  Future<void> _handleRemoteDeletedLabelByRemoteId(String remoteDocId) async {
    final syncTrack = await LabelSyncTrack.getByRemoteId(remoteDocId);
    if (syncTrack == null) {
      return;
    }

    final label = await Label.findById(syncTrack.localId);
    if (label != null) {
      await label.delete(sync: false);
    }
    await syncTrack.delete();
    AppLogger.log(
      "[LABEL_SYNC] Deleted local label from remote deletion by remoteId: $remoteDocId",
    );
  }

  Future<void> _patchRemoteLabel(
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

    if (label == null) {
      // Create new label - let SQLite auto-generate the ID
      label = Label(
        name: remoteData['name'] as String,
        createdAt: remoteData['created_at'] != null
            ? DateTime.parse(remoteData['created_at'])
            : null,
        updatedAt: remoteData['updated_at'] != null
            ? DateTime.parse(remoteData['updated_at'])
            : null,
      );

      // Save without triggering sync (we're pulling from remote)
      final newId = await label.save(sync: false);
      label.id = newId;
    } else {
      // Update existing label
      label.name = remoteData['name'] as String;
      label.updatedAt = remoteData['updated_at'] != null
          ? DateTime.parse(remoteData['updated_at'])
          : DateTime.now();

      await AppState.db.update(
        Label.model,
        label.toJson(),
        where: "id = ?",
        whereArgs: [label.id],
      );
      label.notify("updated");
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
      syncTrack.remoteId = remoteDocId;
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
      existing.status = LabelSyncStatus.pending;
      existing.action = LabelSyncAction.upload;
      await existing.save();
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
      existing.action = LabelSyncAction.delete;
      existing.status = LabelSyncStatus.pending;
      await existing.save();
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
