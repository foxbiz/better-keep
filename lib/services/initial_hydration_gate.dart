import 'dart:async';

import 'package:better_keep/services/retry_controller.dart';

typedef HydrationRetryController = ExponentialBackoffRetryController;

/// Resolves once one listener generation has fully processed a server-backed
/// snapshot without a retryable failure.
class InitialHydrationGate {
  Completer<void> _completer = Completer<void>();
  int _generation = 0;
  int _activeWork = 0;
  bool _serverObserved = false;
  bool _failed = false;

  Future<void> get ready => _completer.future;
  bool get isReady => _completer.isCompleted;
  int get currentGeneration => _generation;

  int startAttempt() {
    _generation++;
    _activeWork = 0;
    _serverObserved = false;
    _failed = false;
    return _generation;
  }

  bool isCurrent(int generation) => generation == _generation;

  void beginWork(int generation, {required bool isFromCache}) {
    if (!isCurrent(generation)) return;
    _activeWork++;
    if (!isFromCache) _serverObserved = true;
  }

  void endWork(int generation, {bool failed = false}) {
    if (!isCurrent(generation)) return;
    if (failed) _failed = true;
    if (_activeWork > 0) _activeWork--;
    _tryComplete();
  }

  void failAttempt(int generation) {
    if (!isCurrent(generation)) return;
    _failed = true;
  }

  void invalidateAttempt() {
    _generation++;
    _activeWork = 0;
    _serverObserved = false;
    _failed = false;
  }

  void reset() {
    invalidateAttempt();
    _completer = Completer<void>();
  }

  void _tryComplete() {
    if (_activeWork == 0 &&
        _serverObserved &&
        !_failed &&
        !_completer.isCompleted) {
      _completer.complete();
    }
  }
}
