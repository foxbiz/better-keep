import 'dart:async';

import 'package:better_keep/services/bounded_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('caps concurrency and completes each of 500 notes once', () async {
    var running = 0, peak = 0;
    final seen = <int>{};
    await forEachBounded(List.generate(500, (i) => i), (i) async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(Duration.zero);
      expect(seen.add(i), true);
      running--;
    });
    expect(peak, 4);
    expect(seen.length, 500);
    expect(running, 0);
  });
  test(
    'failure stops new work and drains in-flight tasks before throwing',
    () async {
      final release = Completer<void>();
      final started = <int>[];
      var finished = false;
      final run = forEachBounded(List.generate(20, (i) => i), (i) async {
        started.add(i);
        if (i == 0) throw StateError('session ended');
        await release.future;
      }, concurrency: 2);
      final check = expectLater(
        run.whenComplete(() => finished = true),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1]);
      expect(finished, false);
      release.complete();
      await check;
      expect(finished, true);
      expect(started, [0, 1]);
    },
  );
}
