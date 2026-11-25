import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Shared by widget tests and the iOS integration runner. Only synthetic state;
// no Firebase initialization, accounts, provider credentials, or user files.
void syncStartupFeedbackCases() {
  final recovery = AuthService.cloudRecovery;
  final encryption = E2EEService.instance;
  late StreamController<FirebaseSyncSelection> selections;
  late FirebaseSyncPreference preference;
  late Completer<void> transferred;
  late int refreshes;
  late E2EEStatus oldStatus;
  late Uint8List? oldKey;
  late bool oldShowProgress;

  setUp(() {
    oldStatus = encryption.status.value;
    oldShowProgress = AppState.showSyncProgress;
    oldKey = encryption.deviceManager.getUMK();
    recovery.stop();
    recovery.setForeground(false);
    recovery.setNetworkAvailable(true);
    recovery.start('synthetic-startup');
    recovery.activity.value = CloudRecoveryActivity.verifying;
    selections = StreamController<FirebaseSyncSelection>.broadcast(sync: true);
    preference = FirebaseSyncPreference(
      currentUid: () => 'synthetic-startup',
      watch: (_) => selections.stream,
      write: (_, _) => throw UnimplementedError(),
    )..bind('synthetic-startup');
    FirebaseSyncPreference.instanceOverride = preference;
    AuthService.sessionInvalid.value = false;
    AuthService.postSignInState.value = PostSignInState.running(
      PostSignInStage.encryptionInitialization,
    );
    encryption.status.value = E2EEStatus.notInitialized;
    encryption.deviceManager.setCachedUMKForTesting(null);
    refreshes = 0;
    transferred = Completer<void>();
    NoteSyncService.refreshOperationOverride = () {
      refreshes++;
      return transferred.future;
    };
    LabelSyncService.refreshOperationOverride = () async {};
    NoteSortService.refreshOperationOverride = () async =>
        SyncRefreshOutcome.complete;
    NoteSyncService().isSyncing.value = false;
    LabelSyncService().isSyncing.value = false;
    NoteSyncService().syncStatus.value = SyncProgress.idle;
    LabelSyncService().syncStatus.value = SyncProgress.idle;
    NoteSortService().syncStatus.value = SyncProgress.idle;
    AppState.set('show_sync_progress', true);
  });

  tearDown(() async {
    recovery.stop();
    retrySyncStartupOverride = null;
    AppState.set('show_sync_progress', oldShowProgress);
    recovery.setNetworkAvailable(true);
    if (!transferred.isCompleted) transferred.complete();
    NoteSyncService.refreshOperationOverride = null;
    LabelSyncService.refreshOperationOverride = null;
    NoteSortService.refreshOperationOverride = null;
    AuthService.postSignInState.value = PostSignInState.idle;
    AuthService.sessionInvalid.value = false;
    encryption.status.value = oldStatus;
    encryption.deviceManager.setCachedUMKForTesting(oldKey);
    FirebaseSyncPreference.instanceOverride = null;
    preference.dispose();
    await selections.close();
  });

  Future<BuildContext> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                const SyncProgressWidget(),
                Align(
                  alignment: Alignment.topRight,
                  child: SyncRefreshButton(
                    onRefresh: () => refreshSyncFromUser(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return tester.element(find.byType(SyncProgressWidget));
  }

  void localReady() {
    encryption.deviceManager.setCachedUMKForTesting(Uint8List(32));
    encryption.status.value = E2EEStatus.ready;
    AuthService.postSignInState.value = PostSignInState.ready;
    selections.add(const FirebaseSyncSelection(true, confirmed: true));
  }

  testWidgets(
    'cold-start refresh waits, coalesces, and runs once after readiness',
    (tester) async {
      final context = await mount(tester);

      transferred = Completer<void>();
      var completed = false;
      final first = refreshSyncFromUser(context);
      first.then((_) => completed = true);
      expect(identical(first, refreshSyncFromUser(context)), isTrue);
      await tester.pump(const Duration(seconds: 12));
      expect(completed, isFalse);
      expect(refreshes, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Sync paused. Please retry.'), findsNothing);
      expect(SyncPresentation.instance.value.isActive, isTrue);

      localReady();
      await tester.pump();
      expect(completed, isFalse);
      expect(refreshes, 0); // Server verification has not completed yet.
      recovery.state.value = CloudSessionState.ready;
      await tester.pump();
      expect(refreshes, 1);
      expect(completed, isFalse); // Wait for actual sync, not just startup.

      transferred.complete();
      await tester.pump();

      await first;
      expect(completed, isTrue);
      expect(refreshes, 1);
      expect(SyncPresentation.instance.value.phase, SyncPhase.complete);
      expect(find.text('Sync paused. Please retry.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final stalled in ['startup', 'settings', 'verification']) {
    testWidgets('stalled $stalled releases refresh with a working Retry', (
      tester,
    ) async {
      final context = await mount(tester);
      if (stalled != 'startup') {
        encryption.deviceManager.setCachedUMKForTesting(Uint8List(32));
        encryption.status.value = E2EEStatus.ready;
        AuthService.postSignInState.value = PostSignInState.ready;
        if (stalled == 'verification') {
          selections.add(const FirebaseSyncSelection(true, confirmed: true));
        }
      }
      var completed = false;
      final work = refreshSyncFromUser(context).then((_) => completed = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      await work;
      expect(completed, isTrue);
      expect(refreshes, 0);
      expect(SyncPresentation.instance.value.phase, SyncPhase.failed);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byType(SyncRefreshButton),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      recovery.activity.value = CloudRecoveryActivity.idle;
      expect(SyncPresentation.instance.value.phase, SyncPhase.failed);
      localReady();
      recovery.state.value = CloudSessionState.ready;
      transferred = Completer<void>()..complete();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('Retry'));
      await tester.pump();
      expect(refreshes, 1);
      expect(SyncPresentation.instance.value.phase, SyncPhase.complete);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Firebase outage does not bypass local startup readiness', (
    tester,
  ) async {
    final context = await mount(tester);
    recovery.state.value = CloudSessionState.unavailable;
    var completed = false;
    final work = refreshSyncFromUser(context).then((_) => completed = true);
    await tester.pump();
    expect(completed, isFalse);
    expect(refreshes, 0);
    localReady();
    transferred = Completer<void>()..complete();
    await tester.pump();
    await work;
    expect(refreshes, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('recoverable startup failure retries once before refreshing', (
    tester,
  ) async {
    final context = await mount(tester);
    localReady();
    recovery.state.value = CloudSessionState.ready;
    AuthService.postSignInState.value = PostSignInState.recoverableFailure(
      PostSignInStage.encryptionInitialization,
      operation: 'restore-local-encryption',
    );
    var retries = 0;
    final retried = Completer<void>();
    retrySyncStartupOverride = () async {
      retries++;
      await retried.future;
      AuthService.postSignInState.value = PostSignInState.ready;
    };
    final work = refreshSyncFromUser(context);
    expect(identical(work, refreshSyncFromUser(context)), isTrue);
    await tester.pump();
    expect(retries, 1);
    expect(refreshes, 0);
    selections.add(
      const FirebaseSyncSelection(true, confirmed: true, revision: 1),
    );
    await tester.pump();
    expect(SyncPresentation.instance.value.isActive, isTrue);
    expect(find.text('Sync paused. Please retry.'), findsNothing);
    transferred = Completer<void>()..complete();
    retried.complete();
    await tester.pump();
    await work;
    expect(refreshes, 1);
    expect(retries, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed startup retry offers Retry instead of a paused loop', (
    tester,
  ) async {
    final context = await mount(tester);
    localReady();
    recovery.state.value = CloudSessionState.ready;
    AuthService.postSignInState.value = PostSignInState.recoverableFailure(
      PostSignInStage.encryptionInitialization,
      operation: 'restore-local-encryption',
    );
    retrySyncStartupOverride = () async =>
        throw StateError('synthetic startup failure');
    final work = refreshSyncFromUser(context);
    await tester.pump();
    await work;
    expect(refreshes, 0);
    expect(SyncPresentation.instance.value.phase, SyncPhase.failed);
    expect(find.text('Sync paused. Please retry.'), findsNothing);
    await tester.pump();
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refresh joins a restore that starts during startup', (
    tester,
  ) async {
    final context = await mount(tester);
    var completed = false;
    final work = refreshSyncFromUser(context).then((_) => completed = true);
    await tester.pump();
    final batch = NoteSyncBatch();
    final restored = Completer<void>();
    final restoring = batch.run(
      30,
      (_) => restored.future,
      isEmptyLibrary: () async => true,
    );
    await tester.pump();
    expect(NoteSyncBatch.active.value, isTrue);
    localReady();
    recovery.state.value = CloudSessionState.ready;
    await tester.pump();
    expect(refreshes, 0);
    expect(completed, isFalse);
    restored.complete();
    await tester.pump();
    await restoring;
    await work;
    expect(refreshes, 0);
    expect(completed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reason in ['approval', 'sign-in']) {
    testWidgets(
      'queued refresh surfaces $reason without waiting for settings',
      (tester) async {
        final context = await mount(tester);
        final work = refreshSyncFromUser(context);
        await tester.pump();
        if (reason == 'approval') {
          encryption.status.value = E2EEStatus.pendingApproval;
        } else {
          AuthService.sessionInvalid.value = true;
        }
        await tester.pump();
        await work;
        expect(refreshes, 0);
        expect(
          SyncPresentation.instance.value.phase,
          reason == 'approval'
              ? SyncPhase.waitingForApproval
              : SyncPhase.signInRequired,
        );
        expect(find.text('Sync failed'), findsNothing);
        expect(find.text('Sync paused. Please retry.'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final reason in ['account changed', 'offline']) {
    testWidgets('queued refresh exits quietly when $reason', (tester) async {
      final context = await mount(tester);
      final work = refreshSyncFromUser(context);
      await tester.pump();
      if (reason == 'account changed') {
        recovery.stop();
      } else {
        recovery.setNetworkAvailable(false);
      }
      await tester.pump();
      await work;
      expect(refreshes, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Sync paused. Please retry.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
