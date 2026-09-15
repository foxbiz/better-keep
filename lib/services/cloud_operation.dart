import 'dart:async';

import 'package:better_keep/services/cloud_session_recovery.dart';

final _sessionKey = Object();

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
