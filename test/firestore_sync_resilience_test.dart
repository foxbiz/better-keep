import 'dart:async';

import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:better_keep/services/remote_pull_lifecycle.dart';
import 'package:better_keep/services/retry_controller.dart';
import 'package:better_keep/services/staged_checkpoint.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

FirebaseException firestoreFailure(String code) {
  return FirebaseException(plugin: 'cloud_firestore', code: code);
}

void main() {
  group('Firestore transient retry', () {
    test(
      'recovers from transient failures using the specified delays',
      () async {
        var attempts = 0;
        final delays = <Duration>[];

        final result = await retryTransientFirestoreOperation(() async {
          attempts++;
          if (attempts < 4) throw firestoreFailure('unavailable');
          return 'downloaded';
        }, delay: (duration) async => delays.add(duration));

        expect(result, 'downloaded');
        expect(attempts, 4);
        expect(delays, firestoreRetryDelays);
      },
    );

    test('does not retry permanent failures', () async {
      var attempts = 0;

      await expectLater(
        retryTransientFirestoreOperation(() async {
          attempts++;
          throw firestoreFailure('permission-denied');
        }, delay: (_) async => fail('permanent failure must not delay')),
        throwsA(
          isA<FirebaseException>().having(
            (error) => error.code,
            'code',
            'permission-denied',
          ),
        ),
      );

      expect(attempts, 1);
    });
  });

  test('concurrent full-pull retries coalesce', () async {
    final controller = ExponentialBackoffRetryController(
      delayForAttempt: (_) => Duration.zero,
    );
    var attempts = 0;

    controller.schedule(() => attempts++);
    controller.schedule(() => attempts++);
    controller.schedule(() => attempts++);
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 1);
    controller.cancel();
  });

  test('a failed page cannot advance a staged durable checkpoint', () async {
    var durableCheckpoint = 'before';
    final checkpoint = StagedCheckpoint<String>(
      commit: (value) => durableCheckpoint = value,
    );

    checkpoint.stage('after-page-one');
    try {
      throw firestoreFailure('unavailable');
    } on FirebaseException {
      // A pull commits only after every page and local application succeeds.
    }

    expect(durableCheckpoint, 'before');
  });

  test('a failed manual pull always restores its listener', () async {
    var listenerRunning = true;
    var fullPullScheduled = false;

    await expectLater(
      runRemotePullWithListenerLifecycle<void>(
        stopListener: () => listenerRunning = false,
        restoreListener: () => listenerRunning = true,
        recoveryDisposition: () => RemotePullRecoveryDisposition.none,
        scheduleCachedResume: () {},
        scheduleFullPull: () => fullPullScheduled = true,
        pull: () async => throw firestoreFailure('unavailable'),
      ),
      throwsA(isA<FirebaseException>()),
    );

    expect(listenerRunning, isTrue);
    expect(fullPullScheduled, isFalse);
  });

  test(
    'failed bootstrap restores listener and schedules one full pull',
    () async {
      var restoreCalls = 0;
      var scheduleCalls = 0;

      await expectLater(
        runRemotePullWithListenerLifecycle<void>(
          stopListener: () {},
          restoreListener: () => restoreCalls++,
          recoveryDisposition: () => RemotePullRecoveryDisposition.restartFull,
          scheduleCachedResume: () {},
          scheduleFullPull: () => scheduleCalls++,
          pull: () async => throw firestoreFailure('deadline-exceeded'),
        ),
        throwsA(isA<FirebaseException>()),
      );

      expect(restoreCalls, 1);
      expect(scheduleCalls, 1);
    },
  );

  test('completed pagination retries only remaining cached entries', () async {
    var cachedResumeCalls = 0;
    var fullPullCalls = 0;

    await expectLater(
      runRemotePullWithListenerLifecycle<void>(
        stopListener: () {},
        restoreListener: () {},
        recoveryDisposition: () => RemotePullRecoveryDisposition.resumeCached,
        scheduleCachedResume: () => cachedResumeCalls++,
        scheduleFullPull: () => fullPullCalls++,
        pull: () async => throw firestoreFailure('unavailable'),
      ),
      throwsA(isA<FirebaseException>()),
    );

    expect(cachedResumeCalls, 1);
    expect(fullPullCalls, 0);
  });

  test('overlapping listener batches preserve update/delete order', () async {
    final serializer = AsyncKeyedSerializer<String>();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];
    var checkpoint = 'before';

    final update = serializer.run('notes', () async {
      events.add('update-start');
      firstStarted.complete();
      await releaseFirst.future;
      checkpoint = 'update';
      events.add('update-end');
    });
    await firstStarted.future;
    final deletion = serializer.run('notes', () async {
      events.add('delete');
      checkpoint = 'delete';
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['update-start']);
    expect(checkpoint, 'before');

    releaseFirst.complete();
    await Future.wait([update, deletion]);
    await serializer.waitForIdle('notes');

    expect(events, ['update-start', 'update-end', 'delete']);
    expect(checkpoint, 'delete');
  });

  test(
    'failed listener generation recovers once after its queue drains',
    () async {
      final serializer = AsyncKeyedSerializer<String>();
      final gate = InitialHydrationGate();
      final generation = gate.startAttempt();
      final outcomes = <HydrationWorkOutcome>[];
      var recoveryRequests = 0;
      var appliedBatches = 0;

      gate.beginWork(generation, isFromCache: false);
      final failedBatch = serializer.run('notes', () async {
        appliedBatches++;
        outcomes.add(gate.endWork(generation, failed: true));
      });
      gate.beginWork(generation, isFromCache: false);
      final queuedBatch = serializer.run('notes', () async {
        if (!gate.isFailed(generation)) appliedBatches++;
        final outcome = gate.endWork(generation);
        outcomes.add(outcome);
        if (outcome == HydrationWorkOutcome.retry) recoveryRequests++;
      });

      await Future.wait([failedBatch, queuedBatch]);
      await serializer.waitForIdle('notes');

      expect(appliedBatches, 1);
      expect(outcomes, [
        HydrationWorkOutcome.pending,
        HydrationWorkOutcome.retry,
      ]);
      expect(recoveryRequests, 1);
    },
  );

  test('manual pull waits for listener cancellation and queued work', () async {
    final serializer = AsyncKeyedSerializer<String>();
    final listenerWorkStarted = Completer<void>();
    final releaseListenerWork = Completer<void>();
    var subscriptionCancelled = false;
    var pullStarted = false;
    var listenerRestored = false;

    unawaited(
      serializer.run('notes', () async {
        listenerWorkStarted.complete();
        await releaseListenerWork.future;
      }),
    );
    await listenerWorkStarted.future;

    final pull = runRemotePullWithListenerLifecycle<String>(
      stopListener: () async {
        subscriptionCancelled = true;
        await serializer.waitForIdle('notes');
      },
      restoreListener: () => listenerRestored = true,
      recoveryDisposition: () => RemotePullRecoveryDisposition.none,
      scheduleCachedResume: () {},
      scheduleFullPull: () {},
      pull: () async {
        pullStarted = true;
        return 'done';
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(subscriptionCancelled, isTrue);
    expect(pullStarted, isFalse);

    releaseListenerWork.complete();
    expect(await pull, 'done');
    expect(pullStarted, isTrue);
    expect(listenerRestored, isTrue);
  });
}
