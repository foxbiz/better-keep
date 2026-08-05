import 'dart:async';

/// Runs a manual remote pull without allowing it to permanently stop the
/// real-time listener.
Future<T> runRemotePullWithListenerLifecycle<T>({
  required FutureOr<void> Function() stopListener,
  required FutureOr<void> Function() restoreListener,
  required bool Function() hasDurableCheckpoint,
  required FutureOr<void> Function() scheduleFullPull,
  required Future<T> Function() pull,
}) async {
  await stopListener();
  try {
    return await pull();
  } finally {
    await restoreListener();
    if (!hasDurableCheckpoint()) {
      await scheduleFullPull();
    }
  }
}
