import 'dart:async';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CloudSessionRecovery recovery;
  late SyncPresentation presentation;
  late Completer<CloudSessionState> verification;
  late Completer<void> initialization;
  late ValueNotifier<bool> notes, labels;
  late ValueNotifier<SyncProgress> noteStatus, labelStatus;
  late ValueNotifier<E2EEStatus> encryption;

  setUp(() {
    verification = Completer();
    initialization = Completer();
    recovery = CloudSessionRecovery(
      verify: (_) => verification.future,
      onReady: (_) => initialization.future,
      onFailure: (_, _) {},
    )..setForeground(false);
    notes = ValueNotifier(false);
    labels = ValueNotifier(false);
    noteStatus = ValueNotifier(SyncProgress.idle);
    labelStatus = ValueNotifier(SyncProgress.idle);
    encryption = ValueNotifier(E2EEStatus.ready);
    presentation = SyncPresentation(
      recovery: recovery,
      noteBusy: notes,
      labelBusy: labels,
      noteStatus: noteStatus,
      labelStatus: labelStatus,
      noteFailures: ValueNotifier({}),
      labelFailures: ValueNotifier({}),
      sessionInvalid: ValueNotifier(false),
      encryptionStatus: encryption,
    );
    recovery.start('account-a');
  });
  tearDown(() {
    recovery.stop();
    presentation.dispose();
  });

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
      expect(presentation.value.phase, SyncPhase.unavailable);
    },
  );

  test(
    'offline and approval backoff show a reason without a spinner',
    () async {
      final check = recovery.check();
      verification.complete(CloudSessionState.unavailable);
      await check;
      expect(recovery.activity.value, CloudRecoveryActivity.idle);
      expect(presentation.value.phase, SyncPhase.unavailable);
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
    expect(presentation.value.phase, SyncPhase.unavailable);
  });
}
