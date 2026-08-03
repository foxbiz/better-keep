import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cached work does not resolve hydration before a server snapshot',
    () async {
      final gate = InitialHydrationGate();
      final generation = gate.startAttempt();
      var resolved = false;
      gate.ready.then((_) => resolved = true);

      gate.beginWork(generation, isFromCache: true);
      gate.endWork(generation);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);

      gate.beginWork(generation, isFromCache: false);
      gate.endWork(generation);
      await gate.ready;
      expect(resolved, isTrue);
    },
  );

  test('a later healthy generation recovers from a failed attempt', () async {
    final gate = InitialHydrationGate();
    final failedGeneration = gate.startAttempt();
    gate.beginWork(failedGeneration, isFromCache: false);
    expect(
      gate.endWork(failedGeneration, failed: true),
      HydrationWorkOutcome.retry,
    );

    final healthyGeneration = gate.startAttempt();
    gate.beginWork(healthyGeneration, isFromCache: false);
    expect(gate.endWork(healthyGeneration), HydrationWorkOutcome.ready);

    await gate.ready;
    expect(gate.isReady, isTrue);
  });

  test('a failed generation cannot be completed by a later snapshot', () async {
    final gate = InitialHydrationGate();
    final generation = gate.startAttempt();
    var resolved = false;
    gate.ready.then((_) => resolved = true);

    gate.beginWork(generation, isFromCache: false);
    expect(gate.endWork(generation, failed: true), HydrationWorkOutcome.retry);

    gate.beginWork(generation, isFromCache: false);
    expect(gate.endWork(generation), HydrationWorkOutcome.retry);
    await Future<void>.delayed(Duration.zero);

    expect(resolved, isFalse);
  });

  test('failed generation retries only after queued work drains', () {
    final gate = InitialHydrationGate();
    final generation = gate.startAttempt();
    gate.beginWork(generation, isFromCache: false);
    gate.beginWork(generation, isFromCache: false);

    expect(
      gate.endWork(generation, failed: true),
      HydrationWorkOutcome.pending,
    );
    expect(gate.isReady, isFalse);
    expect(gate.endWork(generation), HydrationWorkOutcome.retry);
    expect(gate.isReady, isFalse);
  });

  test('stale callbacks cannot complete a newer listener generation', () async {
    final gate = InitialHydrationGate();
    final staleGeneration = gate.startAttempt();
    gate.beginWork(staleGeneration, isFromCache: false);
    final currentGeneration = gate.startAttempt();
    var resolved = false;
    gate.ready.then((_) => resolved = true);

    expect(gate.endWork(staleGeneration), HydrationWorkOutcome.stale);
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);

    gate.beginWork(currentGeneration, isFromCache: false);
    gate.endWork(currentGeneration);
    await gate.ready;
    expect(resolved, isTrue);
  });

  test(
    'retry controller coalesces failures and resets after success',
    () async {
      final retry = HydrationRetryController(
        delayForAttempt: (_) => Duration.zero,
      );
      var attempts = 0;

      retry.schedule(() => attempts++);
      retry.schedule(() => attempts++);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);

      retry.succeeded();
      retry.schedule(() => attempts++);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 2);

      retry.cancel();
    },
  );
}
