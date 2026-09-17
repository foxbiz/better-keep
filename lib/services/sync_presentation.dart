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
  }) : super(SyncProgress.idle) {
    _sources = Listenable.merge([
      recovery.state,
      recovery.activity,
      noteBusy,
      labelBusy,
      noteStatus,
      labelStatus,
      noteFailures,
      labelFailures,
      sessionInvalid,
      encryptionStatus,
      postSignInState,
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
    labelStatus: LabelSyncService().syncStatus,
    noteFailures: NoteSyncService().syncFailed,
    labelFailures: LabelSyncService().syncFailed,
    sessionInvalid: AuthService.sessionInvalid,
    encryptionStatus: E2EEService.instance.status,
    postSignInState: AuthService.postSignInState,
  );

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
  bool get isManualRefresh => _manual != null && _current?.call() == true;

  Object beginManual(bool Function() current) {
    final request = Object();
    _manual = request;
    _current = current;
    // Acknowledge the gesture synchronously, before verification or init awaits.
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
    _update();
  }

  void _update({SyncProgress? completion}) {
    if (_current != null && !_current!()) _resetSession();
    final manual = _manual != null;
    if (!manual && !recovery.hasSession) {
      value = completion ?? SyncProgress.idle;
      return;
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
    final transferring = noteBusy.value || labelBusy.value;
    final activity = recovery.activity.value;
    final cloud = recovery.state.value;
    if (transferring && cloud == CloudSessionState.ready) {
      value = const SyncProgress(SyncPhase.syncing);
    } else if (activity == CloudRecoveryActivity.verifying &&
        (manual || cloud != CloudSessionState.ready)) {
      value = const SyncProgress(SyncPhase.checkingConnection);
    } else if (sessionInvalid.value) {
      value = const SyncProgress(SyncPhase.signInRequired);
    } else if (cloud == CloudSessionState.unavailable) {
      value = const SyncProgress(SyncPhase.unavailable);
    } else if (cloud == CloudSessionState.blocked ||
        const {
          E2EEStatus.pendingApproval,
          E2EEStatus.revoked,
          E2EEStatus.needsRecovery,
          E2EEStatus.error,
        }.contains(encryptionStatus.value) ||
        postSignInState.value.hasRecoverableFailure) {
      value = SyncProgress(_waitingPhase);
    } else if (completion != null && !completion.isSuccess) {
      value = completion;
    } else if (postSignInState.value.isRunning ||
        activity == CloudRecoveryActivity.resuming ||
        cloud == CloudSessionState.pending) {
      value = const SyncProgress(SyncPhase.preparing);
    } else if (completion != null) {
      value = completion;
    } else if (manual) {
      value = const SyncProgress(SyncPhase.preparing);
    } else {
      final failures = noteFailures.value.length + labelFailures.value.length;
      final statuses = [noteStatus.value, labelStatus.value];
      value = failures > 0 || statuses.any((status) => status.isFailure)
          ? SyncProgress(SyncPhase.failed, failedCount: failures)
          : _noteUploadRestricted || _labelUploadRestricted
          ? const SyncProgress(SyncPhase.uploadRestricted)
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
