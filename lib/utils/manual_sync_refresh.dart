import 'dart:async';

import 'package:better_keep/pages/home/note_pane.dart';
import 'package:better_keep/utils/logger.dart';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/pages/settings/sync_issues_page.dart';
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

@visibleForTesting
Future<void> Function()? retrySyncStartupOverride;

bool get _syncNeedsUserAction =>
    AuthService.sessionInvalid.value ||
    e2eeStatusRequiresUserAction(E2EEService.instance.status.value);

Future<bool> _waitForSyncStartup(bool Function() current) async {
  final recovery = AuthService.cloudRecovery;
  final encryption = E2EEService.instance;
  final preference = FirebaseSyncPreference.instance;
  final changes = Listenable.merge([
    recovery.state,
    recovery.sessionRevision,
    AuthService.postSignInState,
    AuthService.sessionInvalid,
    encryption.status,
    encryption.deviceManager.hasUMK,
    preference,
  ]);
  final ready = Completer<bool>();
  var verificationRequested = false;
  var retryRequested = false;
  var retrying = false;
  var retryFailed = false;
  void changed() {
    if (ready.isCompleted) return;
    if (!current() ||
        !recovery.hasSession ||
        !recovery.networkAvailable ||
        _syncNeedsUserAction) {
      ready.complete(true);
      return;
    }
    final startup = AuthService.postSignInState.value;
    if (startup.hasRecoverableFailure && !retryRequested) {
      retryRequested = true;
      retrying = true;
      unawaited(
        Future<void>.sync(
              retrySyncStartupOverride ??
                  AuthService.retryPostSignInInitialization,
            )
            .catchError((Object error, StackTrace stack) {
              retryFailed = true;
              AppLogger.error('[SYNC] Startup retry failed', error, stack);
            })
            .whenComplete(() {
              retrying = false;
              changed();
            }),
      );
    }
    if (retrying) return;
    if (retryFailed || startup.hasRecoverableFailure) {
      ready.complete(false);
      return;
    }
    if (startup.isRunning || !encryption.isCryptoReady) return;
    if (preference.failed) {
      ready.complete(false);
      return;
    }
    if (preference.loading) return;
    final firebase =
        preference.selectedProvider == null ||
        preference.allowsDownload(preference.accountId);
    if (firebase && recovery.state.value == CloudSessionState.pending) {
      if (!verificationRequested &&
          recovery.activity.value == CloudRecoveryActivity.idle) {
        verificationRequested = true;
        unawaited(recovery.check());
      }
      return;
    }
    ready.complete(true);
  }

  changes.addListener(changed);
  AppLogger.log('[SYNC] Waiting for manual refresh startup');
  try {
    changed();
    return await ready.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        AppLogger.log('[SYNC] Manual refresh startup timed out');
        ready.complete(false);
        return false;
      },
    );
  } finally {
    changes.removeListener(changed);
    AppLogger.log('[SYNC] Manual refresh startup wait released');
  }
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
        final startupReady = await _waitForSyncStartup(current);
        if (!current()) return;
        if (!AuthService.cloudRecovery.networkAvailable) {
          presentation.finishManual(request, SyncRefreshOutcome.unavailable);
          return;
        }
        if (_syncNeedsUserAction) {
          presentation.finishManual(request, SyncRefreshOutcome.deferred);
          if (context.mounted) {
            showSyncRefreshFeedback(context, SyncRefreshOutcome.deferred);
          }
          return;
        }
        if (!startupReady) {
          presentation.finishManual(
            request,
            SyncRefreshOutcome.failed,
            startupFailed: true,
          );
          if (context.mounted) {
            showSyncRefreshFeedback(context, SyncRefreshOutcome.failed);
          }
          return;
        }
        final restore = NoteSyncBatch.pending;
        if (restore != null) {
          presentation.finishManual(request, SyncRefreshOutcome.deferred);
          await restore;
          return;
        }
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
    case SyncRefreshOutcome.localStorageFailure:
    case SyncRefreshOutcome.sourceReadFailure:
    case SyncRefreshOutcome.notesNeedAttention:
    case SyncRefreshOutcome.retryScheduled:
      if (AppState.showSyncProgress &&
          (ModalRoute.of(context)?.isCurrent == true ||
              NotePaneHost.isSideBySide(context)) &&
          (SyncPresentation.instance.value.isFailure ||
              SyncPresentation.instance.value.phase ==
                  SyncPhase.retryScheduled)) {
        return;
      }
      final accountCurrent = AuthService.captureSessionIdentity();
      snackbarWithAction(
        outcome == SyncRefreshOutcome.localStorageFailure
            ? context.l10n.externalSyncFailure('localStorage')
            : outcome == SyncRefreshOutcome.sourceReadFailure
            ? context.l10n.externalSyncFailure('sourceRead')
            : outcome == SyncRefreshOutcome.notesNeedAttention
            ? context.l10n.externalSyncBlocked
            : outcome == SyncRefreshOutcome.retryScheduled
            ? context.l10n.syncRetryScheduled
            : context.l10n.syncFailed,
        actionLabel:
            outcome == SyncRefreshOutcome.sourceReadFailure ||
                outcome == SyncRefreshOutcome.notesNeedAttention
            ? context.l10n.syncViewNotes
            : outcome == SyncRefreshOutcome.retryScheduled
            ? context.l10n.syncRetryNow
            : context.l10n.retry,
        onAction: () {
          if (!context.mounted || !accountCurrent()) return;
          if (outcome == SyncRefreshOutcome.sourceReadFailure ||
              outcome == SyncRefreshOutcome.notesNeedAttention) {
            showSyncIssuesPage(context);
          } else {
            refreshSyncFromUser(context);
          }
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
