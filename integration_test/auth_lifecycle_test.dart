// Run in order with AUTH_LIFECYCLE_PHASE=setup,offline-restart,signed-out-restart
// with --no-uninstall on a fresh disposable iOS simulator,
// against demo-bkn-auth-lifecycle only.
// Uses real Firebase SDKs, SQLite and Keychain. No production credentials.
import 'dart:io';

import 'package:better_keep/app.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/home.dart';
import 'package:better_keep/pages/login_page.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/sync_logout_check.dart';
import 'package:better_keep/state.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _project = 'demo-bkn-auth-lifecycle';
const _phase = String.fromEnvironment('AUTH_LIFECYCLE_PHASE');
const _title = 'QA lifecycle local note';
const _phrase = 'Disposable local emulator recovery only';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: label);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real account lifecycle: $_phase', (tester) async {
    expect([
      'setup',
      'offline-restart',
      'signed-out-restart',
    ], contains(_phase));
    await FirebaseEmulatorConfig.initDeviceInfo();
    expect(FirebaseEmulatorConfig.isPhysicalDevice, false);
    expect(Platform.isIOS, true);
    final app = await Firebase.initializeApp(
      name: _project,
      options: const FirebaseOptions(
        apiKey: 'Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        appId: '1:1234567890:ios:0123456789abcdef01234567',
        messagingSenderId: '1234567890',
        projectId: _project,
        storageBucket: 'demo-bkn-auth-lifecycle.appspot.com',
      ),
    );
    final auth = FirebaseAuth.instanceFor(app: app);
    await auth.useAuthEmulator('127.0.0.1', 9099);
    final firestore = FirebaseFirestore.instanceFor(app: app);
    firestore.useFirestoreEmulator('127.0.0.1', 8080);
    final storage = FirebaseStorage.instanceFor(app: app);
    await storage.useStorageEmulator('127.0.0.1', 9199);
    final functions = FirebaseFunctions.instanceFor(app: app);
    functions.useFunctionsEmulator('127.0.0.1', 5001);
    FirebaseBackend.configureForTesting(
      FirebaseBackendConfiguration(
        environment: FirebaseEnvironment.emulator,
        app: app,
        auth: auth,
        firestore: firestore,
        functions: functions,
        storage: storage,
        databaseId: '(default)',
        localDataScope: FirebaseLocalDataScope.emulator,
        googleAuthMode: GoogleEmulatorAuthMode.mock,
        endpoints: const FirebaseEmulatorEndpoints('127.0.0.1'),
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await AppState.init(prefs: prefs);
    await AppState.initializeFirebaseScope(preferences: prefs);
    if (_phase == 'setup') {
      expect(
        auth.currentUser,
        isNull,
        reason: 'Use a fresh disposable simulator',
      );
      expect(await E2EESecureStorage.instance.hasDeviceKeys(), false);
      expect(await File(await activeDatabasePath()).exists(), false);
    }
    if (_phase == 'offline-restart') await firestore.disableNetwork();
    await AuthService.init(prefs: prefs, deferLocalRestore: true);
    await AuthService.openDatabaseForStartup();
    LocalDataEncryption.setDatabaseGetter(() => AppState.db);
    await NoteSortService().init();
    // Isolate persistence/navigation from scheduled background sync. This fixture
    // does not claim coverage of foreground automatic cloud recovery.
    AuthService.setAppForeground(false);
    await tester.pumpWidget(const App());
    final e2ee = E2EEService.instance;
    if (_phase == 'setup') {
      await _until(
        tester,
        () => find.byType(LoginPage).evaluate().isNotEmpty,
        'initial sign-in page',
      );
      final login = AuthService.signInWithGoogle();
      // Observe errors immediately, even if the readiness assertion fails first.
      // Await the original future below to retain its failure and stack trace.
      login.ignore();
      await _until(
        tester,
        () => e2ee.isCryptoReady,
        'fresh sign-in must finish encryption setup',
      );
      await login;
      expect(find.byType(Home), findsOneWidget);
      await e2ee.recoveryKeyService.createRecoveryKey(_phrase);
      await Note(
        title: _title,
        content: '[{"insert":"Saved locally\\n"}]',
      ).save(false);
      expect(await currentSyncLogoutState(), isNot(SyncLogoutState.complete));
      debugPrint('AUTH QA PASS: fresh sign-in and local encrypted note');
    } else if (_phase == 'offline-restart') {
      expect(
        auth.currentUser,
        isNotNull,
        reason: 'Firebase identity persists across process restart',
      );
      await AuthService.initializeCurrentUserServices();
      await _until(
        tester,
        () => find.byType(Home).evaluate().isNotEmpty,
        'approved offline restart opens Home',
      );
      expect(
        (await Note.get(NoteType.all)).any((n) => n.title == _title),
        true,
      );
      expect(find.text('Something went wrong'), findsNothing);
      expect(find.text('Connection needed'), findsNothing);
      debugPrint(
        'AUTH QA PASS: offline process restart preserves identity, keys and note',
      );
      await firestore.enableNetwork();
      await AuthService.signOut();
      await _until(
        tester,
        () => find.byType(LoginPage).evaluate().isNotEmpty,
        'sign-out returns to sign-in',
      );
      expect(auth.currentUser, isNull);
      final login = AuthService.signInWithGoogle();
      // Observe errors immediately, even if the readiness assertion fails first.
      // Await the original future below to retain its failure and stack trace.
      login.ignore();
      await _until(
        tester,
        () => e2ee.status.value == E2EEStatus.needsRecovery,
        're-login offers recovery instead of generic error',
      );
      await login;
      expect(
        await e2ee.recoveryKeyService.recoverWithPassphrase(_phrase),
        true,
      );
      await _until(
        tester,
        () => e2ee.isCryptoReady,
        'recover the same synthetic account',
      );
      debugPrint('AUTH QA PASS: sign-out, re-login and passphrase recovery');
      await AuthService.signOut();
      expect(auth.currentUser, isNull);
    } else {
      expect(
        auth.currentUser,
        isNull,
        reason: 'Signed-out restart must not restore the prior login',
      );
      await AuthService.initializeCurrentUserServices();
      await _until(
        tester,
        () => find.byType(LoginPage).evaluate().isNotEmpty,
        'signed-out restart stays at sign-in',
      );
      await tester.pump(const Duration(seconds: 12));
      expect(auth.currentUser, isNull);
      expect(find.byType(LoginPage), findsOneWidget);
      debugPrint('AUTH QA PASS: signed-out process restart stays signed out');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    AuthService.cloudRecovery.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
