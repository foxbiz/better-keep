@TestOn('browser')
library;

import 'package:better_keep/services/firebase_emulator_web_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('fresh emulator setup discards only its stale Auth routing hint', () {
    const appName = 'qa-emulator-routing';
    const hintKey = '$appName-firebaseEmulatorOrigin';
    const unrelatedKey = 'qa-other-session-value';
    final storage = web.window.sessionStorage;
    addTearDown(() {
      storage.removeItem(hintKey);
      storage.removeItem(unrelatedKey);
    });
    storage.setItem(hintKey, 'http://127.0.0.1:9099');
    storage.setItem(unrelatedKey, 'preserve');

    prepareFirebaseAuthEmulator(appName);

    expect(storage.getItem(hintKey), isNull);
    expect(storage.getItem(unrelatedKey), 'preserve');
    // First use, with no remembered hint, is safe too.
    prepareFirebaseAuthEmulator(appName);
    expect(storage.getItem(unrelatedKey), 'preserve');
  });
}
