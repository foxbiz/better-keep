@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'support/offline_firebase.dart';

import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => OfflineFirebase().configure());
  final legacyKey = List.filled(32, 3);
  final hex = '03' * 32;
  final umk = Uint8List.fromList(List.filled(32, 7));
  Future<void> seed() async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(base64Encode(umk)),
      secretKey: SecretKey(legacyKey),
    );
    SharedPreferences.setMockInitialValues({
      'user_uid': 'owner',
      'e2ee_umk_cache': base64Encode([
        ...box.nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]),
      'firebase_emulator.e2ee_umk_cache': 'other-environment',
      'notes': 'keep-notes',
    });
  }

  test(
    'legacy keys survive reload until recovery, new keys stay in memory',
    () async {
      await seed();
      final first = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await first.init(uid: 'owner');
      expect(await first.getCachedUMK(), umk);
      expect(first.needsLegacyRecoverySetup, true);
      expect(await first.wasAccountInitialized('owner'), true);
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('e2ee_umk_cache');
      await first.cacheUnwrappedUMK(Uint8List.fromList(List.filled(32, 9)));
      expect(prefs.getString('e2ee_umk_cache'), persisted);
      final reloaded = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await reloaded.init(uid: 'owner');
      expect(await reloaded.getCachedUMK(), umk);
      await first.completeLegacyRecovery('other-account');
      expect(prefs.getString('e2ee_umk_cache'), persisted);
      await first.completeLegacyRecovery('owner');
      expect(prefs.containsKey('e2ee_umk_cache'), false);
      expect(
        prefs.getString('firebase_emulator.e2ee_umk_cache'),
        'other-environment',
      );
      expect(prefs.getString('notes'), 'keep-notes');
      final fresh = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await fresh.init(uid: 'owner');
      expect(await fresh.getCachedUMK(), null);
      expect(await fresh.getRememberDevice(), false);
      expect(await fresh.wasAccountInitialized('owner'), true);
    },
  );
  test(
    'wrong key and account changes cannot erase or load legacy material',
    () async {
      await seed();
      final store = E2EESecureStorage.forTesting(legacyKeyHex: '04' * 32);
      await expectLater(
        store.init(uid: 'owner'),
        throwsA(isA<SecureStorageUnavailable>()),
      );
      expect(await store.getCachedUMK(), null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('e2ee_umk_cache'), true);
      final other = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await other.init(uid: 'other');
      expect(await other.getCachedUMK(), null);
      await other.init(uid: 'owner', isCurrent: () => false);
      expect(await other.getCachedUMK(), null);
    },
  );
  test('logout clears legacy data in the current environment only', () async {
    await seed();
    final store = E2EESecureStorage.forTesting(legacyKeyHex: hex);
    await store.init(uid: 'owner');
    await store.clearAll();
    expect(await store.getCachedUMK(), null);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('e2ee_umk_cache'), false);
    expect(
      prefs.getString('firebase_emulator.e2ee_umk_cache'),
      'other-environment',
    );
  });
}
