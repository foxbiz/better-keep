import 'dart:async';
import 'dart:math';

/// Coalesces retry requests and applies capped exponential backoff with jitter.
class ExponentialBackoffRetryController {
  ExponentialBackoffRetryController({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterRatio = 0.2,
    Random? random,
    Duration Function(int attempt)? delayForAttempt,
  }) : assert(!initialDelay.isNegative),
       assert(maxDelay >= initialDelay),
       assert(jitterRatio >= 0),
       _random = random ?? Random(),
       _delayOverride = delayForAttempt;

  final Duration initialDelay;
  final Duration maxDelay;
  final double jitterRatio;
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
    var milliseconds = initialDelay.inMilliseconds;
    for (var index = 0; index < attempt; index++) {
      if (milliseconds >= maxDelay.inMilliseconds) break;
      milliseconds = min(maxDelay.inMilliseconds, milliseconds * 2);
    }
    final jitter = (_random.nextDouble() * milliseconds * jitterRatio).round();
    return Duration(
      milliseconds: min(maxDelay.inMilliseconds, milliseconds + jitter),
    );
  }
}
