import 'dart:async';

/// Serializes asynchronous work sharing the same key while allowing unrelated
/// keys to continue independently.
///
/// Failed operations are deliberately converted to successful queue tails so
/// they cannot poison later work for the same key.
class AsyncKeyedSerializer<K> {
  final Map<K, Future<void>> _tails = <K, Future<void>>{};

  Future<T> run<T>(K key, Future<T> Function() action) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return result;
  }

  bool contains(K key) => _tails.containsKey(key);

  /// Waits until all work currently queued for [key] has completed.
  ///
  /// The loop is intentional: another operation may append itself while the
  /// previously observed tail is still running.
  Future<void> waitForIdle(K key) async {
    while (true) {
      final tail = _tails[key];
      if (tail == null) return;
      await tail;
      if (identical(_tails[key], tail)) {
        _tails.remove(key);
        return;
      }
    }
  }

  Future<void> waitForAll() async {
    while (_tails.isNotEmpty) {
      await Future.wait<void>(_tails.values.toList(growable: false));
    }
  }
}
