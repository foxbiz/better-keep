class AsyncOperationCoalescer<K, V> {
  final Map<K, Future<V>> _inFlight = {};

  int get inFlightCount => _inFlight.length;

  Future<V> run(K key, Future<V> Function() operation) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<V> future;
    future = operation().whenComplete(() {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = future;
    return future;
  }

  Future<void> waitForIdle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait<void>(
        _inFlight.values.map((future) => future.then<void>((_) {})),
      );
    }
  }

  void clear() => _inFlight.clear();
}
