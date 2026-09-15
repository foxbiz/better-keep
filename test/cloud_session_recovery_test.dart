import 'dart:async';

import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
