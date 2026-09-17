import 'dart:async';

import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session start notifies after the new session is installed', () {
    final recovery = CloudSessionRecovery(
      verify: (_) async => CloudSessionState.ready,
      onReady: (_) async {},
      onFailure: (_, _) {},
    );
    final sessions = <bool>[];
    recovery.sessionRevision.addListener(
      () => sessions.add(recovery.hasSession),
    );
    recovery.start('account-a');
    expect(sessions.last, isTrue);
    final count = sessions.length;
    recovery.start('account-a');
    expect(sessions.length, count);
    final current = recovery.captureSession();
    recovery.start('account-b');
    expect(current(), isFalse);
    expect(sessions.last, isTrue);
    recovery.stop();
    expect(sessions.last, isFalse);
  });

  test(
    'initialization queues one fresh check after an unfinished check',
    () async {
      final first = Completer<CloudSessionState>();
      var checks = 0;
      var resumes = 0;
      final recovery = CloudSessionRecovery(
        verify: (_) async =>
            ++checks == 1 ? await first.future : CloudSessionState.ready,
        onReady: (_) async {
          resumes++;
        },
        onFailure: (_, _) => fail('Initialization is not a connection failure'),
      )..setForeground(false);
      addTearDown(recovery.stop);
      recovery.start('account-a');
      final checking = recovery.check();
      final queued = recovery.recheckAfterInitialization();
      expect(identical(queued, recovery.recheckAfterInitialization()), isTrue);
      first.complete(CloudSessionState.pending);
      expect(await checking, CloudSessionState.pending);
      expect(await queued, CloudSessionState.ready);
      await pumpEventQueue();
      expect(checks, 2);
      expect(resumes, 1);
    },
  );

  test(
    'queued initialization check cannot verify a different account',
    () async {
      final first = Completer<CloudSessionState>();
      var checks = 0;
      final recovery = CloudSessionRecovery(
        verify: (_) {
          checks++;
          return first.future;
        },
        onReady: (_) async {},
        onFailure: (_, _) {},
      )..setForeground(false);
      addTearDown(recovery.stop);
      recovery.start('account-a');
      final checking = recovery.check();
      final queued = recovery.recheckAfterInitialization();
      recovery.start('account-b');
      first.complete(CloudSessionState.pending);
      await checking;
      expect(await queued, CloudSessionState.pending);
      expect(checks, 1);
    },
  );

  testWidgets('cancelled partial startup retries in the current account', (
    tester,
  ) async {
    final release = Completer<void>();
    var starts = 0;
    final recovery = CloudSessionRecovery(
      verify: (_) async => CloudSessionState.ready,
      onReady: (_) async {
        starts++;
        if (starts == 1) {
          await release.future;
          throw const CloudOperationCancelled();
        }
      },
      onFailure: (_, _) => fail('Cancellation is not a verification failure'),
    );
    recovery.start('account-a');
    await recovery.check();
    await recovery.check();
    expect(starts, 1);
    release.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(starts, 2);
    await recovery.check();
    expect(starts, 2);
    expect(recovery.state.value, CloudSessionState.ready);
    recovery.stop();
  });

  test(
    'manual checks retry cancellation, but ignore old-account completion',
    () async {
      final old = Completer<void>();
      var starts = 0;
      final recovery = CloudSessionRecovery(
        verify: (_) async => CloudSessionState.ready,
        onReady: (_) async {
          starts++;
          if (starts == 1) throw const CloudOperationCancelled();
          if (starts == 2) await old.future;
        },
        onFailure: (_, _) => fail('Cancellation must be handled'),
      )..setForeground(false);
      recovery.start('account-a');
      await recovery.check();
      await pumpEventQueue();
      await recovery.check();
      expect(starts, 2);
      recovery.start('account-b');
      await recovery.check();
      await pumpEventQueue();
      old.completeError(const CloudOperationCancelled());
      await pumpEventQueue();
      await recovery.check();
      expect(starts, 3);
      expect(recovery.state.value, CloudSessionState.ready);
      recovery.stop();
    },
  );

  testWidgets('partial service startup retries without overlapping restarts', (
    tester,
  ) async {
    final release = Completer<void>();
    var starts = 0;
    final recovery = CloudSessionRecovery(
      verify: (_) async => CloudSessionState.ready,
      onReady: (_) async {
        starts++;
        if (starts == 1) {
          await release.future;
          throw StateError('local service initialization failed');
        }
      },
      onFailure: (_, _) {},
    );
    recovery.start('account-a');
    await recovery.check();
    await recovery.check();
    expect(starts, 1);
    release.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(starts, 2);
    expect(recovery.state.value, CloudSessionState.ready);
    recovery.stop();
  });

  testWidgets('pending authorization is retried until approval', (
    tester,
  ) async {
    var approved = false;
    var starts = 0;
    final recovery = CloudSessionRecovery(
      verify: (_) async =>
          approved ? CloudSessionState.ready : CloudSessionState.pending,
      onReady: (_) async {
        starts++;
      },
      onFailure: (_, _) {},
    );
    recovery.start('account-a');
    await recovery.check();
    expect(starts, 0);
    approved = true;
    await tester.pump(const Duration(seconds: 5));
    expect(starts, 1);
    recovery.stop();
  });

  testWidgets(
    'offline retries back off, then resume once without changing local state',
    (tester) async {
      var online = false;
      var attempts = 0;
      var resumes = 0;
      final recovery = CloudSessionRecovery(
        verify: (_) async {
          attempts++;
          if (!online) {
            throw FirebaseException(
              plugin: 'auth',
              code: 'network-request-failed',
            );
          }
          return CloudSessionState.ready;
        },
        onReady: (_) async {
          resumes++;
        },
        onFailure: (_, _) {},
      );
      recovery.start('account-a');
      await recovery.check();
      expect(recovery.state.value, CloudSessionState.unavailable);
      expect(attempts, 1);
      for (final delay in [5, 15, 30]) {
        await tester.pump(Duration(seconds: delay - 1));
        final before = attempts;
        await tester.pump(const Duration(seconds: 1));
        expect(attempts, before + 1);
        expect(resumes, 0);
      }
      online = true;
      await tester.pump(const Duration(seconds: 60));
      expect(recovery.state.value, CloudSessionState.ready);
      expect(resumes, 1);
      await recovery.check();
      expect(resumes, 1);
      recovery.stop();
    },
  );

  testWidgets('ten-second timeout discards late success and coalesces checks', (
    tester,
  ) async {
    final response = Completer<CloudSessionState>();
    late bool Function() attemptCurrent;
    var resumes = 0;
    final recovery = CloudSessionRecovery(
      verify: (isCurrent) {
        attemptCurrent = isCurrent;
        return response.future;
      },
      onReady: (_) async {
        resumes++;
      },
      onFailure: (_, _) {},
    );
    recovery.start('account-a');
    final first = recovery.check();
    expect(identical(first, recovery.check()), isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(await first, CloudSessionState.unavailable);
    expect(attemptCurrent(), isFalse);
    response.complete(CloudSessionState.ready);
    await tester.pump();
    expect(resumes, 0);
    expect(recovery.state.value, CloudSessionState.unavailable);
    recovery.stop();
  });

  testWidgets('background stops retry timer; resume checks immediately', (
    tester,
  ) async {
    var attempts = 0;
    final recovery = CloudSessionRecovery(
      verify: (_) async {
        attempts++;
        return CloudSessionState.unavailable;
      },
      onReady: (_) async {},
      onFailure: (_, _) {},
    );
    recovery.start('account-a');
    await recovery.check();
    recovery.setForeground(false);
    await tester.pump(const Duration(minutes: 3));
    expect(attempts, 1);
    recovery.setForeground(true);
    await tester.pump();
    expect(attempts, 2);
    recovery.stop();
  });

  testWidgets('old-account failures and callbacks cannot affect new session', (
    tester,
  ) async {
    final response = Completer<CloudSessionState>();
    var calls = 0;
    var resumes = 0;
    final recovery = CloudSessionRecovery(
      verify: (_) => calls++ == 0
          ? response.future
          : Future.value(CloudSessionState.ready),
      onReady: (_) async {
        resumes++;
      },
      onFailure: (_, _) {},
    );
    recovery.start('account-a');
    final old = recovery.check();
    recovery.start('account-b');
    await recovery.check();
    response.completeError(
      FirebaseException(plugin: 'auth', code: 'user-disabled'),
    );
    await old;
    expect(recovery.state.value, CloudSessionState.ready);
    expect(resumes, 1);
    recovery.stop();
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 2);
  });

  test('only transport failures are classified as unavailable', () {
    for (final code in [
      'permission-denied',
      'user-disabled',
      'data-loss',
      'internal',
    ]) {
      expect(
        isCloudConnectionFailure(FirebaseException(plugin: 'auth', code: code)),
        isFalse,
      );
    }
    expect(
      isCloudConnectionFailure(
        FirestoreDocumentFetchException(
          resource: 'notes',
          operation: 'fetch',
          cause: TimeoutException('offline'),
        ),
      ),
      isTrue,
    );
  });
}
