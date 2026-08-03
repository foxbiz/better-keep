/// Runs an asynchronous initializer once until it is reset.
///
/// Concurrent callers receive the same [Future]. Successful completion is
/// cached, while failures clear the gate so a later call can retry.
class AsyncInitializationGate {
  Future<void>? _running;

  Future<void> run(Future<void> Function() initializer) {
    final running = _running;
    if (running != null) return running;

    late final Future<void> candidate;
    candidate = Future<void>.sync(initializer).onError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (identical(_running, candidate)) {
        _running = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    _running = candidate;
    return candidate;
  }

  void reset() {
    _running = null;
  }
}
