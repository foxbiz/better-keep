@TestOn('browser')
library;

import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/web_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'compiled channel retains stable names and separates beta namespaces',
    () {
      const beta = bool.fromEnvironment('WEB_BETA');
      expect(isBetaWebBuild, beta);
      expect(webFirebaseAppName, beta ? 'better-keep-beta' : '[DEFAULT]');
      expect(
        FirebaseLocalDataScope.live.databaseName,
        beta ? 'beta_better_keep.db' : 'better_keep.db',
      );
      expect(
        FirebaseLocalDataScope.emulator.databaseName,
        beta ? 'beta_better_keep_emulator.db' : 'better_keep_emulator.db',
      );
      expect(
        FirebaseLocalDataScope.live.secureStorageKey('key'),
        beta ? 'beta_key' : 'key',
      );
      expect(
        FirebaseLocalDataScope.emulator.secureStorageKey('key'),
        beta ? 'beta_firebase_emulator.key' : 'firebase_emulator.key',
      );
      expect(betaWorkerBase, '/app/beta-runtime/v1/');
    },
  );
}
