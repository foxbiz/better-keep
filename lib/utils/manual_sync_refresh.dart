import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/widgets.dart';

Future<void>? _manualRefresh;

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
  if (noteOutcome == SyncRefreshOutcome.unavailable ||
      noteOutcome == SyncRefreshOutcome.deferred) {
    return noteOutcome;
  }
  final labelOutcome = await attempt(labels);
  return combineSyncRefreshOutcomes([noteOutcome, labelOutcome]);
}

/// Feedback belongs only to user actions, never to automatic sync retries.
Future<void> refreshSyncFromUser(BuildContext context) {
  final running = _manualRefresh;
  if (running != null) return running;
  final current = AuthService.captureSessionIdentity();
  late final Future<void> operation;
  operation =
      (() async {
        final outcome = await runManualSyncRefresh(
          notes: () => NoteSyncService().refreshWithOutcome(manual: true),
          labels: () => LabelSyncService().refreshWithOutcome(),
        );
        if (current() && context.mounted) {
          showSyncRefreshFeedback(context, outcome);
        }
      })().whenComplete(() {
        if (identical(_manualRefresh, operation)) _manualRefresh = null;
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
            : E2EEService.instance.isCryptoReady
            ? context.l10n.syncFailed
            : context.l10n.e2eeNotReady,
      );
    case SyncRefreshOutcome.failed:
      snackbar(context.l10n.syncFailed);
    case SyncRefreshOutcome.complete:
      break;
  }
}
