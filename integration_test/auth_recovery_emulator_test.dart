import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'dart:convert';

import 'package:better_keep/app.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/account_recovery_page.dart';
import 'package:better_keep/pages/email_login_page.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/state.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> until(
  WidgetTester tester,
  bool Function() condition,
  String stage,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: stage);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await FirebaseEmulatorConfig.initDeviceInfo();
    expect(
      FirebaseEmulatorConfig.isPhysicalDevice,
      isFalse,
      reason: 'Use a disposable emulator or simulator.',
    );
    final host = defaultTargetPlatform == TargetPlatform.android
        ? androidEmulatorHost
        : firebaseEmulatorLoopbackHost;
    await FirebaseBackend.configureEmulator(
      endpoints: FirebaseEmulatorEndpoints(host),
      googleAuthMode: GoogleEmulatorAuthMode.mock,
    );
    expect(FirebaseBackend.active.usesEmulators, isTrue);
    const freshDevice =
        'Use a fresh QA simulator or emulator with no existing Better Keep data.';
    expect(FirebaseBackend.auth.currentUser, isNull, reason: freshDevice);
    expect(
      (await SharedPreferences.getInstance()).getString(
        FirebaseScopedPreferences.key('user_uid'),
      ),
      isNull,
      reason: freshDevice,
    );
    expect(
      await E2EESecureStorage.instance.hasDeviceKeys(),
      isFalse,
      reason: freshDevice,
    );
    expect(
      await File(await activeDatabasePath()).exists(),
      isFalse,
      reason: freshDevice,
    );
  });

  testWidgets(
    'signup, duplicate signup, login and recovery after a failed lookup',
    (tester) async {
      final email =
          'qa+${defaultTargetPlatform.name.toLowerCase()}.${DateTime.now().microsecondsSinceEpoch}@example.technology';
      const password = 'TemporaryEmulatorOnly-845!';
      final auth = FirebaseBackend.auth;
      final firestore = FirebaseBackend.firestore;
      await auth.signOut();
      Future<void> page(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            scaffoldMessengerKey: AppState.scaffoldMessengerKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: child,
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
      }

      Future<void> tapText(String text) async {
        final target = find.text(text).last;
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
      }

      await page(const EmailLoginPage());
      await tapText('Sign Up');
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), ' $email ');
      await tester.enterText(fields.at(1), password);
      await tester.enterText(fields.at(2), password);
      await tapText('Create Account');
      await until(
        tester,
        () => auth.currentUser?.email == email && fields.evaluate().isNotEmpty,
        'Signup did not finish',
      );
      final uid = auth.currentUser!.uid;
      expect(auth.currentUser!.emailVerified, isFalse);
      await auth.signOut();

      await tapText('Create Account');
      final l10n = lookupAppLocalizations(const Locale('en'));
      await until(
        tester,
        () => find.text(l10n.signInToExistingAccount).evaluate().isNotEmpty,
        'Duplicate signup message was not shown',
      );
      expect(auth.currentUser, isNull);
      await tapText('Sign In');
      await tapText('Sign In');
      await until(
        tester,
        () => auth.currentUser?.uid == uid && fields.evaluate().isNotEmpty,
        'Sign-in did not restore the original account',
      );

      await firestore.disableNetwork();
      try {
        await page(const AccountRecoveryPage());
        await until(
          tester,
          () => find.text(l10n.recoveryCheckUnavailable).evaluate().isNotEmpty,
          'Recovery did not offer Retry after a failed read',
        );
        expect(find.text(l10n.startFresh), findsNothing);
        expect(find.text(l10n.startFreshInstead), findsNothing);
        expect(find.text(l10n.noActiveDevicesNoRecoveryKey), findsNothing);
      } finally {
        await firestore.enableNetwork();
      }
      await firestore
          .doc('users/$uid')
          .snapshots(includeMetadataChanges: true)
          .firstWhere((snapshot) => !snapshot.metadata.isFromCache)
          .timeout(const Duration(seconds: 15));
      await tapText(l10n.retry);
      await until(
        tester,
        () =>
            find.text(l10n.noActiveDevicesNoRecoveryKey).evaluate().isNotEmpty,
        'Retry did not load the account recovery options',
      );
      expect(find.text(l10n.recoveryCheckUnavailable), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.signOut();
    },
  );

  testWidgets(
    'switch accounts without losing a local note, then recover its original encryption key',
    (tester) async {
      final auth = FirebaseBackend.auth;
      final firestore = FirebaseBackend.firestore;
      final e2ee = E2EEService.instance;
      final run = DateTime.now().microsecondsSinceEpoch;
      OAuthCredential identity(String name) => GoogleAuthProvider.credential(
        idToken: jsonEncode({
          'sub': 'qa-$name-$run',
          'email': '$name+$run@example.test',
          'email_verified': true,
        }),
      );
      final ownerIdentity = identity('owner');
      final owner = (await auth.signInWithCredential(ownerIdentity)).user!;
      final prefs = await SharedPreferences.getInstance();
      final ownerKey = FirebaseScopedPreferences.key('user_uid');
      await prefs.setString(ownerKey, owner.uid);
      await AppState.init(prefs: prefs);
      await AppState.initializeFirebaseScope(preferences: prefs);
      final db = await initDatabase();
      addTearDown(() async {
        await db.close();
        await deleteDatabase(db.path);
        if (prefs.getString(ownerKey) == owner.uid) {
          await prefs.remove(ownerKey);
        }
      });
      await AuthService.init(prefs: prefs, deferLocalRestore: true);
      AuthService.setAppForeground(false);
      expect(await e2ee.setupE2EE(), isTrue);
      const phrase = 'Temporary emulator recovery phrase';
      await e2ee.recoveryKeyService.createRecoveryKey(phrase);
      final storage = E2EESecureStorage.instance;
      final deviceId = (await storage.getDeviceId())!;
      addTearDown(() async {
        if (await storage.getDeviceId() == deviceId) await storage.clearAll();
      });
      tester.platformDispatcher.localeTestValue = const Locale('en');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final title = 'Local-only recovery QA $run';
      final note = Note(
        title: title,
        content: '[{"insert":"Offline note\\n"}]',
        plainText: 'Offline note',
      );
      expect(await note.save(false), greaterThan(0));
      final encrypted = (await e2ee.noteEncryption.encryptNote(title: title))!;
      final l10n = lookupAppLocalizations(const Locale('en'));
      await auth.signInWithCredential(identity('other'));
      await tester.pumpWidget(const App());
      await until(
        tester,
        () => find.text(l10n.localAccountMismatch).evaluate().isNotEmpty,
        'Wrong account must be blocked',
      );
      expect(find.text(title), findsNothing);
      expect((await AuthService.cloudRecovery.check()).name, 'blocked');
      await tester.tap(find.text(l10n.useDifferentAccount));
      await until(
        tester,
        () => auth.currentUser == null,
        'Switch must return to sign-in',
      );
      expect(prefs.getString(ownerKey), owner.uid);
      expect((await Note.findById(note.id!))?.title, title);
      expect(await storage.getDeviceId(), deviceId);

      await auth.signInWithCredential(ownerIdentity);
      await until(
        tester,
        () =>
            auth.currentUser?.uid == owner.uid &&
            !AuthService.hasDifferentLocalAccount,
        'Owner did not sign back in',
      );
      // Reproduce an approved QA device that cannot unwrap or restore its master key.
      await firestore.doc('users/${owner.uid}/devices/$deviceId').update({
        'wrapped_umk': FieldValue.delete(),
        'wrapped_umk_nonce': FieldValue.delete(),
      });
      await e2ee.deviceManager.clearUMK();
      await expectLater(e2ee.initialize(), throwsA(isA<FormatException>()));
      await until(
        tester,
        () => find.text(l10n.recoverWithPassphrase).evaluate().isNotEmpty,
        'Approved device must offer passphrase recovery',
      );
      await tester.ensureVisible(find.text(l10n.signOut));
      await tester.tap(find.text(l10n.signOut));
      await until(
        tester,
        () => find.text(l10n.signOutAnyway).evaluate().isNotEmpty,
        'Local-only note must trigger the data-loss warning',
      );
      expect(find.text(l10n.externalSyncLogoutPending), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await until(
        tester,
        () => find.text(l10n.signOutAnyway).evaluate().isEmpty,
        'Cancel did not close the warning',
      );
      expect(auth.currentUser?.uid, owner.uid);
      final recover = find.text(l10n.recoverWithPassphrase);
      await tester.ensureVisible(recover);
      await tester.tap(recover);
      await until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'Missing recovery dialog',
      );
      await tester.enterText(
        find.byType(TextField).last,
        'Wrong temporary passphrase',
      );
      final submit = find.widgetWithText(FilledButton, l10n.recover);
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await until(
        tester,
        () => find.text(l10n.incorrectPassphrase).evaluate().isNotEmpty,
        'Incorrect passphrase must be rejected',
      );
      expect(e2ee.isCryptoReady, isFalse);
      await tester.enterText(find.byType(TextField).last, phrase);
      await tester.tap(submit);
      await until(
        tester,
        () => e2ee.isCryptoReady && find.byType(AlertDialog).evaluate().isEmpty,
        'Passphrase recovery did not unlock the device',
      );
      expect((await e2ee.noteEncryption.decryptNote(encrypted))?.title, title);
      expect((await Note.findById(note.id!))?.title, title);
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.signOut();
    },
  );
}
