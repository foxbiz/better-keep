import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/external_sync/external_sync_service.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:flutter/foundation.dart';

/// One presentation of verification, manual refresh, and both sync services.
/// This observes work; it never changes authorization or starts cloud requests.
class SyncPresentation extends ValueNotifier<SyncProgress> {
  SyncPresentation({
    required this.recovery,
    required this.noteBusy,
    required this.labelBusy,
    required this.noteStatus,
    required this.labelStatus,
    required this.noteFailures,
    required this.labelFailures,
    required this.sessionInvalid,
    required this.encryptionStatus,
    required this.postSignInState,
    this.orderStatus,
    this.externalChanges,
    this.externalProgress,
    this.firebaseChanges,
    this.firebaseSelected,
  }) : super(SyncProgress.idle) {
    _sources = Listenable.merge([
      recovery.state,
      recovery.activity,
      noteBusy,
      labelBusy,
      noteStatus,
      labelStatus,
      orderStatus,
      noteFailures,
      labelFailures,
      sessionInvalid,
      encryptionStatus,
      postSignInState,
      externalChanges,
      firebaseChanges,
    ]);
    _sources.addListener(_update);
    recovery.sessionRevision.addListener(_resetSession);
    _update();
  }

  static final instance = SyncPresentation(
    recovery: AuthService.cloudRecovery,
    noteBusy: NoteSyncService().isSyncing,
    labelBusy: LabelSyncService().isSyncing,
    noteStatus: NoteSyncService().syncStatus,
    orderStatus: NoteSortService().syncStatus,
    labelStatus: LabelSyncService().syncStatus,
    noteFailures: NoteSyncService().syncFailed,
    labelFailures: LabelSyncService().syncFailed,
    sessionInvalid: AuthService.sessionInvalid,
    encryptionStatus: E2EEService.instance.status,
    postSignInState: AuthService.postSignInState,
    externalChanges: ExternalSyncService.instance,
    externalProgress: () => ExternalSyncService.instance.progress,
    firebaseChanges: FirebaseSyncPreference.instance,
    firebaseSelected: () =>
        !FirebaseSyncPreference.instance.stoppedLocally &&
        (FirebaseSyncPreference.instance.selectedProvider == null ||
            FirebaseSyncPreference.instance.allowsDownload(
              FirebaseSyncPreference.instance.accountId,
            )),
  );

  final ValueListenable<SyncProgress>? orderStatus;
  final Listenable? externalChanges, firebaseChanges;
  final SyncProgress Function()? externalProgress;
  final bool Function()? firebaseSelected;
  final CloudSessionRecovery recovery;
  final ValueListenable<bool> noteBusy, labelBusy, sessionInvalid;
  final ValueListenable<SyncProgress> noteStatus, labelStatus;
  final ValueListenable<Set<int>> noteFailures, labelFailures;
  final ValueListenable<E2EEStatus> encryptionStatus;
  final ValueListenable<PostSignInState> postSignInState;
  late final Listenable _sources;
  Object? _manual;
  bool Function()? _current;
  bool _noteUploadRestricted = false;
  bool _labelUploadRestricted = false;
  bool _orderUploadRestricted = false;
  bool get isManualRefresh => _manual != null && _current?.call() == true;

  /// A restored account can use Home while its first server check runs.
  /// Keep that check quiet in a populated library, but avoid offering to
  /// create a first note while the empty library is still being verified.
  SyncProgress get emptyLibraryProgress {
    if (value.isEmpty &&
        recovery.hasSession &&
        recovery.networkAvailable &&
        recovery.state.value == CloudSessionState.pending &&
        recovery.activity.value == CloudRecoveryActivity.verifying &&
        !sessionInvalid.value &&
        e2eeStatusCanAccessLocalNotes(encryptionStatus.value)) {
      return const SyncProgress(SyncPhase.preparing);
    }
    return value;
  }

  Object beginManual(bool Function() current) {
    final request = Object();
    _manual = request;
    _current = current;
    // Acknowledge the gesture synchronously, before verification or init awaits.
    if (value.notes != null && value.isActive) return request;
    final alreadyChecking = value.phase == SyncPhase.checkingConnection;
    value = const SyncProgress(SyncPhase.checkingConnection);
    if (alreadyChecking) notifyListeners();
    return request;
  }

  void finishManual(Object request, SyncRefreshOutcome outcome) {
    if (!identical(_manual, request) || _current?.call() != true) return;
    _manual = null;
    // Publish this outcome once; later service events resolve live state.
    _update(
      completion: SyncProgress(switch (outcome) {
        SyncRefreshOutcome.complete => SyncPhase.complete,
        SyncRefreshOutcome.uploadRestricted => SyncPhase.uploadRestricted,
        SyncRefreshOutcome.unavailable => SyncPhase.unavailable,
        SyncRefreshOutcome.failed => SyncPhase.failed,
        SyncRefreshOutcome.deferred => _waitingPhase,
      }),
    );
  }

  SyncPhase get _waitingPhase => sessionInvalid.value
      ? SyncPhase.signInRequired
      : encryptionStatus.value == E2EEStatus.pendingApproval
      ? SyncPhase.waitingForApproval
      : SyncPhase.deferred;

  void _resetSession() {
    _manual = null;
    _current = null;
    _noteUploadRestricted = false;
    _labelUploadRestricted = false;
    _orderUploadRestricted = false;
    _update();
  }

  void _update({SyncProgress? completion}) {
    if (_current != null && !_current!()) {
      _resetSession();
      return;
    }
    final firebase = firebaseSelected?.call() ?? true;
    if (!firebase) {
      _noteUploadRestricted = _labelUploadRestricted = _orderUploadRestricted =
          false;
    }
    final cloud = firebase
        ? _firebaseProgress(completion: completion)
        : SyncProgress.idle;
    final external = externalProgress?.call() ?? SyncProgress.idle;
    final localAccess = e2eeStatusCanAccessLocalNotes(encryptionStatus.value);
    final backgroundCheck =
        recovery.state.value == CloudSessionState.pending &&
        !isManualRefresh &&
        postSignInState.value == PostSignInState.ready;
    if (localAccess &&
        !sessionInvalid.value &&
        ((recovery.state.value == CloudSessionState.unavailable &&
                (!isManualRefresh || !recovery.networkAvailable)) ||
            backgroundCheck) &&
        (completion == null ||
            completion.phase == SyncPhase.unavailable ||
            completion.phase == SyncPhase.deferred)) {
      // An external provider can still be reachable during a Firebase outage.
      value =
          recovery.networkAvailable &&
              (external.phase == SyncPhase.syncing ||
                  (!firebase &&
                      (external.isSuccess ||
                          (backgroundCheck && external.isActive))))
          ? external
          : SyncProgress.idle;
      return;
    }
    final states = [cloud, external];
    if (states.any((s) => s.phase == SyncPhase.syncing)) {
      value =
          external.phase == SyncPhase.syncing &&
              (cloud.phase != SyncPhase.syncing ||
                  external.notes != null ||
                  cloud.notes == null)
          ? external
          : cloud;
    } else if (sessionInvalid.value &&
        (recovery.hasSession || !external.isEmpty)) {
      value = const SyncProgress(SyncPhase.signInRequired);
    } else if (states.any((s) => s.phase == SyncPhase.storageFull)) {
      value = const SyncProgress(SyncPhase.storageFull);
    } else if (states.any((s) => s.isFailure)) {
      value = SyncProgress(
        SyncPhase.failed,
        failedCount: cloud.failedCount + external.failedCount,
      );
    } else if (states.any((s) => s.phase == SyncPhase.unavailable)) {
      value = SyncProgress.idle;
    } else if (states.any((s) => s.isActive)) {
      value = states.firstWhere((s) => s.isActive);
    } else if (states.any(
      (s) => const {
        SyncPhase.waitingForApproval,
        SyncPhase.signInRequired,
        SyncPhase.providerSetupRequired,
        SyncPhase.deferred,
      }.contains(s.phase),
    )) {
      value = states.firstWhere(
        (s) => const {
          SyncPhase.waitingForApproval,
          SyncPhase.signInRequired,
          SyncPhase.providerSetupRequired,
          SyncPhase.deferred,
        }.contains(s.phase),
      );
    } else if (completion != null && !completion.isSuccess) {
      value = completion.phase == SyncPhase.unavailable
          ? SyncProgress.idle
          : completion;
    } else if (cloud.phase == SyncPhase.uploadRestricted) {
      value = cloud;
    } else if (isManualRefresh) {
      value = const SyncProgress(SyncPhase.preparing);
    } else {
      value =
          completion ??
          (states.any((s) => s.isSuccess)
              ? const SyncProgress(SyncPhase.complete)
              : SyncProgress.idle);
    }
  }

  SyncProgress _firebaseProgress({SyncProgress? completion}) {
    final manual = _manual != null;
    if (!manual && !recovery.hasSession) {
      return completion ?? SyncProgress.idle;
    }
    // Idle resets clear transient text, not an outstanding upload restriction.
    // Only that service's next completed refresh can clear its own restriction.
    if (noteStatus.value.phase == SyncPhase.uploadRestricted) {
      _noteUploadRestricted = true;
    } else if (noteStatus.value.isSuccess) {
      _noteUploadRestricted = false;
    }
    if (labelStatus.value.phase == SyncPhase.uploadRestricted) {
      _labelUploadRestricted = true;
    } else if (labelStatus.value.isSuccess) {
      _labelUploadRestricted = false;
    }
    if (orderStatus?.value.phase == SyncPhase.uploadRestricted) {
      _orderUploadRestricted = true;
    } else if (orderStatus?.value.isSuccess == true) {
      _orderUploadRestricted = false;
    }
    final transferring =
        noteBusy.value ||
        labelBusy.value ||
        orderStatus?.value.isActive == true;
    final activity = recovery.activity.value;
    final cloud = recovery.state.value;
    if (transferring && cloud == CloudSessionState.ready) {
      if (noteBusy.value &&
          (noteStatus.value.phase == SyncPhase.fetchingUpdates ||
              noteStatus.value.phase == SyncPhase.checkingForUpdates)) {
        return noteStatus.value;
      }
      return SyncProgress(
        SyncPhase.syncing,
        notes: noteBusy.value ? noteStatus.value.notes : null,
      );
    } else if (activity == CloudRecoveryActivity.verifying &&
        (manual || cloud != CloudSessionState.ready)) {
      return const SyncProgress(SyncPhase.checkingConnection);
    } else if (sessionInvalid.value) {
      return const SyncProgress(SyncPhase.signInRequired);
    } else if (cloud == CloudSessionState.unavailable) {
      return const SyncProgress(SyncPhase.unavailable);
    } else if (cloud == CloudSessionState.blocked ||
        const {
          E2EEStatus.pendingApproval,
          E2EEStatus.revoked,
          E2EEStatus.needsRecovery,
          E2EEStatus.error,
        }.contains(encryptionStatus.value) ||
        postSignInState.value.hasRecoverableFailure) {
      return SyncProgress(_waitingPhase);
    } else if (completion != null &&
        !completion.isSuccess &&
        completion.phase != SyncPhase.deferred) {
      return completion;
    } else if (postSignInState.value.isRunning ||
        activity == CloudRecoveryActivity.resuming ||
        cloud == CloudSessionState.pending) {
      return const SyncProgress(SyncPhase.preparing);
    } else if (completion != null) {
      return completion;
    } else if (manual) {
      return const SyncProgress(SyncPhase.preparing);
    } else {
      final failures = noteFailures.value.length + labelFailures.value.length;
      final statuses = [
        noteStatus.value,
        labelStatus.value,
        ?orderStatus?.value,
      ];
      return failures > 0 || statuses.any((status) => status.isFailure)
          ? SyncProgress(SyncPhase.failed, failedCount: failures)
          : _noteUploadRestricted ||
                _labelUploadRestricted ||
                _orderUploadRestricted
          ? const SyncProgress(SyncPhase.uploadRestricted)
          : orderStatus?.value.phase == SyncPhase.deferred
          ? const SyncProgress(SyncPhase.deferred)
          : statuses.firstWhere(
              (status) => status.isSuccess,
              orElse: () => SyncProgress.idle,
            );
    }
  }

  @override
  void dispose() {
    _sources.removeListener(_update);
    recovery.sessionRevision.removeListener(_resetSession);
    super.dispose();
  }
}
