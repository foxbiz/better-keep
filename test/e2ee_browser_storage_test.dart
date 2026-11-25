@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';

import 'package:better_keep/services/firebase_backend.dart';

import 'support/offline_firebase.dart';

import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/file_system.dart'
    show currentAccountFileGeneration;

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_operation.dart';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';

import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/e2ee/browser_device_store_web.dart'
    as browser;
import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineFirebase backend;
  setUp(() {
    backend = OfflineFirebase();
    backend.auth.currentUser = OfflineUser('owner');
    backend.configure();
  });
  final liveKey = FirebaseLocalDataScope.live.secureStorageKey;
  final localUmk = liveKey('e2ee_umk_cache');
  final emulatorUmk = FirebaseLocalDataScope.emulator.secureStorageKey(
    'e2ee_umk_cache',
  );
  final legacyKey = List.filled(32, 3);
  final hex = '03' * 32;
  final umk = Uint8List.fromList(List.filled(32, 7));
  Future<String> encryptedLegacyValue(String value) async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(value),
      secretKey: SecretKey(legacyKey),
    );
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<void> seed({bool approved = false}) async {
    final device = approved ? await KeyExchange.generateKeyPair() : null;
    SharedPreferences.setMockInitialValues({
      'user_uid': 'owner',
      localUmk: await encryptedLegacyValue(base64Encode(umk)),
      if (device != null) ...{
        liveKey('e2ee_device_id'): await encryptedLegacyValue('legacy-device'),
        liveKey('e2ee_device_status'): await encryptedLegacyValue('approved'),
        liveKey('e2ee_device_private_key'): await encryptedLegacyValue(
          base64Encode(device.privateKey),
        ),
        liveKey('e2ee_device_public_key'): await encryptedLegacyValue(
          base64Encode(device.publicKey),
        ),
      },
      emulatorUmk: 'other-environment',
      'notes': 'keep-notes',
    });
  }

  test('legacy recovery remains available and unapproved master keys stay in memory', () async {
    await seed();
    final first = E2EESecureStorage.forTesting(legacyKeyHex: hex);
    await first.init(uid: 'owner');
    expect(await first.getCachedUMK(), umk);
    expect(first.needsLegacyRecoverySetup, true);
    expect(await first.wasAccountInitialized('owner'), true);
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(localUmk);
    await first.cacheUnwrappedUMK(Uint8List.fromList(List.filled(32, 9)));
    expect(prefs.getString(localUmk), persisted);
    final reloaded = E2EESecureStorage.forTesting(legacyKeyHex: hex);
    await reloaded.init(uid: 'owner');
    expect(await reloaded.getCachedUMK(), umk);
    await first.completeLegacyRecovery('other-account');
    expect(prefs.getString(localUmk), persisted);
    await first.completeLegacyRecovery('owner');
    expect(prefs.containsKey(localUmk), false);
    expect(prefs.getString(emulatorUmk), 'other-environment');
    expect(prefs.getString('notes'), 'keep-notes');
    final fresh = E2EESecureStorage.forTesting(legacyKeyHex: hex);
    await fresh.init(uid: 'owner');
    expect(await fresh.getCachedUMK(), null);
    expect(await fresh.getRememberDevice(), true);
    expect(await fresh.wasAccountInitialized('owner'), true);
  });
  test(
    'an approved legacy browser survives a deferred recovery and upgrade',
    () async {
      await seed(approved: true);
      final first = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await first.init(uid: 'owner');
      expect(first.needsLegacyRecoverySetup, isTrue);
      expect(await first.getCachedUMK(), umk);

      final next = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await next.init(uid: 'owner');
      expect(await next.getDeviceId(), 'legacy-device');
      expect(await next.getCachedDeviceStatus(), 'approved');
      await next.completeLegacyRecovery('owner');

      final reopened = E2EESecureStorage.forTesting();
      await reopened.init(uid: 'owner');
      addTearDown(() => reopened.clearAll(signingOut: true));
      expect(reopened.hasRememberedBrowserIdentity, isTrue);
      expect(await reopened.getDeviceId(), 'legacy-device');
      expect(await reopened.getCachedUMK(), isNull);
      expect(reopened.needsLegacyRecoverySetup, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(localUmk), isFalse);
      expect(prefs.getString('user_uid'), 'owner');
    },
  );

  test('only an approved browser identity survives restart; stale tabs cannot restore trust after logout', () async {
    SharedPreferences.setMockInitialValues({});
    final first = E2EESecureStorage.forTesting();
    await first.init(uid: 'owner');
    await first.clearAll();
    await first.storeDeviceId('qa-device');
    await first.storeDevicePublicKey(Uint8List(32));
    await first.storeDevicePrivateKey(Uint8List.fromList(List.filled(32, 4)));
    await first.cacheUnwrappedUMK(umk);
    final pending = E2EESecureStorage.forTesting();
    await pending.init(uid: 'owner');
    expect(await pending.hasDeviceKeys(), isFalse);

    await first.cacheDeviceStatus('approved');
    final restored = E2EESecureStorage.forTesting();
    await restored.init(uid: 'owner');
    expect(await restored.hasDeviceKeys(), isTrue);
    expect(await restored.getDeviceId(), 'qa-device');
    expect(await restored.getCachedDeviceStatus(), 'approved');
    expect(await restored.getCachedUMK(), isNull);

    backend.auth.currentUser = OfflineUser('second');
    final other = E2EESecureStorage.forTesting();
    await other.init(uid: 'second');
    expect(await other.hasDeviceKeys(), isFalse);
    expect(await restored.getDevicePrivateKey(), isNull);
    backend.auth.currentUser = OfflineUser('owner');

    await pending.clearAll();
    final afterCancellation = E2EESecureStorage.forTesting();
    await afterCancellation.init(uid: 'owner');
    expect(await afterCancellation.getDeviceId(), 'qa-device');

    await restored.clearAll(signingOut: true);
    await first.storeDeviceId('stale');
    await first.cacheDeviceStatus('approved');
    expect(await first.getCachedUMK(), umk);
    final afterLogout = E2EESecureStorage.forTesting();
    await afterLogout.init(uid: 'owner');
    expect(await afterLogout.hasDeviceKeys(), isFalse);
  });

  test('failed IndexedDB writes preserve a verified session and require proof for sign-out', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = E2EESecureStorage.forTesting();
    await storage.init(uid: 'owner');
    await storage.clearAll();
    await storage.storeDeviceId('approved-device');
    await storage.storeDevicePublicKey(Uint8List(32));
    await storage.storeDevicePrivateKey(Uint8List(32));
    await storage.cacheUnwrappedUMK(umk);
    await storage.cacheDeviceStatus('approved');
    final webStorage =
        web.window.getProperty<JSObject>('Storage'.toJS)['prototype']
            as JSObject;
    final getItem = webStorage['getItem'];
    try {
      String unavailable(String _) =>
          throw StateError('Web Storage is blocked');
      webStorage['getItem'] = unavailable.toJS;
      final blocked = E2EESecureStorage.forTesting();
      await blocked.init(uid: 'owner');
      expect(blocked.hasRememberedBrowserIdentity, isFalse);
      // The identity can still be verified online once storage is readable.
      expect(await blocked.getCachedDeviceStatus(), 'approved');
      expect(await blocked.hasDeviceKeys(), isTrue);
    } finally {
      webStorage['getItem'] = getItem;
    }
    final prototype =
        web.window.getProperty<JSObject>('IDBObjectStore'.toJS)['prototype']
            as JSObject;
    final original = prototype['put'];
    try {
      void rejectPut() => throw StateError('simulated quota failure');
      prototype['put'] = rejectPut.toJS;
      await storage.storeDeviceId('second-device');
      await storage.cacheDeviceStatus('approved');
      expect(await storage.getCachedUMK(), umk);
      final fresh = E2EESecureStorage.forTesting();
      await fresh.init(uid: 'owner');
      expect(await fresh.getDeviceId(), 'approved-device');
      await expectLater(
        storage.clearAll(signingOut: true, revokedDeviceId: 'second-device'),
        throwsStateError,
      );
      final prefs = await SharedPreferences.getInstance();
      final recovery = LocalStorageRecovery(prefs);
      final next = await recovery.beginSignOut();
      await storage.clearAll(signingOut: true);
      expect(await storage.getCachedUMK(), isNull);
      await prefs.reload();
      expect(currentAccountFileGeneration(prefs), next);
      await recovery.finishSignOut();
      final nextLibrary = E2EESecureStorage.forTesting();
      await nextLibrary.init(uid: 'owner');
      expect(await nextLibrary.hasDeviceKeys(), isFalse);
      // An exact remote revocation is sufficient even without a pending journal.
      await nextLibrary.clearAll(
        signingOut: true,
        revokedDeviceId: 'approved-device',
      );
    } finally {
      prototype['put'] = original;
      await storage.clearAll(signingOut: true);
    }
  });

  test(
    'revocation survives a failed IndexedDB write and a stale approval',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storage = E2EESecureStorage.forTesting();
      await storage.init(uid: 'owner');
      await storage.clearAll();
      await storage.storeDeviceId('approved-device');
      await storage.storeDevicePublicKey(Uint8List(32));
      await storage.storeDevicePrivateKey(Uint8List(32));
      await storage.cacheUnwrappedUMK(umk);
      await storage.cacheDeviceStatus('approved');
      final prototype =
          web.window.getProperty<JSObject>('IDBObjectStore'.toJS)['prototype']
              as JSObject;
      final original = prototype['put'];
      try {
        void rejectPut() => throw StateError('simulated quota failure');
        prototype['put'] = rejectPut.toJS;
        final stale = E2EESecureStorage.forTesting();
        await stale.init(uid: 'owner');
        await stale.cacheUnwrappedUMK(umk);
        await storage.cacheDeviceStatus('revoked');
        await storage.clearCachedUMK();
        await stale.cacheDeviceStatus('approved');
        final cold = E2EESecureStorage.forTesting();
        await cold.init(uid: 'owner');
        expect(await cold.getCachedDeviceStatus(), 'revoked');
        expect(cold.hasRememberedBrowserIdentity, isFalse);
        expect(await cold.hasDeviceKeys(), isFalse);
        expect(await cold.getCachedUMK(), isNull);
      } finally {
        prototype['put'] = original;
        await storage.clearAll(signingOut: true);
      }
    },
  );

  test(
    'concurrent browser approval writes converge only on matching identities',
    () async {
      SharedPreferences.setMockInitialValues({});
      Future<E2EESecureStorage> tab() async {
        final store = E2EESecureStorage.forTesting();
        await store.init(uid: 'owner');
        await store.cacheUnwrappedUMK(umk);
        return store;
      }

      final first = await tab();
      await first.clearAll();
      await first.storeDeviceId('shared');
      await first.storeDevicePublicKey(Uint8List(32));
      await first.storeDevicePrivateKey(Uint8List(32));
      await first.cacheUnwrappedUMK(umk);
      await first.cacheDeviceStatus('approved');
      Future<void> publish(E2EESecureStorage tab, String receipt) async {
        await tab.storeAcceptedApproval(receipt);
        await tab.cacheDeviceStatus('approved');
      }

      try {
        final second = await tab();
        await publish(first, 'intermediate');
        await first.clearApprovalRequest();
        await first.cacheDeviceStatus(
          'approved',
        ); // Same original bytes at a newer revision.
        await publish(second, 'agreed');
        expect(await (await tab()).getAcceptedApproval(), 'agreed');

        await publish(
          first,
          'agreed',
        ); // Another tab already wrote the desired data.
        expect(first.hasRememberedBrowserIdentity, true);
        await publish(first, 'winner');
        await publish(second, 'different');
        expect(second.hasRememberedBrowserIdentity, false);
        expect(await (await tab()).getAcceptedApproval(), 'winner');
      } finally {
        await first.clearAll(signingOut: true);
      }
    },
  );

  test(
    'a cold read cleans only the grant from an interrupted publication',
    () async {
      const scope = 'interrupted-publication-fixture';
      const uid = 'fixture-owner';
      final prior = browser.newOfflineGrantId();
      final interrupted = browser.newOfflineGrantId();
      final (originalRevision, _) = await browser.readDeviceIdentity(
        scope,
        uid,
      );
      final revision = await browser.writeDeviceIdentity(
        scope,
        uid,
        'prior identity',
        expectedRevision: originalRevision,
        isCurrent: () => true,
        grantToActivate: prior,
      );
      final storage = web.window.localStorage;
      final prototype =
          web.window.getProperty<JSObject>('Storage'.toJS)['prototype']
              as JSObject;
      final setItem = prototype['setItem'] as JSFunction;
      try {
        // Leave the cross-store side effect in place as if the renderer exited
        // after setItem but before the identity transaction could commit.
        void interrupt(String key, String value) {
          setItem.callAsFunction(storage, key.toJS, value.toJS);
          throw StateError('interrupted');
        }

        prototype['setItem'] = interrupt.toJS;
        await expectLater(
          browser.writeDeviceIdentity(
            scope,
            uid,
            'new identity',
            expectedRevision: revision,
            isCurrent: () => true,
            grantToActivate: interrupted,
          ),
          throwsStateError,
        );
        expect(
          browser.offlineGrantState(interrupted),
          browser.OfflineGrantState.active,
        );
        expect(await browser.readDeviceIdentity(scope, uid), (
          revision,
          'prior identity',
        ));
        expect(
          browser.offlineGrantState(prior),
          browser.OfflineGrantState.active,
        );
        expect(
          browser.offlineGrantState(interrupted),
          browser.OfflineGrantState.missing,
        );
      } finally {
        prototype['setItem'] = setItem;
        await browser.writeDeviceIdentity(
          scope,
          uid,
          null,
          expectedRevision: null,
          isCurrent: () => true,
        );
        browser.retireOfflineGrant(prior);
        browser.retireOfflineGrant(interrupted);
      }
    },
  );

  test(
    'stale local clears preserve a newer revision of the same device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final current = E2EESecureStorage.forTesting();
      await current.init(uid: 'owner');
      await current.clearAll();
      try {
        await current.storeDeviceId('shared-device');
        await current.storeDevicePublicKey(Uint8List(32));
        await current.storeDevicePrivateKey(Uint8List(32));
        await current.cacheUnwrappedUMK(umk);
        await current.cacheDeviceStatus('approved');

        final older = E2EESecureStorage.forTesting();
        await older.init(uid: 'owner');
        final deleted = E2EESecureStorage.forTesting();
        await deleted.init(uid: 'owner');
        expect(older.hasRememberedBrowserIdentity, isTrue);
        await current.storeAcceptedApproval('newer-receipt');
        await current.cacheDeviceStatus('approved');

        await older.clearCachedUMK();
        expect(current.hasRememberedBrowserIdentity, isTrue);
        await older.clearAll();
        final reopened = E2EESecureStorage.forTesting();
        await reopened.init(uid: 'owner');
        expect(reopened.hasRememberedBrowserIdentity, isTrue);
        expect(await reopened.getAcceptedApproval(), 'newer-receipt');

        await deleted.cacheDeviceStatus('needs_recovery', deviceDeleted: true);
        await deleted.clearCachedUMK();
        final cold = E2EESecureStorage.forTesting();
        await cold.init(uid: 'owner');
        expect(cold.hasRememberedBrowserIdentity, isFalse);
        expect(await cold.hasDeviceKeys(), isFalse);
      } finally {
        await current.clearAll(signingOut: true);
      }
    },
  );

  test('local reset with a failed trust write allows fresh pairing without restoring keys', () async {
    SharedPreferences.setMockInitialValues({});
    final store = E2EESecureStorage.forTesting();
    await store.init(uid: 'owner');
    await store.clearAll();
    await store.storeDeviceId('reset-device');
    await store.storeDevicePublicKey(Uint8List(32));
    await store.storeDevicePrivateKey(Uint8List(32));
    await store.cacheUnwrappedUMK(umk);
    await store.cacheDeviceStatus('approved');
    final prototype =
        web.window.getProperty<JSObject>('IDBObjectStore'.toJS)['prototype']
            as JSObject;
    final original = prototype['put'];
    try {
      void rejectPut() => throw StateError('simulated quota failure');
      prototype['put'] = rejectPut.toJS;
      await store.clearCachedUMK();
      final cold = E2EESecureStorage.forTesting();
      await cold.init(uid: 'owner');
      expect(await cold.getCachedDeviceStatus(), isNull);
      expect(cold.hasRememberedBrowserIdentity, false);
      expect(await cold.hasDeviceKeys(), false);
      expect(await cold.getCachedUMK(), isNull);
      expect(await cold.wasAccountInitialized('owner'), true);
    } finally {
      prototype['put'] = original;
      await store.clearAll(signingOut: true);
    }
  });

  test(
    'committing a rotated library retires only the superseded grant',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final local = web.window.localStorage;
      Set<String> grants() => {
        for (var i = 0; i < local.length; i++)
          if (local.key(i) case final String key
              when key.startsWith('better-keep.offline-grant.'))
            key,
      };
      Future<void> approve(E2EESecureStorage store, String deviceId) async {
        await store.storeDeviceId(deviceId);
        await store.storeDevicePublicKey(Uint8List(32));
        await store.storeDevicePrivateKey(Uint8List(32));
        await store.cacheUnwrappedUMK(umk);
        await store.cacheDeviceStatus('approved');
      }

      final first = E2EESecureStorage.forTesting();
      await first.init(uid: 'owner');
      await first.clearAll();
      const unrelated = 'better-keep.offline-grant.unrelated-fixture';
      local.setItem(unrelated, '1');
      final before = grants();
      final next = E2EESecureStorage.forTesting();
      try {
        await approve(first, 'previous');
        final obsolete = grants().difference(before).single;
        await prefs.setString(
          'account_files.live.active',
          '00000000-0000-4000-8000-000000000001',
        );
        await next.init(uid: 'owner');
        expect(await next.hasDeviceKeys(), false);
        expect(local.getItem(obsolete), '1');
        await approve(next, 'replacement');
        expect(local.getItem(obsolete), isNull);
        expect(local.getItem(unrelated), '1');
        final replacement = grants().difference(before).single;
        expect(replacement, isNot(obsolete));
        // An older tab may still receive a late device-status notification.
        await first.cacheDeviceStatus('revoked');
        await first.cacheDeviceStatus('needs_recovery', deviceDeleted: true);
        expect(local.getItem(obsolete), isNull);
        expect(local.getItem(replacement), '1');
        final cold = E2EESecureStorage.forTesting();
        await cold.init(uid: 'owner');
        expect(await cold.getDeviceId(), 'replacement');
        expect(cold.hasRememberedBrowserIdentity, true);
        await cold.clearAll(signingOut: true);
        expect(grants(), before);
      } finally {
        local.removeItem(unrelated);
        await next.clearAll(signingOut: true);
      }
    },
  );

  test(
    'unreadable browser history retries before permitting first-device setup',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = E2EESecureStorage.forTesting();
      final prototype =
          web.window.getProperty<JSObject>('IDBFactory'.toJS)['prototype']
              as JSObject;
      final original = prototype['open'];
      try {
        void unavailable() => throw StateError('storage blocked');
        prototype['open'] = unavailable.toJS;
        await store.init(uid: 'owner');
        expect(await store.hasDeviceKeys(), isFalse);
        await expectLater(
          store.wasAccountInitialized('owner'),
          throwsA(isA<SecureStorageUnavailable>()),
        );

        // Known remote recovery is sufficient to route this account without
        // making a new master key or relying on the unreadable trust record.
        backend.firestore.queryResponse = (_, _) async =>
            OfflineQuerySnapshot({});
        backend.firestore.documents['users/owner/e2ee/recovery_key'] = {};
        await AuthService.init(
          prefs: await SharedPreferences.getInstance(),
          deferLocalRestore: true,
        );
        final e2ee = E2EEService.instance;
        addTearDown(e2ee.dispose);
        await e2ee.initialize();
        expect(e2ee.status.value, E2EEStatus.needsRecovery);
        expect(e2ee.isCryptoReady, false);
      } finally {
        prototype['open'] = original;
      }
      await store.init(uid: 'owner');
      expect(await store.wasAccountInitialized('owner'), isFalse);
    },
  );

  test('blocked IndexedDB during sign-out requires a journal and retires the old library', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = E2EESecureStorage.forTesting();
    await storage.init(uid: 'owner');
    await storage.clearAll();
    await storage.storeDeviceId('blocked-logout-device');
    await storage.storeDevicePublicKey(Uint8List(32));
    await storage.storeDevicePrivateKey(Uint8List(32));
    await storage.cacheUnwrappedUMK(umk);
    await storage.cacheDeviceStatus('approved');
    expect(storage.hasRememberedBrowserIdentity, isTrue);
    final prototype =
        web.window.getProperty<JSObject>('IDBFactory'.toJS)['prototype']
            as JSObject;
    final original = prototype['open'];
    final recovery = LocalStorageRecovery(prefs);
    try {
      void unavailable() => throw StateError('storage blocked');
      prototype['open'] = unavailable.toJS;
      // A restarted cleanup has no cached grant to invalidate.
      final cold = E2EESecureStorage.forTesting();
      await expectLater(cold.clearAll(signingOut: true), throwsA(anything));
      expect(storage.hasRememberedBrowserIdentity, isTrue);
      final next = await recovery.beginSignOut();
      await cold.clearAll(signingOut: true);
      await prefs.reload();
      expect(currentAccountFileGeneration(prefs), next);
      await recovery.finishSignOut();
    } finally {
      prototype['open'] = original;
    }
    final reopened = E2EESecureStorage.forTesting();
    await reopened.init(uid: 'owner');
    expect(reopened.hasRememberedBrowserIdentity, isFalse);
    expect(await reopened.hasDeviceKeys(), isFalse);
    await reopened.clearAll(signingOut: true);
  });

  test('pairing secrets stay transient; completed proofs survive reload until revocation', () async {
    SharedPreferences.setMockInitialValues({});
    final store = E2EESecureStorage.forTesting();
    await store.init(uid: 'owner');
    await store.clearAll();
    final pub = Uint8List.fromList(List.filled(32, 6));
    final request = DeviceVerificationRequest.create(
      account: 'owner',
      environment: 'fixture',
      deviceId: 'paired',
      publicKey: pub,
    );
    await store.storeDevicePublicKey(pub);
    await store.storeDevicePrivateKey(Uint8List(32));
    await store.storeDeviceId('paired');
    await store.storeApprovalRequest(request.qrData);
    await store.cacheUnwrappedUMK(umk);
    await expectLater(
      store.cacheDeviceStatus('approved'),
      throwsA(isA<BrowserApprovalNotReady>()),
    );
    expect(await store.getCachedDeviceStatus(), isNot('approved'));
    final pending = E2EESecureStorage.forTesting();
    await pending.init(uid: 'owner');
    expect(await pending.hasDeviceKeys(), false);
    await store.storeAcceptedApproval('fixture-accepted-receipt');
    await store.completeApprovalRequest(jsonEncode(request.toJson()));
    await store.cacheDeviceStatus('approved');
    final restored = E2EESecureStorage.forTesting();
    await restored.init(uid: 'owner');
    expect(await restored.getAcceptedApproval(), 'fixture-accepted-receipt');
    expect(await restored.getApprovalRequest(), jsonEncode(request.toJson()));
    await restored.cacheDeviceStatus('revoked');
    final revoked = E2EESecureStorage.forTesting();
    await revoked.init(uid: 'owner');
    expect(await revoked.hasDeviceKeys(), false);
    expect(await revoked.getAcceptedApproval(), isNull);
  });

  test(
    'wrong key and account changes cannot erase or load legacy material',
    () async {
      await seed();
      final store = E2EESecureStorage.forTesting(legacyKeyHex: '04' * 32);
      await expectLater(
        store.init(uid: 'owner'),
        throwsA(
          isA<SecureStorageUnavailable>().having(
            (e) => e.state,
            'state',
            LocalEncryptionState.legacyRecoveryUnavailable,
          ),
        ),
      );
      expect(await store.getCachedUMK(), null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(localUmk), true);
      final other = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await other.init(uid: 'other');
      expect(await other.getCachedUMK(), null);
      await other.init(uid: 'owner', isCurrent: () => false);
      expect(await other.getCachedUMK(), null);
    },
  );
  test(
    'a cancelled legacy import preserves its source without reporting bad keys',
    () async {
      await seed();
      final prefs = await SharedPreferences.getInstance();
      final marker = FirebaseBackend.localDataScope.preferenceKey(
        'e2ee_initialized.owner',
      );
      final store = E2EESecureStorage.forTesting(legacyKeyHex: hex);
      await expectLater(
        runCloudOperation(
          () => !prefs.containsKey(marker),
          () => store.init(uid: 'owner'),
        ),
        throwsA(isA<CloudOperationCancelled>()),
      );
      expect(await store.getCachedUMK(), isNull);
      expect(prefs.containsKey(localUmk), isTrue);
      await store.init(uid: 'owner');
      expect(await store.getCachedUMK(), umk);
    },
  );

  test('restored legacy key failure and Retry stay local', () async {
    await seed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(localUmk, 'malformed');
    await AuthService.init(prefs: prefs, deferLocalRestore: true);
    final e2ee = E2EEService.instance;
    addTearDown(e2ee.dispose);
    AuthService.cloudRecovery.stop();
    final reads = backend.firestore.reads.length;
    final queries = backend.firestore.queryReads.length;
    await AuthService.initializeCurrentUserServices();
    await AuthService.retryPostSignInInitialization();
    expect(e2ee.localState, LocalEncryptionState.legacyRecoveryUnavailable);
    expect(
      AuthService.postSignInState.value.failedOperation,
      'restore-local-encryption',
    );
    expect(AuthService.cloudRecovery.hasSession, isFalse);
    expect(backend.firestore.reads.length, reads);
    expect(backend.firestore.queryReads.length, queries);
    expect(prefs.getString(localUmk), 'malformed');
  });
  test('logout clears legacy data in the current environment only', () async {
    await seed();
    final store = E2EESecureStorage.forTesting(legacyKeyHex: hex);
    await store.init(uid: 'owner');
    await store.clearAll();
    expect(await store.getCachedUMK(), null);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(localUmk), false);
    expect(prefs.getString(emulatorUmk), 'other-environment');
  });
  test(
    'an early master key schedules one check and cannot approve the browser',
    () async {
      SharedPreferences.setMockInitialValues({'user_uid': 'owner'});
      await AuthService.init(
        prefs: await SharedPreferences.getInstance(),
        deferLocalRestore: true,
      );
      final e2ee = E2EEService.instance;
      final recovery = AuthService.cloudRecovery;
      recovery.setForeground(false);
      recovery.start('owner');
      final checked = Completer<void>();
      var checks = 0;
      void onActivity() {
        if (recovery.activity.value == CloudRecoveryActivity.verifying) {
          checks++;
        } else if (checks > 0 && !checked.isCompleted) {
          checked.complete();
        }
      }

      recovery.activity.addListener(onActivity);
      try {
        e2ee.status.value = E2EEStatus.pendingApproval;
        e2ee.listenForStatusChanges();
        e2ee.deviceManager.setCachedUMKForTesting(umk);
        await checked.future.timeout(const Duration(seconds: 3));
        expect(checks, 1);
        expect(e2ee.status.value, E2EEStatus.pendingApproval);
        expect(e2ee.isCryptoReady, isFalse);
      } finally {
        recovery.activity.removeListener(onActivity);
        recovery.stop();
        recovery.setForeground(true);
        await e2ee.dispose();
      }
    },
  );
  test('approved local library opens before a server read and cloud keys unlock only after verification', () async {
    SharedPreferences.setMockInitialValues({'user_uid': 'owner'});
    final previous = E2EESecureStorage.forTesting();
    await previous.init(uid: 'owner');
    await previous.clearAll();
    final pair = await KeyExchange.generateKeyPair();
    final secret = await KeyExchange.deriveSharedSecret(
      pair.privateKey,
      pair.publicKey,
    );
    final wrapped = await AuthenticatedCipher.encryptString(
      base64Encode(umk),
      secret,
    );
    backend.firestore.documents['users/owner/devices/device-a'] = {
      'status': 'approved',
      'public_key': base64Encode(pair.publicKey),
      'created_at': DateTime.now().toIso8601String(),
      'wrapped_umk': wrapped.ciphertext,
      'wrapped_umk_nonce': wrapped.nonce,
    };
    await previous.storeDeviceId('device-a');
    await previous.storeDevicePublicKey(pair.publicKey);
    await previous.storeDevicePrivateKey(pair.privateKey);
    await previous.cacheUnwrappedUMK(umk);
    await previous.cacheDeviceStatus('approved');

    final e2ee = E2EEService.instance;
    addTearDown(e2ee.dispose);
    await AuthService.init(
      prefs: await SharedPreferences.getInstance(),
      deferLocalRestore: true,
    );
    expect(await e2ee.preloadCachedStatus(), true);
    expect(e2ee.canAccessLocalNotes, isTrue);
    expect(e2ee.isCryptoReady, isFalse);
    expect(
      backend.firestore.reads.where((read) => read.$1.contains('/devices/')),
      isEmpty,
    );
    expect(e2ee.deviceManager.getUMK(), isNull);
    await e2ee.initialize();
    expect(
      resolveAuthenticatedStartupRoute(
        postSignInState: PostSignInState.ready,
        e2eeStatus: e2ee.status.value,
        localState: e2ee.localState,
      ),
      AuthenticatedStartupRoute.home,
    );
    expect(e2ee.deviceManager.getUMK(), umk);
    backend.firestore.documents['users/owner/devices/device-a']!['status'] =
        'revoked';
    expect(
      await e2ee.verifyLocalSessionAuthorization(),
      DeviceAuthorization.revoked,
    );
    expect(e2ee.canAccessLocalNotes, isFalse);
    expect(e2ee.isCryptoReady, isFalse);
    final revoked = E2EESecureStorage.forTesting();
    await revoked.init(uid: 'owner');
    expect(await revoked.hasDeviceKeys(), isFalse);
  });
}
