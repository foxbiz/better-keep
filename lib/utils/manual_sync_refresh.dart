import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/widgets.dart';

Future<void>? _manualRefresh;
bool Function()? _manualRefreshCurrent;

/// Retains separate outcomes instead of inferring success from global status.
Future<SyncRefreshOutcome> runManualSyncRefresh({
  required Future<SyncRefreshOutcome> Function() notes,
  required Future<SyncRefreshOutcome> Function() labels,
}) async {
  Future<SyncRefreshOutcome> attempt(
    Future<SyncRefreshOutcome> Function() action,
  ) async {
    try {
      return await action();
    } on CloudOperationCancelled {
      return SyncRefreshOutcome.deferred;
    } catch (error) {
      return isCloudConnectionFailure(error)
          ? SyncRefreshOutcome.unavailable
          : SyncRefreshOutcome.failed;
    }
  }

  final noteOutcome = await attempt(notes);
  if (noteOutcome == SyncRefreshOutcome.unavailable) {
    return noteOutcome;
  }
  final labelOutcome = await attempt(labels);
  return combineSyncRefreshOutcomes([noteOutcome, labelOutcome]);
}

/// Feedback belongs only to user actions, never to automatic sync retries.
Future<void> refreshSyncFromUser(BuildContext context) {
  final running = _manualRefresh;
  if (running != null && _manualRefreshCurrent?.call() == true) return running;
  final accountCurrent = AuthService.captureSessionIdentity();
  final revision = AuthService.cloudRecovery.sessionRevision.value;
  bool current() =>
      accountCurrent() &&
      revision == AuthService.cloudRecovery.sessionRevision.value;
  _manualRefreshCurrent = current;
  final presentation = SyncPresentation.instance;
  final request = presentation.beginManual(current);
  late final Future<void> operation;
  operation =
      (() async {
        final outcome = await runManualSyncRefresh(
          notes: () => NoteSyncService().refreshWithOutcome(manual: true),
          labels: () => current()
              ? LabelSyncService().refreshWithOutcome()
              : Future.value(SyncRefreshOutcome.deferred),
        );
        presentation.finishManual(request, outcome);
        if (current() && context.mounted) {
          showSyncRefreshFeedback(context, outcome);
        }
      })().whenComplete(() {
        if (identical(_manualRefresh, operation)) {
          _manualRefresh = null;
          _manualRefreshCurrent = null;
        }
      });
  _manualRefresh = operation;
  return operation;
}

void showSyncRefreshFeedback(BuildContext context, SyncRefreshOutcome outcome) {
  if (!context.mounted) return;
  switch (outcome) {
    case SyncRefreshOutcome.unavailable:
      snackbar(context.l10n.noConnectionAvailable);
    case SyncRefreshOutcome.deferred:
      snackbar(
        AuthService.sessionInvalid.value
            ? context.l10n.pleaseSignInAgain
            : E2EEService.instance.status.value == E2EEStatus.pendingApproval
            ? context.l10n.waitingForDeviceApproval
            : E2EEService.instance.isCryptoReady
            ? context.l10n.syncPaused
            : context.l10n.e2eeNotReady,
      );
    case SyncRefreshOutcome.failed:
      snackbar(context.l10n.syncFailed);
    case SyncRefreshOutcome.complete:
      if (!AppState.showSyncProgress) snackbar(context.l10n.syncComplete);
    case SyncRefreshOutcome.uploadRestricted:
      if (!AppState.showSyncProgress) {
        snackbar(context.l10n.syncUploadRestricted);
      }
  }
}
