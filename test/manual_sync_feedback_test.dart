import 'dart:async';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AuthService.cloudRecovery.stop();
    AuthService.cloudRecovery.setForeground(false);
    AppState.set('show_sync_progress', true);
    NoteSyncService().isSyncing.value = false;
    LabelSyncService().isSyncing.value = false;
    NoteSyncService().syncStatus.value = SyncProgress.idle;
    LabelSyncService().syncStatus.value = SyncProgress.idle;
  });
  tearDown(() {
    NoteSyncService.refreshOperationOverride = null;
    LabelSyncService.refreshOperationOverride = null;
    AuthService.cloudRecovery.stop();
  });

  Future<void> mountFeedback(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      scaffoldMessengerKey: AppState.scaffoldMessengerKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              SyncRefreshButton(onRefresh: () => refreshSyncFromUser(context)),
              const SyncProgressWidget(),
            ],
          ),
        ),
      ),
    ),
  );

  for (final cardEnabled in [true, false]) {
    testWidgets(
      'offline refresh shows one message with progress card $cardEnabled',
      (tester) async {
        final response = Completer<void>();
        var calls = 0;
        NoteSyncService.refreshOperationOverride = () {
          calls++;
          return response.future;
        };
        LabelSyncService.refreshOperationOverride = () async {};
        AppState.set('show_sync_progress', cardEnabled);
        await mountFeedback(tester);

        await tester.tap(find.byType(IconButton));
        await tester.tap(find.byType(IconButton));
        expect(calls, 1);
        response.completeError(TimeoutException('offline'));
        await tester.pumpAndSettle();

        expect(find.text('No connection available.'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('sync_progress')),
          cardEnabled ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(SnackBar),
          cardEnabled ? findsNothing : findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'post-login preparation remains visible with progress card $cardEnabled',
      (tester) async {
        final oldEncryption = E2EEService.instance.status.value;
        addTearDown(() {
          AuthService.postSignInState.value = PostSignInState.idle;
          E2EEService.instance.status.value = oldEncryption;
        });
        AppState.set('show_sync_progress', cardEnabled);
        E2EEService.instance.status.value = E2EEStatus.ready;
        AuthService.postSignInState.value = PostSignInState.running(
          PostSignInStage.auxiliaryServices,
        );
        AuthService.cloudRecovery.start('synthetic-account');
        await mountFeedback(tester);
        await tester.pump(const Duration(seconds: 10));
        expect(
          find.text('Preparing sync…'),
          cardEnabled ? findsOneWidget : findsNothing,
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Sync complete'), findsNothing);
        AuthService.cloudRecovery.state.value = CloudSessionState.ready;
        NoteSyncService().isSyncing.value = true;
        await tester.pump();
        expect(
          find.text('Syncing...'),
          cardEnabled ? findsOneWidget : findsNothing,
        );
        AuthService.postSignInState.value = PostSignInState.ready;
        NoteSyncService().syncStatus.value = const SyncProgress(
          SyncPhase.complete,
        );
        NoteSyncService().isSyncing.value = false;
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text('Sync complete'),
          cardEnabled ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'restricted result is visible with progress card $cardEnabled',
      (tester) async {
        tester.view.reset();
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        AppState.set('show_sync_progress', cardEnabled);
        await mountFeedback(tester);
        final context = tester.element(find.byType(SyncRefreshButton));
        final request = SyncPresentation.instance.beginManual(() => true);
        SyncPresentation.instance.finishManual(
          request,
          SyncRefreshOutcome.uploadRestricted,
        );
        showSyncRefreshFeedback(context, SyncRefreshOutcome.uploadRestricted);
        await tester.pumpAndSettle();
        expect(
          find.text('Changes saved on this device. Uploading requires Pro.'),
          findsOneWidget,
        );
        expect(find.text('Sync complete'), findsNothing);
        expect(
          find.byType(SnackBar),
          cardEnabled ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'first frame acknowledges refresh with progress card $cardEnabled',
      (tester) async {
        final notes = Completer<void>();
        final labels = Completer<void>();
        NoteSyncService.refreshOperationOverride = () => notes.future;
        LabelSyncService.refreshOperationOverride = () => labels.future;
        AppState.set('show_sync_progress', cardEnabled);
        await mountFeedback(tester);
        await tester.tap(find.byType(IconButton));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.text('Checking connection…'),
          cardEnabled ? findsOneWidget : findsNothing,
        );
        notes.complete();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Sync complete'), findsNothing);
        labels.complete();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Sync complete'), findsOneWidget);
        expect(
          find.byType(SnackBar),
          cardEnabled ? findsNothing : findsOneWidget,
        );
        await tester.pumpAndSettle(const Duration(seconds: 4));
      },
    );
  }

  testWidgets('offline refresh shows the pill again after dismissal', (
    tester,
  ) async {
    NoteSyncService.refreshOperationOverride = () async {
      throw TimeoutException('offline');
    };
    LabelSyncService.refreshOperationOverride = () async {};
    await mountFeedback(tester);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final pill = find.byKey(const ValueKey('sync_progress'));
    expect(pill, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.drag(pill, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(pill, findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(pill, findsOneWidget);
    expect(find.text('No connection available.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('label-only activity is visible without old note counts', (
    tester,
  ) async {
    AuthService.cloudRecovery.start('synthetic-account');
    AuthService.cloudRecovery.state.value = CloudSessionState.ready;
    NoteSyncService().syncProgress.value = (4, 5);
    await mountFeedback(tester);
    LabelSyncService().isSyncing.value = true;
    await tester.pump();
    expect(find.text('Syncing...'), findsOneWidget);
    expect(find.text('4/5'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    LabelSyncService().isSyncing.value = false;
    LabelSyncService().syncStatus.value = const SyncProgress(
      SyncPhase.complete,
    );
    await tester.pump();
    expect(find.text('Sync complete'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    NoteSyncService().syncProgress.value = (0, 0);
  });

  testWidgets(
    'account switch starts a new request and suppresses old feedback',
    (tester) async {
      final old = Completer<void>();
      final next = Completer<void>();
      var calls = 0;
      var labelCalls = 0;
      NoteSyncService.refreshOperationOverride = () =>
          ++calls == 1 ? old.future : next.future;
      LabelSyncService.refreshOperationOverride = () async {
        labelCalls++;
      };
      await mountFeedback(tester);
      final context = tester.element(find.byType(SyncRefreshButton));
      final first = refreshSyncFromUser(context);
      expect(identical(first, refreshSyncFromUser(context)), isTrue);
      AuthService.cloudRecovery.stop();
      final second = refreshSyncFromUser(context);
      expect(identical(first, second), isFalse);
      old.complete();
      await tester.pump();
      expect(find.text('No connection available.'), findsNothing);
      expect(SyncPresentation.instance.value.isActive, isTrue);
      next.complete();
      await tester.pump();
      await Future.wait([first, second]);
      expect(labelCalls, 1);
      expect(find.text('Sync complete'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('disposed refresh host cannot publish a snackbar', (
    tester,
  ) async {
    final response = Completer<void>();
    NoteSyncService.refreshOperationOverride = () => response.future;
    LabelSyncService.refreshOperationOverride = () async {};
    await mountFeedback(tester);
    await tester.tap(find.byType(IconButton));
    await tester.pumpWidget(const SizedBox());
    response.completeError(TimeoutException('offline'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(SyncPresentation.instance.value.isActive, isFalse);
  });

  test('label failures reach the shared refresh result', () async {
    expect(
      await runManualSyncRefresh(
        notes: () async => SyncRefreshOutcome.deferred,
        labels: () async => SyncRefreshOutcome.failed,
      ),
      SyncRefreshOutcome.failed,
    );
    for (final result in [
      SyncRefreshOutcome.unavailable,
      SyncRefreshOutcome.failed,
    ]) {
      expect(
        await runManualSyncRefresh(
          notes: () async => SyncRefreshOutcome.complete,
          labels: () async => result,
        ),
        result,
      );
    }
    expect(
      await runManualSyncRefresh(
        notes: () async => SyncRefreshOutcome.failed,
        labels: () async => SyncRefreshOutcome.unavailable,
      ),
      SyncRefreshOutcome.failed,
    );
    for (final outcome in SyncRefreshOutcome.values) {
      expect(
        await runManualSyncRefresh(
          notes: () async => SyncRefreshOutcome.uploadRestricted,
          labels: () async => outcome,
        ),
        outcome == SyncRefreshOutcome.complete
            ? SyncRefreshOutcome.uploadRestricted
            : outcome,
      );
    }
  });

  testWidgets('overlapping refresh taps share work and show one snackbar', (
    tester,
  ) async {
    AppState.set('show_sync_progress', false);
    final response = Completer<void>();
    var calls = 0;
    NoteSyncService.refreshOperationOverride = () {
      calls++;
      return response.future;
    };
    LabelSyncService.refreshOperationOverride = () async {};
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => refreshSyncFromUser(context),
              child: const Text('Refresh'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Refresh'));
    await tester.tap(find.text('Refresh'));
    expect(calls, 1);
    response.completeError(TimeoutException('remote transport timeout'));
    await tester.pumpAndSettle();
    expect(find.text('No connection available.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('explicit unavailable refresh shows one localized snackbar', (
    tester,
  ) async {
    AppState.set('show_sync_progress', false);
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: AppState.scaffoldMessengerKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSyncRefreshFeedback(
                context,
                SyncRefreshOutcome.unavailable,
              ),
              child: const Text('Refresh'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('No connection available.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
