import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/pages/setup_recovery_key_page.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const path = 'users/account-a/e2ee/recovery_key';
  final master = Uint8List.fromList(List.filled(32, 42));
  late OfflineFirebase backend;
  late Map<String, dynamic> existing;
  final recovery = RecoveryKeyService.instance;

  setUpAll(() async {
    final salt = KeyDerivation.generateSalt();
    final key = await KeyDerivation.deriveKeyWithKdf(
      'OriginalPassphrase',
      salt,
      KdfType.pbkdf2,
    );
    final encrypted = await AuthenticatedCipher.encryptString(
      base64Encode(master),
      key,
    );
    existing = RecoveryKeyData(
      encryptedUMK: encrypted.ciphertext,
      nonce: encrypted.nonce,
      salt: base64Encode(salt),
      createdAt: DateTime.utc(2026),
      kdfAlgorithm: KdfAlgorithm.pbkdf2,
    ).toFirestore();
  });
  setUp(() {
    backend = OfflineFirebase()..configure();
    backend.firestore.documents[path] = Map.of(existing);
    DeviceManager.instance.setCachedUMKForTesting(master);
  });
  tearDown(() async {
    DeviceManager.instance.invalidateSession();
    backend.firebaseSync.dispose();
    await backend.auth.changes.close();
    await backend.firestore.events.close();
  });

  test('existing recovery is verified without replacing its record', () async {
    await recovery.verifyLegacyRecovery('OriginalPassphrase');
    expect(backend.firestore.documents[path], existing);
    expect(backend.firestore.writes, isEmpty);
    await expectLater(
      recovery.verifyLegacyRecovery('WrongPassphrase'),
      throwsA(isA<RecoveryKeyException>()),
    );
    DeviceManager.instance.setCachedUMKForTesting(Uint8List(32));
    await expectLater(
      recovery.verifyLegacyRecovery('OriginalPassphrase'),
      throwsA(isA<RecoveryKeyException>()),
    );
    expect(backend.firestore.documents[path], existing);
  });

  test('creation refuses to overwrite existing recovery', () async {
    await expectLater(
      recovery.createRecoveryKey('NewPassphrase'),
      throwsA(
        isA<RecoveryKeyException>().having(
          (e) => e.kind,
          'kind',
          RecoveryKeyFailureKind.alreadyExists,
        ),
      ),
    );
    expect(backend.firestore.documents[path], existing);
  });

  test(
    'new recovery can be created and updated only with its current passphrase',
    () async {
      backend.firestore.documents.remove(path);
      await recovery.createRecoveryKey('FirstPassphrase');
      final first = Map<String, dynamic>.of(backend.firestore.documents[path]!);
      await expectLater(
        recovery.updateRecoveryKey('WrongPassphrase', 'SecondPassphrase'),
        throwsA(isA<RecoveryKeyException>()),
      );
      expect(backend.firestore.documents[path], first);
      await recovery.updateRecoveryKey('FirstPassphrase', 'SecondPassphrase');
      expect(backend.firestore.documents[path], isNot(first));
      expect(await recovery.verifyPassphrase('SecondPassphrase'), true);
    },
  );

  test(
    'concurrent recovery creation cannot replace the winning record',
    () async {
      backend.firestore.documents.remove(path);
      backend.firestore.commit = () async {
        backend.firestore.documents[path] = Map.of(existing);
      };
      await expectLater(
        recovery.createRecoveryKey('OtherPassphrase'),
        throwsA(
          isA<RecoveryKeyException>().having(
            (e) => e.kind,
            'kind',
            RecoveryKeyFailureKind.alreadyExists,
          ),
        ),
      );
      expect(backend.firestore.documents[path], existing);
    },
  );

  Widget app() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () =>
              showSetupRecoveryKeyPage(context, legacyRecovery: true),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  testWidgets('offline transition can be dismissed to local notes', (
    tester,
  ) async {
    backend.firestore.response = (_, _) async => throw StateError('offline');
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(backend.firestore.documents[path], existing);
  });
  testWidgets('existing recovery shows verification only', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Verify Recovery Key'), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(backend.firestore.documents[path], existing);
  });
}
