import 'dart:js_interop';

import 'package:firebase_core/firebase_core.dart';

import 'firebase_emulator_host.dart';

@JS('betterKeepConfigureEmulatorProxy')
external void _configure(JSString host, JSString origin);

void configureFirebaseEmulatorWebProxy(FirebaseEmulatorEndpoints endpoints) {
  if (endpoints.webProxyOrigin case final origin?) {
    _configure(endpoints.host.toJS, origin.toJS);
  }
}

@JS('betterKeepPrepareAuthEmulator')
external void _prepareAuth(
  JSString appName,
  JSAny options,
  JSString host,
  JSNumber port,
);

/// Configure the JavaScript Auth instance before FlutterFire can restore a
/// persisted session. Also validates real routing when reusing a hot-restart app.
void prepareFirebaseAuthEmulator(
  String appName,
  FirebaseOptions options,
  FirebaseEmulatorEndpoints endpoints,
) {
  _prepareAuth(
    appName.toJS,
    // Match FlutterFire's web options exactly. Native-only fields from asMap()
    // would make its subsequent initializeApp call reject the existing app.
    {
      'apiKey': options.apiKey,
      'authDomain': options.authDomain,
      'databaseURL': options.databaseURL,
      'projectId': options.projectId,
      'storageBucket': options.storageBucket,
      'messagingSenderId': options.messagingSenderId,
      'measurementId': options.measurementId,
      'appId': options.appId,
    }.jsify()!,
    endpoints.host.toJS,
    FirebaseEmulatorEndpoints.authPort.toJS,
  );
}
