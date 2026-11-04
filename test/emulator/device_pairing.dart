// Run explicitly in Chrome with the isolated demo-better-keep-pairing emulator.
// Web plugin registration is required by Flutter's browser test runner.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/device_pairing_channel.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:better_keep/services/e2ee/firestore_pairing_mailbox.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_web/cloud_firestore_web.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_web/firebase_auth_web.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_web/firebase_core_web.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const project = 'demo-better-keep-pairing';
  const options = FirebaseOptions(
    apiKey: 'synthetic-emulator-key',
    appId: '1:123:web:pairing',
    messagingSenderId: '123',
    projectId: project,
    storageBucket: '$project.appspot.com',
  );
  FirebaseCoreWeb.registerWith(webPluginRegistrar);
  FirebaseAuthWeb.registerWith(webPluginRegistrar);
  FirebaseFirestoreWeb.registerWith(webPluginRegistrar);

  test('isolated Firestore pairing authenticates both devices and unlocks an encrypted note', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final trustedApp = await Firebase.initializeApp(
      name: 'trusted-$suffix',
      options: options,
    );
    final pendingApp = await Firebase.initializeApp(
      name: 'pending-$suffix',
      options: options,
    );
    final trustedAuth = FirebaseAuth.instanceFor(app: trustedApp);
    final pendingAuth = FirebaseAuth.instanceFor(app: pendingApp);
    await trustedAuth.useAuthEmulator('127.0.0.1', 19099);
    await pendingAuth.useAuthEmulator('127.0.0.1', 19099);
    final email = 'pairing-$suffix@example.test';
    const password = 'Disposable-Pairing-QA-Only!';
    final user = (await trustedAuth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    )).user!;
    await pendingAuth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    final trustedDb = FirebaseFirestore.instanceFor(app: trustedApp);
    final pendingDb = FirebaseFirestore.instanceFor(app: pendingApp);
    trustedDb.useFirestoreEmulator('127.0.0.1', 18080);
    pendingDb.useFirestoreEmulator('127.0.0.1', 18080);
    FirebaseBackend.configureForTesting(
      FirebaseBackendConfiguration(
        environment: FirebaseEnvironment.emulator,
        app: trustedApp,
        auth: trustedAuth,
        firestore: trustedDb,
        functions: FirebaseFunctions.instanceFor(app: trustedApp),
        storage: FirebaseStorage.instanceFor(app: trustedApp),
        databaseId: '(default)',
        localDataScope: FirebaseLocalDataScope.emulator,
        googleAuthMode: GoogleEmulatorAuthMode.mock,
      ),
    );
    final manager = DeviceManager.instance;
    final storage = E2EESecureStorage.instance;
    final trusted = await KeyExchange.generateKeyPair();
    final recipient = await KeyExchange.generateKeyPair();
    final master = Uint8List.fromList(List.generate(32, (i) => i + 1));
    await storage.storeDeviceId('trusted');
    await storage.storeDevicePrivateKey(trusted.privateKey);
    await storage.storeDevicePublicKey(trusted.publicKey);
    manager.setCachedUMKForTesting(master);
    final request = DeviceVerificationRequest.create(
      account: user.uid,
      environment: jsonEncode([project, '(default)', 'emulator']),
      deviceId: 'pending',
      publicKey: recipient.publicKey,
    );
    final public = DeviceVerificationRequest.fromJson(request.toJson());
    final path = 'users/${user.uid}/devices/pending';
    await trustedDb.doc('users/${user.uid}/devices/trusted').set({
      'status': 'approved',
      'public_key': trusted.publicKeyBase64,
    });
    await pendingDb.doc(path).set({
      'status': 'pending',
      'public_key': recipient.publicKeyBase64,
      'approval_protocol': DeviceVerificationRequest.version,
      'approval_request': request.toJson(),
      'created_at': DateTime.now().toIso8601String(),
    });
    final session = await PendingPairingCode.start(
      request,
      FirestorePairingMailbox(pendingDb.doc(path), request, () => true),
      isCurrent: () => true,
    );
    try {
      final wrong = session.code == '00000000' ? '11111111' : '00000000';
      await expectLater(
        manager.verifyDevicePairingCode(public, wrong, isCurrent: () => true),
        throwsStateError,
      );
      final before =
          (await trustedDb
                  .doc(path)
                  .get(const GetOptions(source: Source.server)))
              .data()!;
      expect(before.containsKey('wrapped_umk'), false);
      final verified = await manager.verifyDevicePairingCode(
        public,
        session.code,
        isCurrent: () => true,
      );
      final mailbox = jsonEncode((await trustedDb.doc(path).get()).data());
      expect(mailbox.contains(session.code), false);
      expect(mailbox.contains(request.qrData), false);
      // A substituted key after SRP verification must still fail the final transaction.
      await pendingDb.doc(path).update({'public_key': trusted.publicKeyBase64});
      await expectLater(manager.approveDevice(verified), throwsStateError);
      expect(
        (await pendingDb.doc(path).get()).data()!.containsKey('wrapped_umk'),
        false,
      );
      await expectLater(
        FirestorePairingMailbox(trustedDb.doc(path), public, () => true).read(),
        throwsStateError,
      );
      await pendingDb.doc(path).update({
        'public_key': recipient.publicKeyBase64,
      });
      final receipt = await manager.approveDevice(verified);
      expect(request.verifyAutomaticReceipt(receipt), isNotNull);
      final shared = await KeyExchange.deriveSharedSecret(
        recipient.privateKey,
        trusted.publicKey,
      );
      final bound = await AuthenticatedCipher.decryptString(
        receipt.ciphertext,
        receipt.nonce,
        shared,
      );
      final restored = request.decodeMasterKey(
        bound,
        envelopeVersion: DeviceVerificationRequest.version,
      );
      expect(restored, master);
      // A payload travels through Firestore, then only the approved key opens it.
      final note = await AuthenticatedCipher.encryptString(
        'QA note with tasks: [x] pair, [ ] sync',
        master,
      );
      final fixture = 'users/${user.uid}/pairing_qa/note';
      await trustedDb.doc(fixture).set({
        'ciphertext': note.ciphertext,
        'nonce': note.nonce,
      });
      final downloaded =
          (await pendingDb
                  .doc(fixture)
                  .get(const GetOptions(source: Source.server)))
              .data()!;
      expect(
        await AuthenticatedCipher.decryptString(
          downloaded['ciphertext'] as String,
          downloaded['nonce'] as String,
          restored,
        ),
        'QA note with tasks: [x] pair, [ ] sync',
      );
      final approved =
          (await pendingDb
                  .doc(path)
                  .get(const GetOptions(source: Source.server)))
              .data()!;
      expect(approved['status'], 'approved');
      expect(approved.containsKey('code_pairing'), false);
      await expectLater(
        manager.verifyDevicePairingCode(
          public,
          session.code,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
    } finally {
      session.dispose();
      await manager.dispose();
      await pendingAuth.signOut();
      await trustedAuth.signOut();
      await trustedApp.delete();
      await pendingApp.delete();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
