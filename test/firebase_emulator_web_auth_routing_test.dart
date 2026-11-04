@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:better_keep/services/firebase_emulator_web_proxy.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web passes the selected named app and routing to synchronous preparation',
    () {
      final calls = <List<Object?>>[];
      globalContext.setProperty(
        'betterKeepPrepareAuthEmulator'.toJS,
        ((JSString name, JSAny options, JSString host, JSNumber port) {
          calls.add([
            name.toDart,
            options.dartify(),
            host.toDart,
            port.toDartInt,
          ]);
        }).toJS,
      );
      addTearDown(
        () => globalContext.delete('betterKeepPrepareAuthEmulator'.toJS),
      );
      const options = FirebaseOptions(
        apiKey: 'qa-key',
        appId: 'qa-app',
        messagingSenderId: 'qa-sender',
        projectId: 'demo-routing',
        iosClientId: 'native-only-client',
        iosBundleId: 'native-only-bundle',
      );
      prepareFirebaseAuthEmulator(
        'better-keep-emulator-qa',
        options,
        const FirebaseEmulatorEndpoints('127.0.0.1'),
      );
      expect(calls.single[0], 'better-keep-emulator-qa');
      expect(calls.single[1], {
        'apiKey': 'qa-key',
        'authDomain': null,
        'databaseURL': null,
        'projectId': 'demo-routing',
        'storageBucket': null,
        'messagingSenderId': 'qa-sender',
        'measurementId': null,
        'appId': 'qa-app',
      });
      expect(calls.single.sublist(2), ['127.0.0.1', 9099]);
    },
  );
}
