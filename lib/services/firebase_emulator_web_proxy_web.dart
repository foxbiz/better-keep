import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'firebase_emulator_host.dart';

@JS('betterKeepConfigureEmulatorProxy')
external void _configure(JSString host, JSString origin);

void configureFirebaseEmulatorWebProxy(FirebaseEmulatorEndpoints endpoints) {
  if (endpoints.webProxyOrigin case final origin?) {
    _configure(endpoints.host.toJS, origin.toJS);
  }
}

/// FlutterFire restores this hint only on localhost, but skips explicit setup
/// whenever it matches. Clear it before creating a fresh emulator app so HTTPS
/// debug sessions cannot accidentally use production Auth after a reload.
void prepareFirebaseAuthEmulator(String appName) {
  web.window.sessionStorage.removeItem('$appName-firebaseEmulatorOrigin');
}
