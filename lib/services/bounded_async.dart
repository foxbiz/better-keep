import 'dart:async';

/// Stops taking new work after failure, and drains in-flight operations before
/// throwing so callers can safely tear down their session/database.
Future<void> forEachBounded<T>(
  Iterable<T> items,
  Future<void> Function(T) action, {
  int concurrency = 4,
}) async {
  if (concurrency < 1) throw ArgumentError.value(concurrency);
  final iterator = items.iterator;
  Object? failure;
  StackTrace? failureStack;
  Future<void> worker() async {
    while (failure == null && iterator.moveNext()) {
      final item = iterator.current;
      try {
        await action(item);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}
