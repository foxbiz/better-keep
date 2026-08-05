import 'dart:async';

import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'deduplicates concurrent and later successful calls until reset',
    () async {
      final gate = AsyncInitializationGate();
      final release = Completer<void>();
      var runCount = 0;

      Future<void> initialize() async {
        runCount++;
        await release.future;
      }

      final first = gate.run(initialize);
      final concurrent = gate.run(initialize);

      expect(identical(first, concurrent), isTrue);
      expect(runCount, 1);

      release.complete();
      await Future.wait([first, concurrent]);

      final cached = gate.run(initialize);
      expect(identical(first, cached), isTrue);
      expect(runCount, 1);

      gate.reset();
      await gate.run(initialize);
      expect(runCount, 2);
    },
  );

  test('propagates failures to every caller and permits retry', () async {
    final gate = AsyncInitializationGate();
    final release = Completer<void>();
    final failure = StateError('initialization failed');
    late StackTrace originalStackTrace;
    var runCount = 0;

    Future<void> initialize() async {
      runCount++;
      if (runCount == 1) {
        await release.future;
        try {
          throw failure;
        } catch (error, stackTrace) {
          originalStackTrace = stackTrace;
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }

    final first = gate.run(initialize);
    final concurrent = gate.run(initialize);
    final firstFailure = _captureFailure(first);
    final concurrentFailure = _captureFailure(concurrent);

    release.complete();
    final failures = await Future.wait([firstFailure, concurrentFailure]);

    for (final captured in failures) {
      expect(identical(captured.$1, failure), isTrue);
      expect(captured.$2.toString(), originalStackTrace.toString());
    }

    await gate.run(initialize);
    expect(runCount, 2);
  });

  test('an older failure cannot clear a newer run after reset', () async {
    final gate = AsyncInitializationGate();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    var runCount = 0;

    Future<void> initialize() async {
      runCount++;
      if (runCount == 1) {
        await firstRelease.future;
        throw StateError('old run failed');
      }
      await secondRelease.future;
    }

    final first = gate.run(initialize);
    final firstExpectation = expectLater(first, throwsStateError);

    gate.reset();
    final second = gate.run(initialize);
    firstRelease.complete();
    await firstExpectation;

    final concurrentWithSecond = gate.run(initialize);
    expect(identical(second, concurrentWithSecond), isTrue);
    expect(runCount, 2);

    secondRelease.complete();
    await second;
  });
}

Future<(Object, StackTrace)> _captureFailure(Future<void> future) async {
  try {
    await future;
  } catch (error, stackTrace) {
    return (error, stackTrace);
  }
  throw StateError('Expected the Future to fail');
}
