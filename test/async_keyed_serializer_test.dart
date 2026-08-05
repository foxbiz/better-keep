import 'dart:async';

import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'same-key operations are ordered and failures do not poison queue',
    () async {
      final serializer = AsyncKeyedSerializer<int>();
      final release = Completer<void>();
      final events = <String>[];

      final first = serializer.run<void>(1, () async {
        events.add('first-start');
        await release.future;
        events.add('first-end');
        throw StateError('expected');
      });
      final second = serializer.run<void>(1, () async {
        events.add('second');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);
      release.complete();
      await expectLater(first, throwsStateError);
      await second;
      expect(events, ['first-start', 'first-end', 'second']);
      expect(serializer.contains(1), false);
    },
  );

  test('different keys can progress independently', () async {
    final serializer = AsyncKeyedSerializer<int>();
    final blocked = Completer<void>();
    var otherFinished = false;

    final first = serializer.run<void>(1, () => blocked.future);
    await serializer.run<void>(2, () async {
      otherFinished = true;
    });

    expect(otherFinished, true);
    blocked.complete();
    await first;
  });

  test('waitForIdle includes work appended behind the observed tail', () async {
    final serializer = AsyncKeyedSerializer<String>();
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    final events = <String>[];

    serializer.run<void>('listener', () async {
      events.add('first');
      await releaseFirst.future;
    });
    final idle = serializer.waitForIdle('listener');
    serializer.run<void>('listener', () async {
      events.add('second');
      await releaseSecond.future;
    });

    releaseFirst.complete();
    await Future<void>.delayed(Duration.zero);
    expect(events, ['first', 'second']);
    var idleCompleted = false;
    idle.then((_) => idleCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(idleCompleted, isFalse);

    releaseSecond.complete();
    await idle;
    expect(serializer.contains('listener'), isFalse);
  });
}
