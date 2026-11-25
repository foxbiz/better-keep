import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'dart:async';

import 'package:web/web.dart' as web;

import 'web_release.dart';

String _lockName(String scope) =>
    'better-keep.sign-out.$webStoragePrefix$scope';

/// Drop this tab's in-memory account state by starting it from the persisted
/// library. Even a delayed Retry can only observe the lock and reload.
Future<void> refreshAfterExternalSignOut(
  String scope, {
  web.Window? window,
}) async {
  final tab = window ?? web.window;
  final navigator = tab.navigator;
  if (navigator.getProperty<JSAny?>('locks'.toJS) != null) {
    // Use a non-queued probe. An unresponsive tab cannot accumulate waiters.
    if (!await _trySignOutLock(navigator, scope, () async {})) {
      throw TimeoutException('Another window is signing out');
    }
  }
  tab.location.reload();
  // Never return to an old session if navigation is deferred or prevented.
  await Future<void>.delayed(const Duration(seconds: 10));
  throw TimeoutException('Waiting for the browser to reload');
}

Future<bool> withSignOutLock(String scope, Future<void> Function() action) =>
    _trySignOutLock(web.window.navigator, scope, action);

Future<bool> _trySignOutLock(
  web.Navigator navigator,
  String scope,
  Future<void> Function() action,
) async {
  // Web Locks require a secure context. Preserve single-tab local development.
  if (navigator.getProperty<JSAny?>('locks'.toJS) == null) {
    await action();
    return true;
  }
  var acquired = false;
  Object? failure;
  StackTrace? trace;
  Future<void> run(web.Lock? lock) async {
    if (lock == null) return;
    acquired = true;
    try {
      await action();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
  }

  await navigator.locks
      .request(
        _lockName(scope),
        web.LockOptions(ifAvailable: true),
        ((web.Lock? lock) => run(lock).toJS).toJS,
      )
      .toDart;
  // Keep Dart error types (including timeouts) across the JS callback.
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return acquired;
}
