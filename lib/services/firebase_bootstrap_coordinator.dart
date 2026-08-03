enum FirebaseBootstrapStage { backendConfiguration, serviceInitialization }

abstract interface class NonRetryableFirebaseBootstrapError {}

class FirebaseBootstrapException implements Exception {
  const FirebaseBootstrapException({required this.stage, required this.cause});

  final FirebaseBootstrapStage stage;
  final Object cause;

  /// Service initialization can be retried without changing Firebase routing.
  bool get canRetryWithoutReconfiguringBackend =>
      stage == FirebaseBootstrapStage.serviceInitialization &&
      cause is! NonRetryableFirebaseBootstrapError;

  @override
  String toString() => cause.toString();
}

/// Enforces Firebase backend routing before dependent services initialize.
class FirebaseBootstrapCoordinator {
  FirebaseBootstrapCoordinator({required this.initializeServices});

  final Future<void> Function() initializeServices;

  Future<void>? _running;
  bool _initialized = false;

  Future<void> start({Future<void> Function()? configureBackend}) {
    if (_initialized) return Future.value();
    final running = _running;
    if (running != null) return running;

    final future = _start(configureBackend);
    _running = future;
    return future;
  }

  Future<void> _start(Future<void> Function()? configureBackend) async {
    try {
      if (configureBackend != null) {
        try {
          await configureBackend();
        } catch (error) {
          throw FirebaseBootstrapException(
            stage: FirebaseBootstrapStage.backendConfiguration,
            cause: error,
          );
        }
      }
      try {
        await initializeServices();
      } catch (error) {
        throw FirebaseBootstrapException(
          stage: FirebaseBootstrapStage.serviceInitialization,
          cause: error,
        );
      }
      _initialized = true;
    } finally {
      if (!_initialized) _running = null;
    }
  }
}
