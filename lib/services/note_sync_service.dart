import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/note_encryption.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:better_keep/config.dart' show demoAccountEmail;

/// Result of downloading a file
enum DownloadResult {
  /// File downloaded successfully
  success,

  /// Temporary failure (network, etc.) - should retry later
  temporaryFailure,

  /// Permanent failure (object-not-found) - file is gone, skip this attachment
  permanentFailure,
}

/// Result of downloading a file with path
class FileDownloadResult {
  final DownloadResult result;
  final String? localPath;

  FileDownloadResult(this.result, [this.localPath]);

  bool get isSuccess => result == DownloadResult.success;
  bool get isPermanentFailure => result == DownloadResult.permanentFailure;
  bool get isTemporaryFailure => result == DownloadResult.temporaryFailure;
}

class NoteSyncService {
  Timer? _syncTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  StreamSubscription<User?>? _userStreamSubscription;
  bool _initialized = false;

  /// Track last known E2EE status to detect transitions
  E2EEStatus? _lastKnownE2EEStatus;

  NoteSyncService._internal();

  factory NoteSyncService() => _instance;

  static final NoteSyncService _instance = NoteSyncService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: DefaultFirebaseOptions.databaseId,
  );
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Cache service for managing pending remote syncs
  final RemoteSyncCacheService _syncCache = RemoteSyncCacheService();

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  final ValueNotifier<String> statusMessage = ValueNotifier("");

  /// Tracks sync progress: (syncedCount, totalCount)
  final ValueNotifier<(int, int)> syncProgress = ValueNotifier((0, 0));

  /// Tracks note IDs currently being synced (outgoing push)
  final ValueNotifier<Set<int>> syncingOutgoing = ValueNotifier({});

  /// Tracks note IDs currently being synced (incoming pull)
  final ValueNotifier<Set<int>> syncingIncoming = ValueNotifier({});

  /// Tracks detailed sync status per note (for debug mode display)
  /// Key: noteId, Value: status message
  final ValueNotifier<Map<int, String>> noteStatus = ValueNotifier({});

  /// Tracks notes that failed to sync
  final ValueNotifier<Set<int>> syncFailed = ValueNotifier({});

  User? get currentUser => AuthService.currentUser;
  DocumentReference<Map<String, dynamic>> get _userRef =>
      _firestore.collection('users').doc(currentUser!.uid);
  CollectionReference<Map<String, dynamic>> get _notesCollection =>
      _userRef.collection('notes');

  void _setNoteStatus(int noteId, String status) {
    noteStatus.value = {...noteStatus.value, noteId: status};
  }

  void _clearNoteStatus(int noteId) {
    noteStatus.value = Map.from(noteStatus.value)..remove(noteId);
  }

  void _markSyncFailed(int noteId) {
    syncFailed.value = {...syncFailed.value, noteId};
  }

  void _clearSyncFailed(int noteId) {
    syncFailed.value = {...syncFailed.value}..remove(noteId);
  }

  void _addSyncingOutgoing(int noteId) {
    syncingOutgoing.value = {...syncingOutgoing.value, noteId};
    _clearSyncFailed(noteId);
  }

  void _removeSyncingOutgoing(int noteId) {
    syncingOutgoing.value = {...syncingOutgoing.value}..remove(noteId);
    _clearNoteStatus(noteId);
  }

  void _addSyncingIncoming(int noteId) {
    syncingIncoming.value = {...syncingIncoming.value, noteId};
    _clearSyncFailed(noteId);
  }

  void _removeSyncingIncoming(int noteId) {
    syncingIncoming.value = {...syncingIncoming.value}..remove(noteId);
    _clearNoteStatus(noteId);
  }

  /// Track the last user ID to detect login vs session restore
  String? _lastKnownUserId;

  Future<void> init() async {
    // Prevent duplicate initialization and listener registration
    if (_initialized) return;
    _initialized = true;

    AppLogger.log("[SYNC] SyncService initialized");

    // Initialize the sync cache
    await _syncCache.init();

    // Load last known user ID to detect login vs restore
    final prefs = await SharedPreferences.getInstance();
    _lastKnownUserId = prefs.getString('last_synced_user_id');

    if (currentUser != null) {
      // Skip sync for demo accounts to avoid E2EE errors
      if (_isDemoAccount) {
        AppLogger.log("[SYNC] Demo account detected, skipping sync");
        return;
      }

      // Sync if E2EE is ready or verifying in background
      // (verifyingInBackground means user can access notes while we verify)
      if (E2EEService.instance.isReady) {
        // Check if there are pending syncs from previous session
        if (_syncCache.hasPendingSyncs) {
          final pendingCount = _syncCache.getPendingSyncs().length;
          AppLogger.log(
            "[SYNC] Found $pendingCount pending syncs from previous session, resuming...",
          );
          _resumePendingSyncs();
        } else {
          AppLogger.log("[SYNC] No pending syncs, starting fresh sync");
          _sync();
        }
        _startRemoteListener();
      } else {
        AppLogger.log(
          "[SYNC] Skipping initial sync - E2EE status: ${E2EEService.instance.status.value}",
        );
      }
    }

    // Listen for E2EE status changes to trigger sync when ready
    E2EEService.instance.status.addListener(_onE2EEStatusChange);

    // Listen for subscription changes to start/stop sync when user upgrades/downgrades
    // Initialize with current subscription state
    _wasPreviouslyPaid = PlanService.instance.isPaid;
    PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);

    _userStreamSubscription = AuthService.userStream.listen((user) async {
      if (user != null) {
        final isNewUser = _lastKnownUserId != user.uid;
        if (isNewUser) {
          // On login (new user or different user), clear lastSynced and cache
          // This ensures we get all notes including deleted ones
          AppLogger.log(
            "[SYNC] New user login detected (was: $_lastKnownUserId, now: ${user.uid}), clearing sync state",
          );
          AppState.lastSynced = null;
          await _syncCache.clear();

          // Save new user ID
          _lastKnownUserId = user.uid;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_synced_user_id', user.uid);

          refresh(); // Do a full refresh on login
        } else {
          AppLogger.log(
            "[SYNC] Session restored for same user (${user.uid}), keeping sync state",
          );
        }
        _startRemoteListener();
      } else {
        _stopRemoteListener();
        await _syncCache.clear();
      }
    });
  }

  /// Resume syncing from cached pending syncs
  Future<void> _resumePendingSyncs() async {
    if (isSyncing.value || currentUser == null) return;
    if (!_canPushSync) return;

    // Yield to ensure we don't update state during a build phase
    await Future.microtask(() {});
    if (isSyncing.value || currentUser == null) return;

    final pendingCount = _syncCache.getPendingSyncs().length;
    final cacheAge = _syncCache.metadata?.updatedAt != null
        ? DateTime.now().difference(_syncCache.metadata!.updatedAt).inMinutes
        : 0;

    try {
      isSyncing.value = true;
      statusMessage.value = "Resuming sync...";
      AppLogger.log(
        "[SYNC] RESUME START: $pendingCount pending syncs from cache (age: ${cacheAge}min)",
      );

      // Refresh stale cache data from Firebase to ensure we have latest versions
      await _refreshStaleCacheData();

      await _processCachedSyncs();

      // Only show "Sync Complete" if there are no failed syncs
      final failedSyncs = _syncCache.getPendingSyncs();
      if (failedSyncs.isEmpty) {
        statusMessage.value = "Sync Complete";
        // Clear cache after successful resume
        await _syncCache.clear();
        AppLogger.log(
          "[SYNC] RESUME COMPLETE: Cache cleared after successful sync",
        );
      } else {
        AppLogger.log(
          "[SYNC] RESUME PARTIAL: ${failedSyncs.length} notes failed, cache retained",
        );
      }
    } catch (e, stack) {
      statusMessage.value = "Sync Failed";
      AppLogger.log("[SYNC] RESUME FAILED: $e\n$stack");
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        // Only clear status message if no failed syncs
        if (!isSyncing.value && syncFailed.value.isEmpty) {
          statusMessage.value = "";
        }
      });
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
    statusMessage.value = "Checking for updates...";

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
            .get();

        for (final doc in querySnapshot.docs) {
          final remoteData = doc.data();
          final localId = remoteData['local_id'] as int;
          final cachedSync = _syncCache.getSync(localId);

          if (cachedSync == null) continue;

          // Check if remote data has been updated since we cached it
          final cachedUpdatedAt = cachedSync.remoteData['updated_at'];
          final remoteUpdatedAt = remoteData['updated_at'];

          if (cachedUpdatedAt != remoteUpdatedAt) {
            // Remote has newer data, update cache
            await _syncCache.updateRemoteData(localId, remoteData, doc.id);
            updatedCount++;
            AppLogger.log(
              "[SYNC] REFRESH: Note $localId updated (cached: $cachedUpdatedAt -> remote: $remoteUpdatedAt)",
            );
          }
        }

        // Check for deleted notes (docs that no longer exist)
        final fetchedIds = querySnapshot.docs
            .map((d) => d.data()['local_id'] as int)
            .toSet();

        for (final docId in batch) {
          final cachedSync = pendingSyncs.firstWhere(
            (s) => s.remoteDocId == docId,
            orElse: () => pendingSyncs.first,
          );

          if (!fetchedIds.contains(cachedSync.localId)) {
            // Note was deleted on remote, mark cache entry as deleted
            final updatedData = Map<String, dynamic>.from(
              cachedSync.remoteData,
            );
            updatedData['deleted'] = true;
            await _syncCache.updateRemoteData(
              cachedSync.localId,
              updatedData,
              cachedSync.remoteDocId,
            );
            deletedCount++;
            AppLogger.log(
              "[SYNC] REFRESH: Note ${cachedSync.localId} deleted on remote",
            );
          }
        }
      } catch (e) {
        AppLogger.log("[SYNC] REFRESH ERROR: Batch $batchNum failed: $e");
        // Continue with next batch
      }
    }

    AppLogger.log(
      "[SYNC] REFRESH COMPLETE: $updatedCount updated, $deletedCount deleted",
    );
  }

  void _onE2EEStatusChange() {
    final status = E2EEService.instance.status.value;
    final previousStatus = _lastKnownE2EEStatus;
    _lastKnownE2EEStatus = status;

    AppLogger.log("[SYNC] E2EE status changed from $previousStatus to $status");

    // Skip sync for demo accounts
    if (_isDemoAccount) {
      AppLogger.log("[SYNC] Demo account detected, skipping sync");
      return;
    }

    // Check if we're transitioning TO a ready state from a non-ready state
    final isNowReady =
        status == E2EEStatus.ready ||
        status == E2EEStatus.verifyingInBackground;
    final wasReady =
        previousStatus == E2EEStatus.ready ||
        previousStatus == E2EEStatus.verifyingInBackground;

    // Trigger sync when E2EE becomes ready (from any non-ready state like pendingApproval)
    // Only trigger if we weren't already ready (to avoid duplicate syncs)
    if (isNowReady && !wasReady) {
      // E2EE just became ready - force a full sync to decrypt notes
      // This commonly happens after device approval or account recovery
      AppLogger.log(
        "[SYNC] E2EE just became ready (was: $previousStatus), triggering full sync",
      );

      // Schedule sync in a microtask to avoid blocking the listener callback
      // and to ensure proper async handling
      Future.microtask(() async {
        // Wait for any in-progress sync to complete before starting recovery sync
        // This prevents race conditions and ensures clean state
        int waitAttempts = 0;
        const maxWaitAttempts = 10;
        while (isSyncing.value && waitAttempts < maxWaitAttempts) {
          AppLogger.log(
            "[SYNC] E2EE ready: Waiting for in-progress sync to complete (attempt ${waitAttempts + 1}/$maxWaitAttempts)",
          );
          await Future.delayed(const Duration(milliseconds: 500));
          waitAttempts++;
        }

        // Clear sync cache to ensure fresh start (important for recovery)
        await _syncCache.clear();

        // Force full sync by clearing lastSynced
        AppState.lastSynced = null;

        // Stop any existing listener before starting fresh
        _stopRemoteListener();

        // Start the remote listener first (with null lastSynced = all notes)
        _startRemoteListener();

        // Then trigger a full refresh to pull all remote notes
        // This is awaited to ensure sync completes
        await refresh();

        AppLogger.log("[SYNC] E2EE ready sync completed");
      });
    } else if (status == E2EEStatus.pendingApproval ||
        status == E2EEStatus.revoked ||
        status == E2EEStatus.error) {
      // E2EE not ready - stop syncing encrypted content
      AppLogger.log("[SYNC] E2EE not ready ($status), pausing remote sync");
      _stopRemoteListener();
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
      if (currentUser != null &&
          E2EEService.instance.status.value == E2EEStatus.ready) {
        refresh();
        _startRemoteListener();
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

  /// Check if the current user is the demo account (for Google Play review testing).
  /// Demo accounts skip sync to avoid E2EE errors.
  bool get _isDemoAccount {
    final email = currentUser?.email;
    return email != null &&
        email.toLowerCase() == demoAccountEmail.toLowerCase();
  }

  /// Check if we can receive/download sync (incoming):
  /// - E2EE must be ready
  /// - Not a demo account
  /// - Session must be valid
  /// Note: Pro subscription NOT required for receiving sync
  bool get _canReceiveSync {
    // If session is invalid (user deleted/disabled), disable all sync
    if (AuthService.sessionInvalid.value) {
      return false;
    }

    // Demo accounts skip sync entirely to avoid E2EE errors
    if (_isDemoAccount) {
      return false;
    }

    final e2eeStatus = E2EEService.instance.status.value;
    // Only allow sync when E2EE is fully ready
    return e2eeStatus == E2EEStatus.ready;
  }

  /// Check if we can push/upload sync (outgoing):
  /// - Must have Pro subscription (cloud sync upload is a Pro feature)
  /// - E2EE must be ready
  /// - Not a demo account
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

  /// Start listening for real-time updates from Firebase
  void _startRemoteListener() {
    _stopRemoteListener();
    if (currentUser == null) return;

    // Don't listen for remote changes if we can't decrypt them
    if (!_canReceiveSync) {
      AppLogger.log("[SYNC] LISTENER: Skipping - E2EE not ready");
      return;
    }

    DateTime? lastSynced = AppState.lastSynced;
    Query<Map<String, dynamic>> query = _notesCollection;
    if (lastSynced != null) {
      query = query.where(
        'updated_at',
        isGreaterThan: lastSynced.toIso8601String(),
      );
    }

    _remoteListener = query.snapshots().listen(
      (snapshot) async {
        if (snapshot.docChanges.isEmpty) return;

        // Filter only modified/added documents (not from local changes)
        final changes = snapshot.docChanges.where(
          (change) =>
              change.type == DocumentChangeType.modified ||
              change.type == DocumentChangeType.added,
        );

        if (changes.isEmpty) return;

        AppLogger.log(
          "[SYNC] REALTIME: Received ${changes.length} remote changes",
        );

        // Track processed note IDs to avoid duplicates in this batch
        final Set<int> processedIds = {};
        bool allSyncsSucceeded = true;
        int syncedCount = 0;
        int skippedCount = 0;

        for (final change in changes) {
          final remoteData = change.doc.data();
          if (remoteData == null) {
            AppLogger.log("[SYNC] REALTIME: Remote data is null, skipping");
            skippedCount++;
            continue;
          }

          final localId = remoteData['local_id'] as int;
          final remoteDocId = change.doc.id;

          // Skip if already processed in this batch
          if (processedIds.contains(localId)) {
            AppLogger.log(
              "[SYNC] REALTIME: Note $localId already processed in this batch, skipping",
            );
            skippedCount++;
            continue;
          }
          processedIds.add(localId);

          // Check if this note is in the pending sync cache
          // If so, update the cache with the new data
          final wasInCache = await _syncCache.updateRemoteData(
            localId,
            remoteData,
            remoteDocId,
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

          // Check if this is a deleted note FIRST
          final isDeleted =
              remoteData['deleted'] == true || remoteData['deleted'] == 1;

          if (isDeleted) {
            AppLogger.log(
              "[SYNC] REALTIME: Note $localId deleted, handling deletion",
            );
            _addSyncingIncoming(localId);
            try {
              await _handleRemoteDeletedNote(localId);
              syncedCount++;
            } finally {
              _removeSyncingIncoming(localId);
            }
            continue;
          }

          // Check if there's a pending sync for this note - don't overwrite local changes
          final pendingSync = await NoteSyncTrack.getByLocalId(localId);
          if (pendingSync != null &&
              (pendingSync.status == SyncStatus.pending ||
                  pendingSync.status == SyncStatus.failed)) {
            AppLogger.log(
              "[SYNC] REALTIME: Note $localId has pending local changes, skipping",
            );
            skippedCount++;
            continue;
          }

          final localNote = await Note.findById(localId);

          if (localNote != null && remoteData['updated_at'] != null) {
            final localUpdatedAt = localNote.updatedAt;
            final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

            if (localUpdatedAt != null &&
                (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                    remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt))) {
              AppLogger.log(
                "[SYNC] REALTIME: Note $localId local is newer, skipping",
              );
              skippedCount++;
              continue;
            }
          }

          AppLogger.log("[SYNC] REALTIME: Patching note $localId from remote");
          _addSyncingIncoming(localId);
          try {
            final success = await _patchRemoteNote(remoteData, remoteDocId);
            if (success) {
              syncedCount++;
              AppLogger.log(
                "[SYNC] REALTIME: Note $localId patched successfully",
              );
            } else {
              allSyncsSucceeded = false;
              AppLogger.log("[SYNC] REALTIME: Note $localId patch failed");
            }
          } finally {
            _removeSyncingIncoming(localId);
          }
        }

        AppLogger.log(
          "[SYNC] REALTIME COMPLETE: $syncedCount synced, $skippedCount skipped",
        );

        // Only update lastSynced if all syncs succeeded
        if (allSyncsSucceeded) {
          AppState.lastSynced = DateTime.now();
        } else {
          AppLogger.log(
            "[SYNC] REALTIME: Some syncs failed, not updating lastSynced",
          );
        }
      },
      onError: (error) {
        AppLogger.error('[SYNC] REALTIME ERROR', error);
      },
    );

    AppLogger.log("[SYNC] LISTENER: Started real-time remote listener");
  }

  /// Stop listening for real-time updates
  void _stopRemoteListener() {
    try {
      _remoteListener?.cancel();
    } catch (e) {
      // Ignore errors when cancelling listener that wasn't fully initialized
      AppLogger.error(
        '[SYNC] Error stopping remote listener (safe to ignore)',
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
    E2EEService.instance.status.removeListener(_onE2EEStatusChange);
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    _initialized = false;
  }

  Reference getNoteDocsRef(int noteId) {
    return _storage.ref().child('users/${currentUser!.uid}/notes/$noteId');
  }

  Future<void> sync([bool now = false]) async {
    _syncTimer?.cancel();

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[SYNC] Skipping sync request - push sync not allowed");
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

  /// Manual refresh - pushes local changes and pulls remote changes
  /// Used for pull-to-refresh and refresh button
  /// Note: Incoming sync (pull) works for all users, outgoing sync (push) requires Pro
  Future<void> refresh() async {
    if (isSyncing.value || currentUser == null) return;

    // Don't sync if E2EE is not ready (pending approval, revoked, etc.)
    if (!_canReceiveSync) {
      AppLogger.log("[SYNC] REFRESH: Skipping - E2EE not ready");
      return;
    }

    await Future.microtask(() {});
    if (isSyncing.value || currentUser == null) return;

    // Clear failed syncs on manual refresh - user is trying again
    syncFailed.value = {};

    try {
      isSyncing.value = true;
      statusMessage.value = "Refreshing...";
      final currentLastSynced = AppState.lastSynced;
      AppLogger.log(
        "[SYNC] REFRESH START: Manual refresh triggered (lastSynced: ${currentLastSynced?.toIso8601String() ?? 'null'})",
      );

      // Only start listener if not already running
      // The listener is started on login/init and runs continuously
      if (_remoteListener == null) {
        _startRemoteListener();
      }

      // Only push local changes if user has Pro subscription
      if (_canPushSync) {
        await _pushLocalChanges();
      } else {
        AppLogger.log(
          "[SYNC] REFRESH: Skipping push - Pro subscription required",
        );
      }
      // Always pull remote changes (available to all users)
      await _pullRemoteChanges();

      // Only show "Refresh Complete" if there are no failed syncs
      final failedSyncs = _syncCache.getPendingSyncs();
      if (failedSyncs.isEmpty) {
        statusMessage.value = "Refresh Complete";
        AppLogger.log("[SYNC] REFRESH COMPLETE: All syncs successful");
      } else {
        AppLogger.log(
          "[SYNC] REFRESH PARTIAL: ${failedSyncs.length} notes failed",
        );
      }
    } catch (e, stack) {
      statusMessage.value = "Refresh Failed";
      AppLogger.error('[SYNC] REFRESH FAILED', e, stack);
    } finally {
      isSyncing.value = false;
      Future.delayed(const Duration(seconds: 2), () {
        // Only clear status message if no failed syncs
        if (!isSyncing.value && syncFailed.value.isEmpty) {
          statusMessage.value = "";
        }
      });
    }
  }

  Future<void> _sync() async {
    if (isSyncing.value || currentUser == null) return;

    // Don't push sync if not allowed (requires Pro)
    if (!_canPushSync) {
      AppLogger.log("[SYNC] Skipping sync - push sync not allowed");
      return;
    }

    // Yield to ensure we don't update state during a build phase
    await Future.microtask(() {});

    // Check again after yield
    if (isSyncing.value || currentUser == null) return;

    // Check if there are pending local changes before syncing
    final pendingSyncs = await NoteSyncTrack.get(pending: true);
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[SYNC] No local changes to sync");
      return;
    }

    try {
      isSyncing.value = true;
      statusMessage.value = "Syncing...";
      AppLogger.log(
        "[SYNC] PUSH START: ${pendingSyncs.length} local changes to sync",
      );

      await _pushLocalChangesWithPending(pendingSyncs);

      statusMessage.value = "Sync Complete";
      AppLogger.log("[SYNC] PUSH COMPLETE: Local changes synced");
    } catch (e, stack) {
      statusMessage.value = "Sync Failed";
      AppLogger.error('[SYNC] PUSH FAILED', e, stack);
    } finally {
      isSyncing.value = false;
      // Clear message after delay
      Future.delayed(const Duration(seconds: 2), () {
        if (!isSyncing.value) statusMessage.value = "";
      });
    }
  }

  /// Push local changes with already fetched pending syncs
  Future<void> _pushLocalChangesWithPending(
    List<NoteSyncTrack> pendingSyncs,
  ) async {
    if (pendingSyncs.isEmpty) return;
    statusMessage.value = "Saving changes...";

    AppLogger.log(
      "[SYNC] PUSH: Starting push of ${pendingSyncs.length} local changes",
    );

    WriteBatch batch = _firestore.batch();
    int batchCount = 0;
    int pushedCount = 0;
    int failedCount = 0;
    final List<Future<void> Function()> postCommitActions = [];

    for (final sync in pendingSyncs) {
      // Capture sync start time to detect modifications during sync
      final syncStartTime = DateTime.now();
      _addSyncingOutgoing(sync.localId);
      try {
        if (sync.action == SyncAction.delete && sync.remoteId == null) {
          await sync.delete();
          AppLogger.log(
            "[SYNC] PUSH: Note ${sync.localId} - deleted local track (no remote ID)",
          );
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        late final Map<String, dynamic>? remoteData;

        if (sync.remoteId != null) {
          final docSnapshot = await _notesCollection.doc(sync.remoteId).get();
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
            await _patchRemoteNote(remoteData, sync.remoteId!);
            AppLogger.log(
              "[SYNC] PUSH: Note ${sync.localId} - patched from remote (remote newer)",
            );
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
          await sync.delete();
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        if (sync.action == SyncAction.delete && !isRemoteDeleted) {
          // If remoteData is null, the document doesn't exist on remote
          // so there's nothing to delete - just clean up the local sync track
          if (remoteData == null) {
            await sync.delete();
            AppLogger.log(
              "[SYNC] PUSH: Note ${sync.localId} - cleaned up track (remote doesn't exist)",
            );
            _removeSyncingOutgoing(sync.localId);
            continue;
          }
          if (sync.remoteId != null) {
            final localId = sync.localId;
            batch.set(_notesCollection.doc(sync.remoteId), {
              'local_id': sync.localId,
              'deleted_at': FieldValue.serverTimestamp(),
              'deleted': true,
              'updated_at': DateTime.now().toIso8601String(),
            });
            postCommitActions.add(() async {
              await _deleteNoteStorage(sync.localId);
              await sync.delete();
              AppLogger.log(
                "[SYNC] PUSH: Note ${sync.remoteId} deleted from remote",
              );
              _removeSyncingOutgoing(localId);
            });
            batchCount++;
            pushedCount++;
          } else {
            await sync.delete();
            _removeSyncingOutgoing(sync.localId);
          }
          continue;
        }

        final note = await Note.findById(sync.localId);

        if (note == null) {
          await sync.delete();
          _removeSyncingOutgoing(sync.localId);
          continue;
        }

        var noteData = note.toJson();

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
        final attachmentsData = await _uploadAttachments(
          note.attachments,
          note,
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
        noteData = await _encryptNoteData(noteData);

        final localId = sync.localId;
        final capturedSyncStartTime = syncStartTime;
        if (sync.remoteId != null) {
          batch.set(
            _notesCollection.doc(sync.remoteId),
            noteData,
            SetOptions(merge: true),
          );
          postCommitActions.add(() async {
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
          final newDocRef = _notesCollection.doc();
          batch.set(newDocRef, noteData);
          sync.remoteId = newDocRef.id;
          // Save remoteId immediately to prevent duplicates if another sync runs
          // before the batch commits and markSynced is called
          await sync.save();
          postCommitActions.add(() async {
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
          await batch.commit();
          for (final action in postCommitActions) {
            await action();
          }
          postCommitActions.clear();
          batch = _firestore.batch();
          batchCount = 0;
        }
      } catch (e) {
        AppLogger.error('[SYNC] PUSH: Note ${sync.localId} error', e);
        _markSyncFailed(sync.localId);
        _removeSyncingOutgoing(sync.localId);
        failedCount++;
      }
    }

    if (batchCount > 0) {
      await batch.commit();
      for (final action in postCommitActions) {
        await action();
      }
    }

    AppLogger.log(
      "[SYNC] PUSH COMPLETE: $pushedCount pushed, $failedCount failed",
    );
  }

  Future<void> _deleteNoteStorage(int noteId) async {
    try {
      final ref = getNoteDocsRef(noteId);
      final listResult = await ref.listAll();
      await Future.wait(listResult.items.map((item) => item.delete()));
    } catch (e) {
      AppLogger.error('[SYNC] Error deleting storage for note $noteId', e);
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
    statusMessage.value = "Getting updates...";
    final lastSynced = AppState.lastSynced;

    AppLogger.log(
      "[SYNC] PULL START: Fetching remote changes since ${lastSynced?.toIso8601String() ?? 'beginning'}",
    );

    // Start a new sync session with the current lastSynced timestamp
    await _syncCache.startNewSync(lastSynced);

    // Fetch all pages from Firebase and cache them
    // Note: lastSynced is updated progressively after each page fetch
    await _fetchAndCacheRemoteNotes(lastSynced);

    // Process all cached syncs
    await _processCachedSyncs();

    // Clear cache and log result
    if (_syncCache.metadata?.syncComplete == true) {
      AppLogger.log(
        "[SYNC] PULL COMPLETE: All remote changes synced successfully",
      );
      // Clear the cache files since sync is complete
      await _syncCache.clear();
      AppLogger.log("[SYNC] Cache cleared after successful sync");
    } else {
      final failedCount = _syncCache.getPendingSyncs().length;
      AppLogger.log(
        "[SYNC] PULL PARTIAL: $failedCount notes failed, cache retained for resume",
      );
    }
  }

  /// Fetch all remote notes updated since lastSynced and cache them in pages
  Future<void> _fetchAndCacheRemoteNotes(DateTime? lastSynced) async {
    statusMessage.value = "Fetching updates...";

    DocumentSnapshot? lastDocument;
    int pageIndex = 0;
    bool hasMore = true;
    int totalNotesFetched = 0;

    AppLogger.log(
      "[SYNC] FETCH START: Querying Firebase for changes since ${lastSynced?.toIso8601String() ?? 'null'}",
    );

    while (hasMore) {
      // Build the query with pagination
      Query<Map<String, dynamic>> query = _notesCollection
          .orderBy('updated_at')
          .limit(RemoteSyncCacheService.pageSize);

      if (lastSynced != null) {
        query = query.where(
          'updated_at',
          isGreaterThan: lastSynced.toIso8601String(),
        );
      }

      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }

      final querySnapshot = await query.get();

      if (querySnapshot.docs.isEmpty) {
        hasMore = false;
        AppLogger.log("[SYNC] FETCH: No more documents to fetch");
        break;
      }

      // Create pending syncs from fetched documents and track max updated_at
      final syncs = <int, PendingRemoteSync>{};
      DateTime? maxUpdatedAt;

      for (final doc in querySnapshot.docs) {
        final remoteData = doc.data();
        final localId = remoteData['local_id'] as int;
        final updatedAtStr = remoteData['updated_at'] as String?;

        // Log each fetched note for debugging
        AppLogger.log(
          "[SYNC] FETCH: Note $localId (doc: ${doc.id}) updated_at: $updatedAtStr",
        );

        // Track max updated_at from this page
        if (updatedAtStr != null) {
          final docUpdatedAt = DateTime.parse(updatedAtStr);
          if (maxUpdatedAt == null || docUpdatedAt.isAfter(maxUpdatedAt)) {
            maxUpdatedAt = docUpdatedAt;
          }
        }

        syncs[localId] = PendingRemoteSync(
          localId: localId,
          remoteDocId: doc.id,
          remoteData: remoteData,
          fetchedAt: DateTime.now(),
        );
      }

      totalNotesFetched += syncs.length;

      // Determine if there are more pages
      hasMore = querySnapshot.docs.length >= RemoteSyncCacheService.pageSize;

      // Save the page to cache with max updated_at
      final page = PendingRemoteSyncPage(
        pageIndex: pageIndex,
        syncs: syncs,
        lastDocumentId: querySnapshot.docs.isNotEmpty
            ? querySnapshot.docs.last.id
            : null,
        hasMore: hasMore,
      );
      await _syncCache.addPage(page, maxUpdatedAt: maxUpdatedAt);

      // Update AppState.lastSynced immediately after caching each page
      // This prevents re-fetching the same notes if sync is interrupted
      if (maxUpdatedAt != null) {
        AppState.lastSynced = maxUpdatedAt;
        AppLogger.log(
          "[SYNC] FETCH: Updated lastSynced to ${maxUpdatedAt.toIso8601String()}",
        );
      }

      // Update cursor for next page
      if (querySnapshot.docs.isNotEmpty) {
        lastDocument = querySnapshot.docs.last;
      }

      pageIndex++;

      AppLogger.log(
        "[SYNC] FETCH: Page $pageIndex - ${syncs.length} notes fetched, hasMore: $hasMore",
      );
    }

    AppLogger.log(
      "[SYNC] FETCH COMPLETE: $totalNotesFetched notes in ${_syncCache.metadata?.totalPages ?? 0} pages",
    );
  }

  /// Process all cached pending syncs
  Future<void> _processCachedSyncs() async {
    final pendingSyncs = _syncCache.getPendingSyncs();
    if (pendingSyncs.isEmpty) {
      AppLogger.log("[SYNC] PROCESS: No pending syncs to process");
      syncProgress.value = (0, 0);
      // Mark sync as complete since there's nothing to process
      await _syncCache.markSyncComplete();
      return;
    }

    final totalCount = pendingSyncs.length;
    int syncedCount = 0;
    int skippedCount = 0;
    int failedCount = 0;

    syncProgress.value = (syncedCount, totalCount);
    statusMessage.value = "Syncing notes...";
    AppLogger.log("[SYNC] PROCESS START: $totalCount cached syncs to process");

    // Track processed note IDs to avoid duplicates
    final Set<int> processedIds = {};

    for (final pendingSync in pendingSyncs) {
      final localId = pendingSync.localId;
      final remoteData = pendingSync.remoteData;
      final remoteDocId = pendingSync.remoteDocId;

      // Skip if already processed in this sync cycle
      if (processedIds.contains(localId)) {
        continue;
      }
      processedIds.add(localId);

      // Check if this is a deleted note FIRST
      final isDeleted =
          remoteData['deleted'] == true || remoteData['deleted'] == 1;

      if (isDeleted) {
        // Handle deletion
        _addSyncingIncoming(localId);
        try {
          await _handleRemoteDeletedNote(localId);
          await _syncCache.markCompleted(localId);
          syncedCount++;
          syncProgress.value = (syncedCount, totalCount);
          AppLogger.log(
            "[SYNC] PROCESS: Note $localId deleted locally (remote deletion)",
          );
        } finally {
          _removeSyncingIncoming(localId);
        }
        continue;
      }

      // Check if there's a pending sync for this note - don't overwrite local changes
      final localPendingSync = await NoteSyncTrack.getByLocalId(localId);
      if (localPendingSync != null &&
          (localPendingSync.status == SyncStatus.pending ||
              localPendingSync.status == SyncStatus.failed)) {
        AppLogger.log(
          "[SYNC] PROCESS: Note $localId skipped - has pending local changes",
        );
        await _syncCache.markCompleted(localId);
        syncedCount++;
        skippedCount++;
        syncProgress.value = (syncedCount, totalCount);
        continue;
      }

      final localNote = await Note.findById(localId);

      if (localNote != null && remoteData['updated_at'] != null) {
        final localUpdatedAt = localNote.updatedAt;
        final remoteUpdatedAt = DateTime.parse(remoteData['updated_at']);

        if (localUpdatedAt != null &&
            (remoteUpdatedAt.isBefore(localUpdatedAt) ||
                remoteUpdatedAt.isAtSameMomentAs(localUpdatedAt))) {
          // Local is newer, skip
          await _syncCache.markCompleted(localId);
          syncedCount++;
          skippedCount++;
          syncProgress.value = (syncedCount, totalCount);
          continue;
        }
      }

      _addSyncingIncoming(localId);
      try {
        // Update status to in progress
        await _syncCache.updateSync(
          localId,
          pendingSync.copyWith(status: PendingRemoteSyncStatus.inProgress),
        );

        final success = await _patchRemoteNote(remoteData, remoteDocId);

        if (success) {
          await _syncCache.markCompleted(localId);
          syncedCount++;
          syncProgress.value = (syncedCount, totalCount);
          AppLogger.log("[SYNC] PROCESS: Note $localId synced successfully");
        } else {
          await _syncCache.markFailed(localId, "Attachment download failed");
          _markSyncFailed(localId);
          failedCount++;
          AppLogger.log(
            "[SYNC] PROCESS: Note $localId failed - attachment download failed",
          );
        }
      } catch (e) {
        await _syncCache.markFailed(localId, e.toString());
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
      statusMessage.value = "Some notes failed to sync";
    }

    AppLogger.log(
      "[SYNC] PROCESS COMPLETE: $syncedCount synced, $skippedCount skipped, $failedCount failed",
    );

    // Reset progress when done
    syncProgress.value = (0, 0);
  }

  /// Handle a note that was deleted on remote
  Future<void> _handleRemoteDeletedNote(int localId) async {
    final note = await Note.findById(localId);
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
    final syncTrack = await NoteSyncTrack.getByLocalId(localId);
    if (syncTrack != null) {
      await syncTrack.delete();
    }

    await note.delete();
    AppLogger.log("Deleted local note from remote deletion: $localId");
  }

  /// Patch a local note with remote data
  /// Returns true if sync was successful, false if it failed (e.g., attachment download failed)
  Future<bool> _patchRemoteNote(
    Map<String, dynamic> remoteData,
    String remoteDocId,
  ) async {
    final localId = remoteData['local_id'] as int;

    // Note: deleted notes should be handled by _handleRemoteDeletedNote
    // This method is only for patching non-deleted notes
    final isDeleted =
        remoteData['deleted'] == true || remoteData['deleted'] == 1;
    if (isDeleted) {
      await _handleRemoteDeletedNote(localId);
      return true;
    }

    // Check if note is encrypted but E2EE isn't ready
    // Don't save encrypted notes with null content - wait for E2EE to be ready
    final isEncrypted = remoteData.containsKey('e2ee_ciphertext');
    final e2ee = E2EEService.instance;
    if (isEncrypted && !e2ee.isReady) {
      AppLogger.log(
        "[SYNC] PROCESS: Note $localId skipped - encrypted but E2EE not ready",
      );
      return false; // Return false to retry later when E2EE is ready
    }

    // Decrypt E2EE data if encrypted
    final decryptedData = await _decryptNoteData(remoteData);

    // Double-check decryption succeeded for encrypted notes
    if (isEncrypted && decryptedData.containsKey('e2ee_ciphertext')) {
      // Decryption failed - still contains encrypted data
      AppLogger.log(
        "[SYNC] PROCESS: Note $localId skipped - decryption failed",
      );
      return false;
    }

    final note =
        await Note.findById(decryptedData['local_id'] as int) ??
        Note(id: decryptedData['local_id'] as int);

    note.pinned = decryptedData['pinned'] == 1;
    note.locked = decryptedData['locked'] == 1;
    note.trashed = decryptedData['trashed'] == 1;
    note.archived = decryptedData['archived'] == 1;
    note.readOnly = decryptedData['read_only'] == 1;
    note.completed = decryptedData['completed'] == 1;
    note.title = decryptedData['title'] as String?;
    note.labels = decryptedData['labels'] as String?;
    final colorValue = decryptedData['color'];
    if (colorValue != null) {
      note.color = Color(int.tryParse(colorValue.toString()) ?? 0xFFFFFFFF);
    }
    note.content = decryptedData['content'] as String?;
    note.plainText = decryptedData['plain_text'] as String?;

    // Download attachments - if any fail, don't sync this note
    final attachments = await _downloadAttachments(
      remoteData['attachments'],
      note,
    );
    if (attachments == null) {
      // Attachment download failed - log and skip this note
      AppLogger.log(
        "Skipping sync for note ${note.id} due to attachment download failure",
      );
      _markSyncFailed(note.id!);
      return false;
    }
    note.attachments = attachments;

    if (remoteData['updated_at'] != null) {
      note.updatedAt = DateTime.parse(remoteData['updated_at'] as String);
    } else {
      note.updatedAt = DateTime.now();
    }

    if (remoteData['reminder'] != null) {
      final reminderData = remoteData['reminder'];
      if (reminderData is String) {
        note.reminder = Reminder.fromJson(
          jsonDecode(reminderData) as Map<String, Object?>,
        );
      } else if (reminderData is Map) {
        note.reminder = Reminder.fromJson(
          Map<String, Object?>.from(reminderData),
        );
      }
      // Only set alarm if the reminder is not completed
      if (!note.completed) {
        note.setAlarm();
      }
    }

    await note.save(false);

    // Create or update sync track to link local note with remote document
    // This ensures we can properly sync deletes and updates later
    var syncTrack = await NoteSyncTrack.getByLocalId(localId);
    if (syncTrack == null) {
      syncTrack = NoteSyncTrack(
        localId: localId,
        remoteId: remoteDocId,
        action: SyncAction.upload,
        status: SyncStatus.synced,
      );
      await syncTrack.save();
    } else {
      // Update existing sync track with remote ID and mark as synced
      // This is important: when we receive a remote update, any pending local
      // changes are superseded, so we must mark as synced to prevent blocking
      // future remote updates
      syncTrack.remoteId ??= remoteDocId;
      syncTrack.status = SyncStatus.synced;
      syncTrack.action = SyncAction.upload;
      await syncTrack.save();
    }

    return true;
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
  Future<List<NoteAttachment>?> _downloadAttachments(
    List<dynamic> attachmentData,
    Note note,
  ) async {
    List<NoteAttachment> attachments = [];

    for (final data in attachmentData) {
      final attachment = NoteAttachment.fromJson(data as Map<String, dynamic>);
      final result = await _downloadAttachment(attachment, note);

      switch (result) {
        case DownloadResult.success:
          attachments.add(attachment);
          break;
        case DownloadResult.permanentFailure:
          // File doesn't exist on remote - skip this attachment but continue with note
          AppLogger.log(
            "Attachment file missing on remote for note ${note.id}, skipping attachment",
          );
          // Don't add to attachments list - effectively removes the broken attachment
          break;
        case DownloadResult.temporaryFailure:
          // Temporary failure (network, E2EE not ready, etc.) - fail the entire note sync
          AppLogger.log(
            "Temporary failure downloading attachment for note ${note.id}, will retry later",
          );
          return null;
      }
    }

    // Don't delete orphans here - downloads create new local files
    // Orphan cleanup should only happen after uploads
    return attachments;
  }

  /// Result of uploading attachments - contains data and success status
  /// Returns null if any required upload failed
  Future<List<dynamic>?> _uploadAttachments(
    List<NoteAttachment> attachments,
    Note note,
  ) async {
    List<dynamic> attachmentData = [];
    bool hasFailure = false;

    for (final attachment in attachments) {
      // Skip sketch attachments without a preview image
      if (attachment.type == AttachmentType.sketch &&
          (attachment.sketch!.previewImage == null ||
              attachment.sketch!.previewImage!.isEmpty)) {
        AppLogger.log(
          "Skipping sketch attachment without preview image for note ${note.id}",
        );
        continue;
      }

      // Get remote URLs for the attachment without modifying the original
      final result = await _getRemoteAttachmentJson(attachment, note);

      if (result == null) {
        // Upload failed for this attachment
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
  Future<Map<String, dynamic>?> _getRemoteAttachmentJson(
    NoteAttachment attachment,
    Note note,
  ) async {
    // Start with the current JSON representation
    final json = attachment.toJson();

    // Upload main file and update JSON with remote URL
    final src = switch (attachment.type) {
      AttachmentType.image => attachment.image!.src,
      AttachmentType.sketch => attachment.sketch!.previewImage,
      AttachmentType.audio => attachment.recording!.src,
    };

    if (src != null && src.isNotEmpty && !src.startsWith('http')) {
      final remoteUrl = await _uploadFile(src, note, 'main');
      // Update the JSON 'data' field, not the original attachment
      // toJson() returns {'type': '...', 'data': {...}} structure
      final data = json['data'] as Map<String, dynamic>;
      if (remoteUrl != null) {
        switch (attachment.type) {
          case AttachmentType.image:
          case AttachmentType.audio:
            data['src'] = remoteUrl;
            break;
          case AttachmentType.sketch:
            data['previewImage'] = remoteUrl;
            break;
        }
      } else {
        // Upload failed - return null to signal sync should be aborted
        AppLogger.log(
          "Failed to upload attachment file for note ${note.id}, aborting sync",
        );
        return null;
      }
    }

    // Also upload sketch background image if present
    if (attachment.type == AttachmentType.sketch &&
        attachment.sketch!.backgroundImage != null &&
        attachment.sketch!.backgroundImage!.isNotEmpty &&
        !attachment.sketch!.backgroundImage!.startsWith('http')) {
      final bgSrc = attachment.sketch!.backgroundImage!;
      final remoteBgUrl = await _uploadFile(bgSrc, note, 'bg');
      if (remoteBgUrl != null) {
        (json['data'] as Map<String, dynamic>)['backgroundImage'] = remoteBgUrl;
      } else {
        // Background image upload failed - return null to signal sync should be aborted
        AppLogger.log(
          "Failed to upload background image for note ${note.id}, aborting sync",
        );
        return null;
      }
    }

    return json;
  }

  /// Helper to upload a single file and return remote URL
  Future<String?> _uploadFile(String src, Note note, String suffix) async {
    if (src.startsWith('http')) {
      return null; // Already remote
    }

    String? remoteUrl;
    final FileSyncTrack? sync = await FileSyncTrack.getByLocalPath(src);

    if (sync != null && sync.remotePath != null) {
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

    final userStorageRef = getNoteDocsRef(note.id!);

    if (src.startsWith('data:')) {
      try {
        final commaIndex = src.indexOf(',');
        if (commaIndex == -1) {
          return null;
        }

        final base64Data = src.substring(commaIndex + 1);
        var bytes = Uint8List.fromList(base64Decode(base64Data));

        String extension = 'jpg';
        final regex = RegExp(r'image\/([a-zA-Z0-9+]+);base64');
        final match = regex.firstMatch(src);
        if (match != null && match.groupCount >= 1) {
          extension = match.group(1)!;
        }
        final fileRef = userStorageRef.child(
          '${note.id}_${suffix}_${DateTime.now().millisecondsSinceEpoch}.$extension',
        );

        // Encrypt if E2EE is enabled
        final e2ee = E2EEService.instance;
        if (e2ee.isReady) {
          final umk = e2ee.deviceManager.getUMK();
          if (umk != null) {
            bytes = await FileEncryption.encryptBytes(bytes, umk);
            AppLogger.log("Encrypted data URI attachment");
          }
        }

        statusMessage.value = "Uploading media...";
        _setNoteStatus(note.id!, "Uploading media...");
        await fileRef.putData(bytes);
        remoteUrl = await fileRef.getDownloadURL();
      } catch (e) {
        AppLogger.error('Error uploading data URI image', e);
        return null;
      }
    } else {
      final fs = await fileSystem();
      if (await fs.exists(src)) {
        final fileName = path.basename(src);
        final fileRef = userStorageRef.child(fileName);

        try {
          statusMessage.value = "Uploading media...";
          _setNoteStatus(note.id!, "Uploading media...");

          var fileBytes = await fs.readBytes(src);

          // Encrypt file if E2EE is enabled
          final e2ee = E2EEService.instance;
          if (e2ee.isReady) {
            final umk = e2ee.deviceManager.getUMK();
            if (umk != null) {
              fileBytes = await FileEncryption.encryptBytes(fileBytes, umk);
              AppLogger.log("Encrypted attachment: $fileName");
            }
          }

          await fileRef
              .putData(fileBytes)
              .timeout(const Duration(seconds: 120));
          remoteUrl = await fileRef.getDownloadURL();
        } catch (e) {
          AppLogger.error('Error uploading $fileName', e);
          _markSyncFailed(note.id!);
          return null;
        }
      }
    }

    if (remoteUrl != null) {
      if (sync == null) {
        final newSync = FileSyncTrack(
          localPath: src,
          remotePath: remoteUrl,
          noteId: note.id!,
        );
        await newSync.save();
      } else {
        await sync.setRemotePath(remoteUrl);
      }
    }

    return remoteUrl;
  }

  /// Downloads attachment file and returns the download result
  /// Returns DownloadResult.success if downloaded, permanentFailure if file doesn't exist,
  /// or temporaryFailure for retryable errors
  Future<DownloadResult> _downloadAttachment(
    NoteAttachment attachment,
    Note note,
  ) async {
    // Download main file
    String? src = switch (attachment.type) {
      AttachmentType.image => attachment.image!.src,
      AttachmentType.sketch => attachment.sketch!.previewImage,
      AttachmentType.audio => attachment.recording?.src,
    };

    if (src != null && src.isNotEmpty && src.startsWith('http')) {
      final result = await _downloadFile(src, note, 'main');
      if (result.isSuccess && result.localPath != null) {
        switch (attachment.type) {
          case AttachmentType.image:
            attachment.image!.src = result.localPath!;
            break;
          case AttachmentType.sketch:
            attachment.sketch!.previewImage = result.localPath;
            break;
          case AttachmentType.audio:
            attachment.recording!.src = result.localPath!;
            break;
        }
      } else {
        // Download failed - return the failure type
        return result.result;
      }
    } else if (src != null && src.isNotEmpty && !src.startsWith('http')) {
      // Local path - check if file exists
      final fs = await fileSystem();
      if (!await fs.exists(src)) {
        // Local file missing - this is a permanent failure
        return DownloadResult.permanentFailure;
      }
    } else {
      // No src - attachment is invalid, treat as permanent failure
      return DownloadResult.permanentFailure;
    }

    // Also download sketch background image if present
    if (attachment.type == AttachmentType.sketch &&
        attachment.sketch!.backgroundImage != null &&
        attachment.sketch!.backgroundImage!.isNotEmpty &&
        attachment.sketch!.backgroundImage!.startsWith('http')) {
      final bgSrc = attachment.sketch!.backgroundImage!;
      final result = await _downloadFile(bgSrc, note, 'bg');
      if (result.isSuccess && result.localPath != null) {
        attachment.sketch!.backgroundImage = result.localPath;
      }
      // Background image failure is not critical, don't fail the whole attachment
    }

    return DownloadResult.success;
  }

  /// Helper to download a single file and return local path with result status
  Future<FileDownloadResult> _downloadFile(
    String src,
    Note note,
    String suffix,
  ) async {
    if (!src.startsWith('http')) {
      return FileDownloadResult(DownloadResult.temporaryFailure);
    }

    final fs = await fileSystem();
    final sync = await FileSyncTrack.getByRemotePath(src);

    // If we have a sync record, check if the local file actually exists and is valid
    if (sync != null) {
      if (await fs.exists(sync.localPath)) {
        // Validate the file isn't corrupted (e.g., encrypted bytes saved by mistake)
        final bytes = await fs.readBytes(sync.localPath);
        if (FileEncryption.looksEncrypted(bytes)) {
          // File appears encrypted - it was saved incorrectly, re-download
          await sync.delete();
          await fs.delete(sync.localPath);
          AppLogger.log(
            "Local file appears encrypted, will re-download: ${sync.localPath}",
          );
        } else {
          return FileDownloadResult(DownloadResult.success, sync.localPath);
        }
      } else {
        // File was deleted, remove the stale sync record and re-download
        await sync.delete();
        AppLogger.log(
          "Local file missing, will re-download: ${sync.localPath}",
        );
      }
    }

    statusMessage.value = "Downloading media...";
    _setNoteStatus(note.id!, "Downloading media...");

    // Use FileSystem interface for cross-platform compatibility
    final documentsDir = await fs.documentDir;
    final attachmentsPath = path.join(documentsDir, 'attachments');

    // Ensure attachments directory exists by writing a placeholder if needed
    // The FileSystem interface creates directories automatically on write

    final localPath = path.join(
      attachmentsPath,
      '${note.id}_${suffix}_${DateTime.now().millisecondsSinceEpoch}${path.extension(src).split('?').first}',
    );
    try {
      final downloadedBytes = await _storage.refFromURL(src).getData();
      if (downloadedBytes == null) {
        throw "Unable to read $src";
      }

      Uint8List bytes = downloadedBytes;

      // Decrypt if E2EE is enabled and file appears encrypted
      final e2ee = E2EEService.instance;
      final looksEncrypted = FileEncryption.looksEncrypted(bytes);

      if (looksEncrypted) {
        if (!e2ee.isReady) {
          AppLogger.log(
            "Cannot decrypt attachment - E2EE not ready: $localPath",
          );
          // Fail download, will retry when E2EE is ready
          return FileDownloadResult(DownloadResult.temporaryFailure);
        }

        final umk = e2ee.deviceManager.getUMK();
        if (umk == null) {
          AppLogger.log(
            "Cannot decrypt attachment - UMK not available: $localPath",
          );
          // Fail download, will retry when UMK is available
          return FileDownloadResult(DownloadResult.temporaryFailure);
        }

        try {
          bytes = await FileEncryption.decryptBytes(bytes, umk);
          AppLogger.log("Decrypted attachment: $localPath");
        } catch (e) {
          AppLogger.log("Failed to decrypt attachment: $e - will retry later");
          // Fail download rather than save encrypted garbage
          return FileDownloadResult(DownloadResult.temporaryFailure);
        }
      }

      await fs.writeBytes(localPath, bytes);

      // Track the downloaded file
      final newSync = FileSyncTrack(
        localPath: localPath,
        remotePath: src,
        noteId: note.id!,
      );
      await newSync.save();

      return FileDownloadResult(DownloadResult.success, localPath);
    } on FirebaseException catch (e) {
      AppLogger.log("Failed to download from $src: ${e.code} ${e.message}");
      // If object doesn't exist on remote, this is a permanent failure
      if (e.code == 'object-not-found') {
        final existingSync = await FileSyncTrack.getByRemotePath(src);
        if (existingSync != null) {
          await existingSync.delete();
        }
        return FileDownloadResult(DownloadResult.permanentFailure);
      }
      // Other Firebase errors are temporary (network issues, etc.)
      return FileDownloadResult(DownloadResult.temporaryFailure);
    } catch (e) {
      AppLogger.error('Failed to download attachment', e);
      return FileDownloadResult(DownloadResult.temporaryFailure);
    }
  }

  /// Encrypts note data if E2EE is enabled.
  Future<Map<String, dynamic>> _encryptNoteData(
    Map<String, dynamic> noteData,
  ) async {
    final e2ee = E2EEService.instance;
    if (!e2ee.isReady) return noteData;

    final title = noteData['title'] as String?;
    final content = noteData['content'] as String?;

    if (title == null && content == null) return noteData;

    final encrypted = await e2ee.noteEncryption.encryptNote(
      title: title,
      content: content,
    );

    if (encrypted == null) return noteData;

    // Remove plaintext fields and add encrypted fields
    final result = Map<String, dynamic>.from(noteData);
    result.remove('title');
    result.remove('content');
    result.remove('plain_text');
    result.addAll(encrypted.toFirestore());

    return result;
  }

  /// Decrypts note data if it contains E2EE encrypted content.
  Future<Map<String, dynamic>> _decryptNoteData(
    Map<String, dynamic> noteData,
  ) async {
    final e2ee = E2EEService.instance;

    // Check if data is encrypted
    if (!noteData.containsKey('e2ee_ciphertext')) {
      return noteData;
    }

    if (!e2ee.isReady) {
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

      return result;
    } catch (e) {
      AppLogger.error('E2EE: Failed to decrypt note', e);
      return noteData;
    }
  }

  /// Verifies that a remote file still exists in Firebase Storage.
  /// Returns true if the file exists, false if it doesn't or on error.
  Future<bool> _verifyRemoteFileExists(String remoteUrl) async {
    try {
      final ref = FirebaseStorage.instance.refFromURL(remoteUrl);
      await ref.getMetadata();
      return true;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') {
        return false;
      }
      // For other errors (network issues, etc.), assume file exists to avoid unnecessary re-uploads
      AppLogger.error('Error verifying remote file exists', e);
      return true;
    } catch (e) {
      AppLogger.error('Error verifying remote file', e);
      return true;
    }
  }

  /// Re-downloads a file from its remote URL if the local file is missing or corrupted.
  /// Returns the local path if successful, null otherwise.
  /// This is useful for recovering images that fail to load.
  Future<String?> redownloadFile(String localPath) async {
    try {
      final sync = await FileSyncTrack.getByLocalPath(localPath);
      if (sync == null || sync.remotePath == null) {
        AppLogger.log(
          "Cannot redownload file: no sync record found for $localPath",
        );
        return null;
      }

      final fs = await fileSystem();
      final remoteUrl = sync.remotePath!;

      AppLogger.log("Attempting to redownload file from $remoteUrl");

      try {
        final downloadedBytes = await _storage.refFromURL(remoteUrl).getData();
        if (downloadedBytes == null) {
          AppLogger.log("Unable to read remote file: $remoteUrl");
          return null;
        }

        Uint8List bytes = downloadedBytes;

        // Decrypt if E2EE is enabled and file appears encrypted
        final e2ee = E2EEService.instance;
        final looksEncrypted = FileEncryption.looksEncrypted(bytes);

        if (looksEncrypted) {
          if (!e2ee.isReady) {
            AppLogger.log("Cannot decrypt redownloaded file - E2EE not ready");
            return null;
          }

          final umk = e2ee.deviceManager.getUMK();
          if (umk == null) {
            AppLogger.log(
              "Cannot decrypt redownloaded file - UMK not available",
            );
            return null;
          }

          try {
            bytes = await FileEncryption.decryptBytes(bytes, umk);
            AppLogger.log("Decrypted redownloaded file: $localPath");
          } catch (e) {
            AppLogger.log("Failed to decrypt redownloaded file: $e");
            return null;
          }
        }

        await fs.writeBytes(localPath, bytes);
        AppLogger.log("Successfully redownloaded file to $localPath");

        return localPath;
      } on FirebaseException catch (e) {
        AppLogger.log("Failed to redownload file: ${e.code} ${e.message}");
        if (e.code == 'object-not-found') {
          // File no longer exists on remote - remove the sync record
          await sync.delete();
        }
        return null;
      }
    } catch (e) {
      AppLogger.error('Error redownloading file', e);
      return null;
    }
  }
}
