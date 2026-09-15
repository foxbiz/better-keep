import 'dart:async';

import 'package:better_keep/services/cloud_session_recovery.dart';

final _sessionKey = Object();

/// Registers callbacks in their owner's session, rather than inheriting the
/// shorter operation (such as device verification) that created the listener.
T runCloudCallback<T>(bool Function() isCurrent, T Function() callback) =>
    runZoned(() {
      requireCurrentSession(isCurrent);
      return callback();
    }, zoneValues: {_sessionKey: isCurrent});

/// Keeps nested sync work bound to the account that scheduled it. A zone avoids
/// storing an operation's guard on a singleton shared by concurrent listeners.
Future<T> runCloudOperation<T>(
  bool Function() isCurrent,
  Future<T> Function() operation,
) => runZoned(() async {
  requireCurrentSession(isCurrent);
  return operation();
}, zoneValues: {_sessionKey: isCurrent});

bool Function() captureCloudOperation() =>
    Zone.current[_sessionKey] as bool Function()? ?? () => true;

bool cloudOperationIsCurrent() => captureCloudOperation()();

void requireCloudOperation() => requireCurrentSession(cloudOperationIsCurrent);

/// Captures ownership when background work is scheduled, including timers.
/// Cancellation is expected; current-session failures still reach the owner.
Future<void> Function() bindBackgroundCloudOperation(
  bool Function() isCurrent,
  Future<void> Function() operation, {
  required void Function(Object, StackTrace) onError,
}) => () async {
  try {
    await runCloudOperation(isCurrent, operation);
  } catch (error, stack) {
    if (!isCurrent() || error is CloudOperationCancelled) return;
    onError(error, stack);
  }
};
