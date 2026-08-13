import 'dart:async';

enum RemotePullRecoveryDisposition { none, resumeCached, restartFull }

/// Runs a manual remote pull without allowing it to permanently stop the
/// real-time listener.
Future<T> runRemotePullWithListenerLifecycle<T>({
  required FutureOr<void> Function() stopListener,
  required FutureOr<void> Function() restoreListener,
  required RemotePullRecoveryDisposition Function() recoveryDisposition,
  required FutureOr<void> Function() scheduleCachedResume,
  required FutureOr<void> Function() scheduleFullPull,
  required Future<T> Function() pull,
}) async {
  await stopListener();
  try {
    return await pull();
  } finally {
    await restoreListener();
    switch (recoveryDisposition()) {
      case RemotePullRecoveryDisposition.none:
        break;
      case RemotePullRecoveryDisposition.resumeCached:
        await scheduleCachedResume();
        break;
      case RemotePullRecoveryDisposition.restartFull:
        await scheduleFullPull();
        break;
    }
  }
}
