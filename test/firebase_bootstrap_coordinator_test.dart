import 'package:better_keep/services/firebase_bootstrap_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

class _NonRetryableInitializationError
    implements Exception, NonRetryableFirebaseBootstrapError {}

void main() {
  test('routes Firebase before initializing dependent services', () async {
    final events = <String>[];
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async {
        events.add('services');
      },
    );

    await coordinator.start(
      configureBackend: () async {
        events.add('routing');
      },
    );

    expect(events, ['routing', 'services']);
  });

  test('does not initialize services when routing fails', () async {
    var initialized = false;
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async {
        initialized = true;
      },
    );

    await expectLater(
      coordinator.start(
        configureBackend: () async => throw StateError('unreachable'),
      ),
      throwsA(
        isA<FirebaseBootstrapException>().having(
          (error) => error.stage,
          'stage',
          FirebaseBootstrapStage.backendConfiguration,
        ),
      ),
    );

    expect(initialized, isFalse);
  });

  test('identifies service initialization failures separately', () async {
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async => throw StateError('auth failed'),
    );

    await expectLater(
      coordinator.start(),
      throwsA(
        isA<FirebaseBootstrapException>().having(
          (error) => error.stage,
          'stage',
          FirebaseBootstrapStage.serviceInitialization,
        ),
      ),
    );
  });

  test('service initialization can retry without repeating routing', () async {
    var routingCount = 0;
    var initializationCount = 0;
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async {
        initializationCount++;
        if (initializationCount == 1) {
          throw StateError('review token unavailable');
        }
      },
    );

    await expectLater(
      coordinator.start(
        configureBackend: () async {
          routingCount++;
        },
      ),
      throwsA(
        isA<FirebaseBootstrapException>().having(
          (error) => error.canRetryWithoutReconfiguringBackend,
          'canRetryWithoutReconfiguringBackend',
          isTrue,
        ),
      ),
    );

    await coordinator.start();

    expect(routingCount, 1);
    expect(initializationCount, 2);
  });

  test('backend routing failures are not retryable in-process', () {
    const error = FirebaseBootstrapException(
      stage: FirebaseBootstrapStage.backendConfiguration,
      cause: 'partial routing',
    );

    expect(error.canRetryWithoutReconfiguringBackend, isFalse);
  });

  test('configuration mismatches are not retryable after routing', () {
    final error = FirebaseBootstrapException(
      stage: FirebaseBootstrapStage.serviceInitialization,
      cause: _NonRetryableInitializationError(),
    );

    expect(error.canRetryWithoutReconfiguringBackend, isFalse);
  });

  test('another environment can be selected after routing fails', () async {
    final events = <String>[];
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async {
        events.add('services');
      },
    );

    await expectLater(
      coordinator.start(
        configureBackend: () async {
          events.add('emulator-failed');
          throw StateError('unreachable');
        },
      ),
      throwsA(isA<FirebaseBootstrapException>()),
    );

    await coordinator.start(
      configureBackend: () async {
        events.add('live-selected');
      },
    );

    expect(events, ['emulator-failed', 'live-selected', 'services']);
  });

  test('deduplicates concurrent initialization attempts', () async {
    var initializationCount = 0;
    final coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () async {
        initializationCount++;
      },
    );

    await Future.wait([coordinator.start(), coordinator.start()]);

    expect(initializationCount, 1);
  });
}
