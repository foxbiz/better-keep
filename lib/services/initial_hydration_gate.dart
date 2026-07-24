import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

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

class HydrationRetryController {
  HydrationRetryController({
    Random? random,
    @visibleForTesting Duration Function(int attempt)? delayForAttempt,
  }) : _random = random ?? Random(),
       _delayOverride = delayForAttempt;

  final Random _random;
  final Duration Function(int attempt)? _delayOverride;
  Timer? _timer;
  int _failures = 0;

  bool get isScheduled => _timer?.isActive ?? false;

  void schedule(FutureOr<void> Function() retry) {
    if (isScheduled) return;
    final delay = _delayOverride?.call(_failures) ?? _backoff(_failures);
    _failures++;
    _timer = Timer(delay, () {
      _timer = null;
      retry();
    });
  }

  void succeeded() {
    _failures = 0;
    _timer?.cancel();
    _timer = null;
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _failures = 0;
  }

  Duration _backoff(int attempt) {
    final exponent = min(attempt, 5);
    final baseMilliseconds = min(30000, 1000 * (1 << exponent));
    final jitter = (_random.nextDouble() * baseMilliseconds * 0.2).round();
    return Duration(milliseconds: baseMilliseconds + jitter);
  }
}
