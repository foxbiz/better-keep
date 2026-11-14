import 'dart:async';

import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CloudSessionRecovery recovery;
  late SyncPresentation presentation;
  late Completer<CloudSessionState> verification;
  late Completer<void> initialization;
  late ValueNotifier<bool> notes, labels, firebaseEnabled;
  late ValueNotifier<SyncProgress> external;
  late ValueNotifier<SyncProgress> noteStatus, labelStatus, orderStatus;
  late ValueNotifier<E2EEStatus> encryption;
  late ValueNotifier<PostSignInState> postSignIn;

  setUp(() {
    verification = Completer();
    initialization = Completer();
    recovery = CloudSessionRecovery(
      verify: (_) => verification.future,
      onReady: (_) => initialization.future,
      onFailure: (_, _) {},
    )..setForeground(false);
    firebaseEnabled = ValueNotifier(true);
    external = ValueNotifier(SyncProgress.idle);
    notes = ValueNotifier(false);
    labels = ValueNotifier(false);
    noteStatus = ValueNotifier(SyncProgress.idle);
    orderStatus = ValueNotifier(SyncProgress.idle);
    labelStatus = ValueNotifier(SyncProgress.idle);
    encryption = ValueNotifier(E2EEStatus.ready);
    postSignIn = ValueNotifier(PostSignInState.idle);
    presentation = SyncPresentation(
      recovery: recovery,
      externalChanges: external,
      externalProgress: () => external.value,
      firebaseChanges: firebaseEnabled,
      firebaseSelected: () => firebaseEnabled.value,
      noteBusy: notes,
      labelBusy: labels,
      noteStatus: noteStatus,
      orderStatus: orderStatus,
      labelStatus: labelStatus,
      noteFailures: ValueNotifier({}),
      labelFailures: ValueNotifier({}),
      sessionInvalid: ValueNotifier(false),
      encryptionStatus: encryption,
      postSignInState: postSignIn,
    );
    recovery.start('account-a');
  });
  tearDown(() {
    recovery.stop();
    presentation.dispose();
  });

  testWidgets('initial restore honors the sync progress display preference', (
    tester,
  ) async {
    final reduceMotion = ValueNotifier(false);
    addTearDown(reduceMotion.dispose);
    final previous = AppState.showSyncProgress;
    final session = NoteSyncBatch();
    final done = Completer<void>();
    final work = session.run(
      24,
      (_) => done.future,
      isEmptyLibrary: () async => true,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: reduceMotion,
            builder: (context, reduce, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: child!,
            ),
          ),
          home: const Scaffold(body: BulkSyncProgress()),
        ),
      );
      for (final show in [true, false]) {
        AppState.set('show_sync_progress', show);
        await tester.pump();
        expect(find.text('24 notes'), show ? findsOneWidget : findsNothing);
        if (!show) {
          expect(find.bySemanticsLabel('Downloading Notes'), findsOneWidget);
        }
        final download = find.byKey(const ValueKey('download_activity'));
        expect(download, findsOneWidget);
        expect(find.text('0%'), show ? findsOneWidget : findsNothing);
        expect(
          find.byType(LinearProgressIndicator),
          show ? findsOneWidget : findsNothing,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        double shaftLength() {
          final canvas = TestRecordingCanvas();
          tester
              .widget<CustomPaint>(download)
              .painter!
              .paint(canvas, tester.getSize(download));
          final shaft = canvas.invocations
              .map((call) => call.invocation)
              .singleWhere((call) => call.memberName == #drawLine)
              .positionalArguments;
          return ((shaft[1] as Offset) - (shaft[0] as Offset)).distance;
        }

        final center = tester.getCenter(download);
        final before = shaftLength();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.getCenter(download), center);
        expect(shaftLength(), isNot(closeTo(before, 1)));
        reduceMotion.value = true;
        await tester.pump();
        final still = shaftLength();
        expect(still, greaterThan(0));
        await tester.pump(const Duration(milliseconds: 700));
        expect(shaftLength(), still);
        reduceMotion.value = false;
        await tester.pump();
      }
    } finally {
      done.complete();
      await work;
      AppState.set('show_sync_progress', previous);
    }
  });

  test(
    'checking publishes the first result and flushes the full count once',
    () {
      var elapsed = Duration.zero;
      final samples = <NoteTransfer>[];
      final meter = NoteTransferMeter(
        NoteTransferStage.checking,
        null,
        samples.add,
        elapsed: () => elapsed,
      );
      for (var batch = 0; batch < 80; batch++) {
        meter.advance(10);
      }
      elapsed = const Duration(milliseconds: 500);
      meter.advance(20);
      meter.advance(3);
      meter.flush();
      meter.flush();
      expect(samples.map((p) => p.done), [0, 10, 823]);
      expect(
        samples.every((p) => p.total == null && p.minutesLeft == null),
        isTrue,
      );
    },
  );

  test('estimate uses completed work and resets at a phase boundary', () {
    final samples = <NoteTransfer>[];
    var elapsed = Duration.zero;
    final meter = NoteTransferMeter(
      NoteTransferStage.downloading,
      60,
      samples.add,
      elapsed: () => elapsed,
    );
    expect(samples.single.minutesLeft, isNull);
    meter.advance();
    meter.advance();
    expect(samples.length, 1);
    elapsed = const Duration(seconds: 6);
    meter.advance();
    expect(samples.last.done, 3);
    expect(samples.last.minutesLeft, 2);
    for (var i = 3; i < 60; i++) {
      meter.advance();
    }
    expect(samples.last.fraction, 1);
    expect(samples.last.minutesLeft, isNull);
    NoteTransferMeter(NoteTransferStage.uploading, 3, samples.add);
    expect(samples.last.done, 0);
    expect(samples.last.minutesLeft, isNull);
  });

  test('download progress keeps its total when a revision is skipped', () {
    final samples = <NoteTransfer>[];
    final meter = NoteTransferMeter(
      NoteTransferStage.downloading,
      3,
      samples.add,
    );
    meter.advance();
    meter.exclude();
    meter.flush();
    expect(samples.last.total, 3);
    expect(samples.last.done, 2);
    meter.advance();
    expect(samples.last.fraction, 1);
  });

  test(
    'deferred notes shrink the expected transfer without counting as writes',
    () {
      final samples = <NoteTransfer>[];
      final meter = NoteTransferMeter(
        NoteTransferStage.uploading,
        5,
        samples.add,
        elapsed: () => Duration.zero,
      );
      meter.advance();
      meter.exclude(2);
      meter.flush();
      expect(samples.last.done, 1);
      expect(samples.last.total, 3);
      expect(samples.last.minutesLeft, isNull);
      meter.advance();
      meter.advance();
      expect(samples.last.fraction, 1);
    },
  );

  test('paused uploads still show incoming activity and failure', () async {
    final preference = FirebaseSyncPreference(
      currentUid: () => 'account-a',
      watch: (_) =>
          Stream.value(const FirebaseSyncSelection(false, confirmed: true)),
      write: (_, _) async => throw StateError('No writes expected'),
    )..bind('account-a');
    addTearDown(preference.dispose);
    await pumpEventQueue();
    firebaseEnabled.value = preference.allowsDownload('account-a');
    expect(preference.allowsSync('account-a'), false);
    const update = (
      stage: NoteTransferStage.downloading,
      done: 9,
      total: 20,
      minutesLeft: 1,
    );
    noteStatus.value = const SyncProgress(SyncPhase.syncing, notes: update);
    recovery.state.value = CloudSessionState.ready;
    notes.value = true;
    expect(presentation.value.phase, SyncPhase.syncing);
    external.value = const SyncProgress(SyncPhase.syncing);
    expect(presentation.value.notes, update);
    external.value = SyncProgress.idle;
    notes.value = false;
    noteStatus.value = const SyncProgress(SyncPhase.failed, failedCount: 1);
    expect(presentation.value.phase, SyncPhase.failed);
    noteStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
    expect(presentation.value.phase, SyncPhase.uploadRestricted);
  });

  test(
    'external transfers remain visible while Firebase is unavailable or paused',
    () {
      recovery.connectionLost();
      external.value = const SyncProgress(SyncPhase.syncing);
      expect(presentation.value.phase, SyncPhase.syncing);
      external.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.phase, SyncPhase.idle);
      firebaseEnabled.value = false;
      expect(presentation.value.phase, SyncPhase.complete);
      noteStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
      expect(presentation.value.phase, SyncPhase.complete);
    },
  );

  test('external failure or pending work prevents a global success', () {
    recovery.state.value = CloudSessionState.ready;
    noteStatus.value = const SyncProgress(SyncPhase.complete);
    external.value = const SyncProgress(SyncPhase.failed, failedCount: 2);
    expect(presentation.value.phase, SyncPhase.failed);
    expect(presentation.value.failedCount, 2);
    external.value = const SyncProgress(SyncPhase.storageFull);
    expect(presentation.value.phase, SyncPhase.storageFull);
    expect(presentation.value.isFailure, true);
    external.value = const SyncProgress(SyncPhase.deferred);
    expect(presentation.value.phase, SyncPhase.deferred);
    external.value = const SyncProgress(SyncPhase.providerSetupRequired);
    expect(presentation.value.phase, SyncPhase.providerSetupRequired);
    expect(presentation.value.isFailure, false);
    external.value = const SyncProgress(SyncPhase.syncing);
    expect(presentation.value.phase, SyncPhase.syncing);
    external.value = const SyncProgress(SyncPhase.complete);
    expect(presentation.value.phase, SyncPhase.complete);
  });

  test(
    'order-only work and failures contribute to combined Firebase progress',
    () {
      recovery.state.value = CloudSessionState.ready;
      noteStatus.value = const SyncProgress(SyncPhase.complete);
      orderStatus.value = const SyncProgress(SyncPhase.syncing);
      expect(presentation.value.phase, SyncPhase.syncing);
      orderStatus.value = const SyncProgress(SyncPhase.failed);
      expect(presentation.value.phase, SyncPhase.failed);
      orderStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
      expect(presentation.value.phase, SyncPhase.uploadRestricted);
      orderStatus.value = SyncProgress.idle;
      labelStatus.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.phase, SyncPhase.uploadRestricted);
      orderStatus.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.phase, SyncPhase.complete);
    },
  );

  test(
    'empty restored library acknowledges startup verification until offline',
    () async {
      postSignIn.value = PostSignInState.ready;
      final check = recovery.check();
      expect(presentation.value.phase, SyncPhase.idle);
      expect(presentation.emptyLibraryProgress.phase, SyncPhase.preparing);
      verification.complete(CloudSessionState.unavailable);
      await check;
      expect(presentation.emptyLibraryProgress.phase, SyncPhase.idle);
    },
  );

  test('empty library does not add a restore placeholder when encryption blocks access', () async {
    postSignIn.value = PostSignInState.ready;
    final check = recovery.check();
    for (final status in [
      E2EEStatus.pendingApproval,
      E2EEStatus.needsRecovery,
      E2EEStatus.revoked,
    ]) {
      encryption.value = status;
      expect(
        presentation.emptyLibraryProgress.phase,
        SyncPhase.checkingConnection,
      );
    }
    verification.complete(CloudSessionState.unavailable);
    await check;
  });

  test('new session immediately prepares before any verification event', () {
    expect(recovery.state.value, CloudSessionState.pending);
    expect(recovery.activity.value, CloudRecoveryActivity.idle);
    expect(presentation.value.phase, SyncPhase.preparing);
    recovery.stop();
    expect(presentation.value.phase, SyncPhase.idle);
    recovery.start('account-b');
    expect(presentation.value.phase, SyncPhase.preparing);
  });

  test('post-login stages stay visible with encryption ready', () async {
    final phases = <SyncPhase>[];
    presentation.addListener(() => phases.add(presentation.value.phase));
    for (final stage in [
      PostSignInStage.identityValidation,
      PostSignInStage.accountInitialization,
      PostSignInStage.encryptionInitialization,
      PostSignInStage.auxiliaryServices,
    ]) {
      postSignIn.value = PostSignInState.running(stage);
      expect(presentation.value.phase, SyncPhase.preparing);
    }
    final check = recovery.check();
    verification.complete(CloudSessionState.ready);
    await check;
    initialization.complete();
    await pumpEventQueue();
    noteStatus.value = const SyncProgress(SyncPhase.complete);
    final request = presentation.beginManual(() => true);
    presentation.finishManual(request, SyncRefreshOutcome.complete);
    expect(presentation.value.phase, SyncPhase.preparing);
    notes.value = true;
    expect(presentation.value.phase, SyncPhase.syncing);
    postSignIn.value = PostSignInState.ready;
    notes.value = false;
    expect(presentation.value.phase, SyncPhase.complete);
    expect(phases, isNot(contains(SyncPhase.idle)));
  });

  test('initialization failure ends preparation and retry restores it', () {
    postSignIn.value = PostSignInState.recoverableFailure(
      PostSignInStage.accountInitialization,
      operation: 'initialize-account',
    );
    expect(presentation.value.phase, SyncPhase.deferred);
    expect(presentation.value.isActive, isFalse);
    postSignIn.value = PostSignInState.running(
      PostSignInStage.accountInitialization,
    );
    expect(presentation.value.phase, SyncPhase.preparing);
    recovery.connectionLost();
    expect(presentation.value.phase, SyncPhase.idle);
    expect(presentation.value.isActive, isFalse);
  });

  test('approval and encryption failures stop the preparation indicator', () {
    postSignIn.value = PostSignInState.running(
      PostSignInStage.encryptionInitialization,
    );
    for (final state in [
      E2EEStatus.pendingApproval,
      E2EEStatus.revoked,
      E2EEStatus.needsRecovery,
      E2EEStatus.error,
    ]) {
      encryption.value = state;
      expect(presentation.value.isActive, isFalse);
      expect(
        presentation.value.phase,
        state == E2EEStatus.pendingApproval
            ? SyncPhase.waitingForApproval
            : SyncPhase.deferred,
      );
    }
  });

  test(
    'unfinished device initialization shows preparing rather than offline',
    () async {
      encryption.value = E2EEStatus.notInitialized;
      final check = recovery.check();
      verification.complete(CloudSessionState.pending);
      await check;
      expect(presentation.value.phase, SyncPhase.preparing);
      expect(presentation.value.isActive, isTrue);
      encryption.value = E2EEStatus.pendingApproval;
      expect(presentation.value.phase, SyncPhase.waitingForApproval);
    },
  );

  test(
    'startup shows verification, initialization, and label-only activity',
    () async {
      final check = recovery.check();
      expect(presentation.value.phase, SyncPhase.checkingConnection);
      verification.complete(CloudSessionState.ready);
      await check;
      expect(presentation.value.phase, SyncPhase.preparing);
      labels.value = true;
      expect(presentation.value.phase, SyncPhase.syncing);
      initialization.complete();
      await pumpEventQueue();
      expect(presentation.value.isActive, isTrue);
      labels.value = false;
      labelStatus.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.isSuccess, isTrue);
    },
  );

  test(
    'refresh during startup keeps preparing until note checking starts',
    () async {
      final request = presentation.beginManual(() => true);
      final check = recovery.check();
      verification.complete(CloudSessionState.ready);
      await check;
      presentation.finishManual(request, SyncRefreshOutcome.deferred);
      expect(presentation.value.phase, SyncPhase.preparing);
      notes.value = true;
      noteStatus.value = const SyncProgress(SyncPhase.fetchingUpdates);
      expect(presentation.value.phase, SyncPhase.fetchingUpdates);
      initialization.complete();
      await pumpEventQueue();
    },
  );

  test(
    'manual activity lasts through notes and labels and preserves restrictions',
    () async {
      final request = presentation.beginManual(() => true);
      expect(presentation.value.phase, SyncPhase.checkingConnection);
      final check = recovery.check();
      verification.complete(CloudSessionState.ready);
      initialization.complete();
      await check;
      await pumpEventQueue();
      expect(presentation.value.phase, SyncPhase.preparing);
      notes.value = true;
      notes.value = false;
      noteStatus.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.isSuccess, isFalse);
      labels.value = true;
      expect(presentation.value.isActive, isTrue);
      labelStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
      labels.value = false;
      presentation.finishManual(request, SyncRefreshOutcome.uploadRestricted);
      expect(presentation.value.phase, SyncPhase.uploadRestricted);
      noteStatus.value = SyncProgress.idle;
      expect(presentation.value.phase, SyncPhase.uploadRestricted);
      expect(presentation.value.isActive, isFalse);
      recovery.connectionLost();
      expect(presentation.value.phase, SyncPhase.idle);
    },
  );

  test(
    'offline retries stay silent while an approval request remains visible',
    () async {
      final check = recovery.check();
      verification.complete(CloudSessionState.unavailable);
      await check;
      expect(recovery.activity.value, CloudRecoveryActivity.idle);
      expect(presentation.value.phase, SyncPhase.idle);
      expect(presentation.value.isActive, isFalse);
      encryption.value = E2EEStatus.pendingApproval;
      recovery.state.value = CloudSessionState.pending;
      expect(presentation.value.phase, SyncPhase.waitingForApproval);
      expect(presentation.value.isActive, isFalse);
    },
  );

  test(
    'label completion cannot clear an outstanding note upload restriction',
    () {
      recovery.state.value = CloudSessionState.ready;
      noteStatus.value = const SyncProgress(SyncPhase.uploadRestricted);
      noteStatus.value = SyncProgress.idle;
      labels.value = true;
      labels.value = false;
      labelStatus.value = const SyncProgress(SyncPhase.complete);
      expect(presentation.value.phase, SyncPhase.uploadRestricted);
      notes.value = true;
      noteStatus.value = const SyncProgress(SyncPhase.complete);
      notes.value = false;
      expect(presentation.value.phase, SyncPhase.complete);
    },
  );

  test(
    'account switch rejects late verification and manual completion',
    () async {
      final old = presentation.beginManual(() => true);
      final check = recovery.check();
      recovery.start('account-b');
      final current = presentation.beginManual(() => true);
      verification.complete(CloudSessionState.ready);
      await check;
      presentation.finishManual(old, SyncRefreshOutcome.complete);
      expect(presentation.value.isSuccess, isFalse);
      presentation.finishManual(current, SyncRefreshOutcome.failed);
      expect(presentation.value.isFailure, isTrue);
      expect(recovery.activity.value, CloudRecoveryActivity.idle);
    },
  );

  testWidgets('verification timeout stops activity before the next retry', (
    tester,
  ) async {
    final check = recovery.check();
    await tester.pump(const Duration(seconds: 10));
    expect(await check, CloudSessionState.unavailable);
    expect(presentation.value.isActive, isFalse);
    expect(recovery.activity.value, CloudRecoveryActivity.idle);
    verification.complete(CloudSessionState.ready);
    await tester.pump();
    expect(presentation.value.phase, SyncPhase.idle);
  });
}
