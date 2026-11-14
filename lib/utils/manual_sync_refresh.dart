import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/external_sync/external_sync_service.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
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
  Future<SyncRefreshOutcome?> Function()? external,
  Future<SyncRefreshOutcome> Function()? ordering,
  bool firebaseEnabled = true,
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

  Future<SyncRefreshOutcome> firebase() async {
    final noteOutcome = await attempt(notes);
    if (noteOutcome == SyncRefreshOutcome.unavailable) return noteOutcome;
    final labelOutcome = await attempt(labels);
    final outcomes = [noteOutcome, labelOutcome];
    if (ordering != null &&
        outcomes.every(
          (outcome) =>
              outcome == SyncRefreshOutcome.complete ||
              outcome == SyncRefreshOutcome.uploadRestricted,
        )) {
      outcomes.add(await attempt(ordering));
    }
    return combineSyncRefreshOutcomes(outcomes);
  }

  Future<SyncRefreshOutcome?> providers() async {
    try {
      return await external!();
    } on CloudOperationCancelled {
      return SyncRefreshOutcome.deferred;
    } catch (error) {
      return isCloudConnectionFailure(error)
          ? SyncRefreshOutcome.unavailable
          : SyncRefreshOutcome.failed;
    }
  }

  final results = await Future.wait<SyncRefreshOutcome?>([
    if (firebaseEnabled) firebase(),
    if (external != null) providers(),
  ]);
  final outcomes = results.whereType<SyncRefreshOutcome>().toList();
  return outcomes.isEmpty
      ? SyncRefreshOutcome.deferred
      : combineSyncRefreshOutcomes(outcomes);
}

/// Feedback belongs only to user actions, never to automatic sync retries.
Future<void> refreshSyncFromUser(BuildContext context) {
  if (!AuthService.cloudRecovery.networkAvailable) return Future.value();
  final running = _manualRefresh;
  if (running != null && _manualRefreshCurrent?.call() == true) return running;
  if (NoteSyncBatch.active.value) return Future.value();
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
        final preference = FirebaseSyncPreference.instance;
        if (preference.loading && !await preference.waitForSelection()) {
          if (!current()) return;
          final outcome =
              AuthService.cloudRecovery.networkAvailable &&
                  AuthService.cloudRecovery.state.value !=
                      CloudSessionState.unavailable
              ? SyncRefreshOutcome.failed
              : SyncRefreshOutcome.unavailable;
          presentation.finishManual(request, outcome);
          if (context.mounted) showSyncRefreshFeedback(context, outcome);
          return;
        }
        if (!current()) return;
        final selected = preference.selectedProvider;
        final outcome = await runManualSyncRefresh(
          firebaseEnabled:
              !preference.stoppedLocally &&
              (preference.selectedProvider == null ||
                  preference.allowsDownload(preference.accountId)),
          ordering: () => current()
              ? NoteSortService().refreshWithOutcome(dataHydrated: true)
              : Future.value(SyncRefreshOutcome.deferred),
          external:
              selected == null || selected == 'firebase' || selected == 'none'
              ? null
              : () => current()
                    ? ExternalSyncService.instance.refreshWithOutcome()
                    : Future.value(SyncRefreshOutcome.deferred),
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
      return;
    case SyncRefreshOutcome.deferred:
      if (SyncPresentation.instance.value.isActive ||
          AuthService.cloudRecovery.state.value ==
              CloudSessionState.unavailable) {
        return;
      }
      final chooseProvider =
          !AuthService.sessionInvalid.value &&
          E2EEService.instance.status.value != E2EEStatus.pendingApproval &&
          FirebaseSyncPreference.instance.allTransfersPaused;
      // The status pill already explains this deliberate pause.
      if (chooseProvider && AppState.showSyncProgress) return;
      snackbar(
        AuthService.sessionInvalid.value
            ? context.l10n.pleaseSignInAgain
            : E2EEService.instance.status.value == E2EEStatus.pendingApproval
            ? context.l10n.waitingForDeviceApproval
            : chooseProvider
            ? context.l10n.externalSyncDescription
            : E2EEService.instance.isCryptoReady
            ? context.l10n.syncPaused
            : context.l10n.e2eeNotReady,
      );
    case SyncRefreshOutcome.failed:
      if (AppState.showSyncProgress &&
          ModalRoute.of(context)?.isCurrent == true &&
          SyncPresentation.instance.value.isFailure) {
        return;
      }
      final accountCurrent = AuthService.captureSessionIdentity();
      snackbarWithAction(
        context.l10n.syncFailed,
        actionLabel: context.l10n.retry,
        onAction: () {
          if (context.mounted && accountCurrent()) refreshSyncFromUser(context);
        },
      );
    case SyncRefreshOutcome.complete:
      if (!AppState.showSyncProgress) snackbar(context.l10n.syncComplete);
    case SyncRefreshOutcome.uploadRestricted:
      if (!AppState.showSyncProgress) {
        snackbar(
          const SyncProgress(SyncPhase.uploadRestricted).localized(
            context.l10n,
            cloudUploadsRequirePro:
                !PlanService.instance.entitlements.realtimeCloudSync,
          ),
        );
      }
  }
}
