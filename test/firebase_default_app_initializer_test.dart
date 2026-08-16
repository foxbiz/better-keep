import 'dart:async';

import 'package:better_keep/services/firebase_default_app_initializer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SingleFlightDefaultAppInitializer', () {
    test(
      'returns an existing default app without creating another one',
      () async {
        final initializer = SingleFlightDefaultAppInitializer<String>();
        var createCalls = 0;

        final app = await initializer.initialize(
          currentApps: () => const ['secondary', 'default'],
          isDefaultApp: (value) => value == 'default',
          createApp: () async {
            createCalls++;
            return 'created';
          },
          isDuplicateAppError: (_) => false,
          currentDefaultApp: () => 'default',
        );

        expect(app, 'default');
        expect(createCalls, 0);
      },
    );

    test('coalesces concurrent initialization calls', () async {
      final initializer = SingleFlightDefaultAppInitializer<String>();
      final completer = Completer<String>();
      var createCalls = 0;

      Future<String> initialize() => initializer.initialize(
        currentApps: () => const [],
        isDefaultApp: (_) => false,
        createApp: () {
          createCalls++;
          return completer.future;
        },
        isDuplicateAppError: (_) => false,
        currentDefaultApp: () => 'default',
      );

      final first = initialize();
      final second = initialize();
      expect(createCalls, 1);

      completer.complete('created');
      expect(await first, 'created');
      expect(await second, 'created');
    });

    test('recovers only the duplicate-app failure', () async {
      final initializer = SingleFlightDefaultAppInitializer<String>();
      final duplicate = StateError('duplicate');

      final app = await initializer.initialize(
        currentApps: () => const [],
        isDefaultApp: (_) => false,
        createApp: () async => throw duplicate,
        isDuplicateAppError: (error) => identical(error, duplicate),
        currentDefaultApp: () => 'default',
      );

      expect(app, 'default');
    });

    test('propagates unrelated failures and permits a retry', () async {
      final initializer = SingleFlightDefaultAppInitializer<String>();
      var createCalls = 0;

      Future<String> initialize() => initializer.initialize(
        currentApps: () => const [],
        isDefaultApp: (_) => false,
        createApp: () async {
          createCalls++;
          if (createCalls == 1) throw StateError('network');
          return 'created';
        },
        isDuplicateAppError: (_) => false,
        currentDefaultApp: () => 'default',
      );

      await expectLater(initialize(), throwsStateError);
      expect(await initialize(), 'created');
      expect(createCalls, 2);
    });
  });
}
