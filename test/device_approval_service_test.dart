import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/device_pairing_code.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DeviceManager.instance;
  final storage = E2EESecureStorage.instance;
  const path = 'users/account-a/devices/device-a';
  late OfflineFirebase backend;
  late DeviceKeyPair recipient;
  late DeviceKeyPair trusted;
  late DeviceVerificationRequest request;
  final master = Uint8List.fromList(List.filled(32, 43));
  Future<void> local(
    DeviceKeyPair pair,
    String id, {
    bool pending = false,
  }) async {
    manager.invalidateSession();
    FlutterSecureStorage.setMockInitialValues({
      'e2ee_device_id': id,
      'e2ee_device_private_key': pair.privateKeyBase64,
      'e2ee_device_public_key': pair.publicKeyBase64,
      if (pending) 'e2ee_approval_request': request.qrData,
      if (pending) 'e2ee_device_status': 'pending',
    });
  }

  setUp(() async {
    backend = OfflineFirebase()..configure();
    backend.firestore.queryResponse = (_, _) async => OfflineQuerySnapshot({});
    recipient = await KeyExchange.generateKeyPair();
    trusted = await KeyExchange.generateKeyPair();
    request = DeviceVerificationRequest.create(
      account: 'account-a',
      environment: jsonEncode(['demo-offline-test', 'offline-test', 'live']),
      deviceId: 'device-a',
      publicKey: recipient.publicKey,
    );
    backend.firestore.documents[path] = {
      'public_key': recipient.publicKeyBase64,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'approval_protocol': 2,
      'approval_request': request.toJson(),
    };
    await local(trusted, 'trusted');
    backend.firestore.documents['users/account-a/devices/trusted'] = {
      'public_key': trusted.publicKeyBase64,
      'status': 'approved',
    };
    manager.setCachedUMKForTesting(master);
  });
  test(
    'short-code mutual authentication reuses automatic QR key acceptance',
    () async {
      final host = PairingCodeHost(request);
      final public = DeviceVerificationRequest.fromJson(request.toJson());
      final client = PairingCodeClient(public, host.code, host.offer);
      final verified = await client.finish(
        (await host.answer(client.response))!,
      );
      expect(
        backend.firestore.documents[path]!.containsKey('wrapped_umk'),
        false,
      );
      final receipt = await manager.approveDevice(verified);
      expect(receipt.hasPairingProof, true);
      await local(recipient, 'device-a', pending: true);
      expect(await manager.tryRetrieveUMK(), true);
      expect(manager.getUMK(), master);
      expect(
        await manager.readServerAuthorization(),
        DeviceAuthorization.approved,
      );
      expect(await storage.getAcceptedApproval(), receipt.fingerprint);
    },
  );

  test(
    'legacy server-selected sender cannot replace a lost cached master key',
    () async {
      final shared = await KeyExchange.deriveSharedSecret(
        trusted.privateKey,
        recipient.publicKey,
      );
      final wrapped = await AuthenticatedCipher.encryptString(
        base64Encode(master),
        shared,
      );
      await local(recipient, 'device-a');
      backend.firestore.documents[path] = {
        'public_key': recipient.publicKeyBase64,
        'status': 'approved',
        'created_at': DateTime.now().toIso8601String(),
        'approved_by_public_key': trusted.publicKeyBase64,
        'wrapped_umk': wrapped.ciphertext,
        'wrapped_umk_nonce': wrapped.nonce,
      };
      expect(await manager.tryRetrieveUMK(), false);
      expect(await storage.getCachedUMK(), isNull);
      // Existing approved native devices do not depend on the untrusted unwrap.
      manager.setCachedUMKForTesting(master);
      expect(await manager.tryRetrieveUMK(), true);
      expect(manager.getUMK(), master);
    },
  );

  test(
    'device list accepts only current requests bound to that device key',
    () {
      final data = backend.firestore.documents[path]!;
      final device = DeviceDocument.fromFirestore(OfflineSnapshot(value: data));
      expect(device.canApproveAt(DateTime.now()), true);
      final roundTrip = DeviceDocument.fromFirestore(
        OfflineSnapshot(value: {...device.toFirestore(), 'id': 'device-a'}),
      );
      expect(roundTrip.approvalRequest!.toJson(), request.toJson());
      expect(
        roundTrip.toFirestore()['approval_request'],
        isNot(contains('pairingSecret')),
      );
      expect(
        device.canApproveAt(DateTime.now().add(const Duration(minutes: 11))),
        false,
      );
      final changed = DeviceDocument.fromFirestore(
        OfflineSnapshot(
          value: {...data, 'public_key': trusted.publicKeyBase64},
        ),
      );
      expect(changed.canApproveAt(DateTime.now()), false);
    },
  );

  test('pending banner filters invalid requests and expires without another snapshot', () async {
    const collection = 'users/account-a/devices';
    final events = StreamController<OfflineQuerySnapshot>.broadcast();
    backend.firestore.queryEvents[collection] = events;
    final data = backend.firestore.documents[path]!;
    await manager.startListeningForCurrentDevice();
    events.add(
      OfflineQuerySnapshot({
        'device-a': {
          ...data,
          'approval_request': {
            ...request.toJson(),
            'createdAt': DateTime.now()
                .subtract(const Duration(minutes: 9, seconds: 59))
                .millisecondsSinceEpoch,
          },
        },
        'wrong-key': data,
        'legacy': {...data}..remove('approval_request'),
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(manager.pendingApprovals.value.map((e) => e.deviceId), ['device-a']);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(manager.pendingApprovals.value, isEmpty);
    await manager.dispose();
    await events.close();
  });

  tearDown(() async {
    await manager.dispose();
    await backend.auth.changes.close();
    await backend.firestore.events.close();
  });
  test(
    'revoked approver cannot publish a verified master-key envelope',
    () async {
      backend
              .firestore
              .documents['users/account-a/devices/trusted']!['status'] =
          'revoked';
      await expectLater(
        manager.approveDevice(request.verifyQr(request.qrData)),
        throwsStateError,
      );
      expect(
        backend.firestore.documents[path]!.containsKey('wrapped_umk'),
        false,
      );
    },
  );
  test('code fallback never unlocks before recipient confirms the exact trusted-device receipt', () async {
    await manager.pendingVerificationRequest('device-a');
    expect(
      backend.firestore.documents[path]!.containsKey('wrapped_umk'),
      false,
    );
    final receipt = await manager.approveDevice(
      request.confirmCode(request.securityCode),
    );
    await local(recipient, 'device-a', pending: true);
    expect(
      await manager.readServerAuthorization(),
      DeviceAuthorization.pending,
    );
    expect(await storage.getCachedUMK(), null);
    expect(await manager.tryRetrieveUMK(), false);
    expect(manager.hasUMK.value, false);
    final incoming = await manager.pendingApprovalReceipt();
    expect(incoming!.fingerprint, receipt.fingerprint);
    await manager.acceptVerifiedApproval(incoming.verifyQr(receipt.qrData));
    expect(manager.getUMK(), master);
    expect(await storage.getAcceptedApproval(), receipt.fingerprint);
    expect(
      await manager.readServerAuthorization(),
      DeviceAuthorization.approved,
    );
  });

  Future<void> useCodeMode() async {
    request = DeviceVerificationRequest.create(
      account: request.account,
      environment: request.environment,
      deviceId: request.deviceId,
      publicKey: recipient.publicKey,
      codeApproval: true,
    );
    backend.firestore.documents[path]!['approval_request'] = request.toJson();
  }

  test(
    'legacy code-mode receipt cannot auto-accept a server-chosen key',
    () async {
      await useCodeMode();
      manager.setCachedUMKForTesting(Uint8List.fromList(List.filled(32, 99)));
      final receipt = await manager.approveDevice(
        request.confirmCode(request.securityCode),
      );
      expect(receipt.hasPairingProof, false);
      expect(receipt.requiresReturnVerification, true);
      await local(recipient, 'device-a', pending: true);
      expect(await manager.tryRetrieveUMK(), false);
      expect(await storage.getAcceptedApproval(), isNull);
      expect(await storage.getCachedUMK(), isNull);
      expect(manager.hasUMK.value, false);
    },
  );

  test('changing method regenerates locally before publication and invalidates prior approval', () async {
    final old = request;
    await local(recipient, 'device-a', pending: true);
    request = await manager.ensureVerificationRequest(codeApproval: true);
    expect(request.codeApproval, true);
    expect(request.requestId, isNot(old.requestId));
    expect(
      (await manager.localVerificationRequest())!.canonical,
      request.canonical,
    );
    expect(
      backend.firestore.documents[path]!['approval_request'],
      request.toJson(),
    );
    await local(trusted, 'trusted');
    manager.setCachedUMKForTesting(master);
    await expectLater(
      manager.approveDevice(old.confirmCode(old.securityCode)),
      throwsStateError,
    );
    await local(recipient, 'device-a', pending: true);
    final codeRequest = request;
    request = await manager.ensureVerificationRequest(codeApproval: false);
    expect(request.codeApproval, false);
    expect(request.requestId, isNot(codeRequest.requestId));
    expect(request.toJson().containsKey('approvalMode'), false);
  });

  test('comparison stream follows current requests and rejects stale or invalid data', () async {
    final seen = <DeviceVerificationRequest?>[];
    final errors = <Object>[];
    final subscription = manager
        .watchPendingVerificationRequest('device-a')
        .listen(seen.add, onError: (Object error) => errors.add(error));
    addTearDown(subscription.cancel);
    final initial = Map<String, dynamic>.from(
      backend.firestore.documents[path]!,
    );
    final next = DeviceVerificationRequest.create(
      account: request.account,
      environment: request.environment,
      deviceId: request.deviceId,
      publicKey: recipient.publicKey,
      codeApproval: true,
    );
    final changed = {...initial, 'approval_request': next.toJson()};
    backend.firestore.events.add(OfflineSnapshot(value: initial));
    backend.firestore.events.add(OfflineSnapshot(value: changed));
    backend.firestore.events.add(OfflineSnapshot(value: initial, cached: true));
    backend.firestore.events.add(
      OfflineSnapshot(value: initial, pending: true),
    );
    backend.firestore.events.add(
      OfflineSnapshot(value: {...changed, 'status': 'revoked'}),
    );
    backend.firestore.events.add(
      OfflineSnapshot(
        value: {...changed, 'public_key': trusted.publicKeyBase64},
      ),
    );
    backend.firestore.events.add(OfflineSnapshot());
    await Future<void>.delayed(Duration.zero);
    expect(seen.map((value) => value?.securityCode), [
      request.securityCode,
      next.securityCode,
      null,
      null,
    ]);
    expect(errors, hasLength(1));
    manager.invalidateSession();
    backend.firestore.events.add(OfflineSnapshot(value: changed));
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(4));
    expect(errors, hasLength(2));
  });

  test('server cannot inject code mode or remove proof to auto-accept a QR request', () async {
    final receipt = await manager.approveDevice(
      request.verifyQr(request.qrData),
    );
    await local(recipient, 'device-a', pending: true);
    final data = backend.firestore.documents[path]!;
    data.remove('pairing_proof');
    expect(await manager.tryRetrieveUMK(), false);
    data['approval_request'] = {...request.toJson(), 'approvalMode': 'code'};
    expect(await manager.tryRetrieveUMK(), false);
    expect(await storage.getAcceptedApproval(), isNull);
    expect(await storage.getCachedUMK(), isNull);
    // The original proof still completes the unchanged local request.
    data['approval_request'] = request.toJson();
    data['pairing_proof'] = receipt.pairingProof;
    expect(await manager.tryRetrieveUMK(), true);
  });

  test('one scan authenticates and restores the key automatically without publishing the secret', () async {
    final pending = await manager.pendingVerificationRequest('device-a');
    expect(pending.hasPairingSecret, false);
    final receipt = await manager.approveDevice(
      pending.verifyQr(request.qrData),
    );
    final secret = (jsonDecode(request.qrData) as Map)['secret'] as String;
    expect(receipt.hasPairingProof, true);
    expect(jsonEncode(backend.firestore.documents), isNot(contains(secret)));
    await local(recipient, 'device-a', pending: true);
    expect(
      await manager.readServerAuthorization(),
      DeviceAuthorization.approved,
    );
    expect(await storage.getAcceptedApproval(), receipt.fingerprint);
    expect(await storage.getApprovalRequest(), jsonEncode(request.toJson()));
    expect(await manager.tryRetrieveUMK(), true);
    expect(manager.getUMK(), master);
    // Restoring the already accepted handoff does not need the consumed secret.
    manager.invalidateSession();
    await manager.init();
    expect(manager.getUMK(), master);
  });

  test('a server-substituted sender and master key cannot reuse a scanned pairing proof', () async {
    await manager.approveDevice(request.verifyQr(request.qrData));
    final attacker = await KeyExchange.generateKeyPair();
    final forged = await AuthenticatedCipher.encryptString(
      request.encodeMasterKey(Uint8List(32)),
      await KeyExchange.deriveSharedSecret(
        attacker.privateKey,
        recipient.publicKey,
      ),
    );
    backend.firestore.documents[path]!.addAll({
      'approved_by_public_key': attacker.publicKeyBase64,
      'wrapped_umk': forged.ciphertext,
      'wrapped_umk_nonce': forged.nonce,
    });
    await local(recipient, 'device-a', pending: true);
    expect(
      await manager.readServerAuthorization(),
      DeviceAuthorization.pending,
    );
    expect(await manager.tryRetrieveUMK(), false);
    expect(manager.hasUMK.value, false);
    expect(await storage.getAcceptedApproval(), null);
    expect(await storage.getCachedUMK(), null);
  });

  test(
    'removing the proof cannot turn server approval into automatic trust',
    () async {
      await manager.approveDevice(request.verifyQr(request.qrData));
      backend.firestore.documents[path]!.remove('pairing_proof');
      await local(recipient, 'device-a', pending: true);
      expect(
        await manager.readServerAuthorization(),
        DeviceAuthorization.pending,
      );
      expect(await manager.tryRetrieveUMK(), false);
      expect(await storage.getAcceptedApproval(), null);
    },
  );

  test(
    'approval before mode change keeps the approved request and handoff',
    () async {
      await manager.approveDevice(request.verifyQr(request.qrData));
      final approved = Map<String, dynamic>.from(
        backend.firestore.documents[path]!,
      );
      await local(recipient, 'device-a', pending: true);
      await expectLater(
        manager.ensureVerificationRequest(codeApproval: true),
        throwsStateError,
      );
      expect(backend.firestore.documents[path], approved);
      expect(
        (await manager.localVerificationRequest())!.canonical,
        request.canonical,
      );
      expect(await manager.tryRetrieveUMK(), true);
      expect(manager.getUMK(), master);
    },
  );

  test('concurrent approval restores the previous local request when mode publication loses', () async {
    await local(recipient, 'device-a', pending: true);
    backend.firestore.commit = () async {
      backend.firestore.commit = null;
      backend.firestore.documents[path] = {
        ...backend.firestore.documents[path]!,
        'status': 'approved',
      };
    };
    await expectLater(
      manager.ensureVerificationRequest(codeApproval: true),
      throwsStateError,
    );
    expect(backend.firestore.documents[path]!['status'], 'approved');
    expect((await manager.localVerificationRequest())!.qrData, request.qrData);
  });

  test('uncertain publication restores only a locally held matching request and fingerprint', () async {
    await local(recipient, 'device-a', pending: true);
    await storage.storeAcceptedApproval('previous-fingerprint');
    final candidate = DeviceVerificationRequest.create(
      account: request.account,
      environment: request.environment,
      deviceId: request.deviceId,
      publicKey: recipient.publicKey,
    );
    await storage.beginApprovalPublication(candidate.qrData);
    expect(await storage.getAcceptedApproval(), isNull);
    await manager.ensureVerificationRequest();
    expect(await storage.getApprovalRequest(), request.qrData);
    expect(await storage.getAcceptedApproval(), 'previous-fingerprint');

    await storage.beginApprovalPublication(candidate.qrData);
    backend.firestore.documents[path]!['approval_request'] = candidate.toJson();
    expect(
      (await manager.ensureVerificationRequest()).qrData,
      candidate.qrData,
    );
    expect(await storage.getAcceptedApproval(), isNull);
  });

  test(
    'publication reconciliation never adopts an unknown remote request',
    () async {
      await local(recipient, 'device-a', pending: true);
      final candidate = DeviceVerificationRequest.create(
        account: request.account,
        environment: request.environment,
        deviceId: request.deviceId,
        publicKey: recipient.publicKey,
      );
      await storage.beginApprovalPublication(candidate.qrData);
      final substituted = DeviceVerificationRequest.create(
        account: request.account,
        environment: request.environment,
        deviceId: request.deviceId,
        publicKey: recipient.publicKey,
      );
      backend.firestore.documents[path]!['approval_request'] = substituted
          .toJson();
      await expectLater(manager.ensureVerificationRequest(), throwsStateError);
      expect(await storage.getApprovalRequest(), candidate.qrData);
      expect(await storage.getAcceptedApproval(), isNull);
      final fresh = await manager.ensureVerificationRequest(regenerate: true);
      expect(fresh.canonical, isNot(candidate.canonical));
      expect(fresh.canonical, isNot(substituted.canonical));
      expect(
        backend.firestore.documents[path]!['approval_request'],
        fresh.toJson(),
      );
    },
  );

  test('session invalidation during journal write cannot replace the local request', () async {
    await local(recipient, 'device-a', pending: true);
    final delayed = _DelayedKeyWrite({
      'e2ee_approval_request': request.qrData,
      'e2ee_accepted_approval': 'accepted',
    }, keyToDelay: 'e2ee_approval_publication');
    FlutterSecureStoragePlatform.instance = delayed;
    var current = true;
    final writing = runCloudOperation(
      () => current,
      () => storage.beginApprovalPublication(request.qrData),
    );
    final rejected = expectLater(
      writing,
      throwsA(isA<CloudOperationCancelled>()),
    );
    await delayed.started.future;
    current = false;
    delayed.release.complete();
    await rejected;
    expect(await storage.getApprovalRequest(), request.qrData);
    expect(await storage.getAcceptedApproval(), 'accepted');
    await storage.clearApprovalRequest();
    await storage.reconcileApprovalPublication(request);
    expect(await storage.getApprovalRequest(), null);
    expect(await storage.getAcceptedApproval(), null);
  });

  test('a lost commit reply retains the committed local secret', () async {
    await local(recipient, 'device-a', pending: true);
    backend.firestore.commit = () async {
      backend.firestore.commit = null;
      final committed = DeviceVerificationRequest.fromLocalData(
        (await storage.getApprovalRequest())!,
      );
      backend.firestore.documents[path]!['approval_request'] = committed
          .toJson();
      throw StateError('Synthetic lost commit acknowledgement');
    };
    await expectLater(
      manager.ensureVerificationRequest(regenerate: true),
      throwsStateError,
    );
    final restored = await manager.ensureVerificationRequest();
    expect(restored.canonical, isNot(request.canonical));
    expect(restored.hasPairingSecret, true);
    expect(
      backend.firestore.documents[path]!['approval_request'],
      restored.toJson(),
    );
  });

  test(
    'an uncommitted first publication can restore an absent request',
    () async {
      await storage.clearApprovalRequest();
      await storage.beginApprovalPublication(request.qrData);
      await storage.reconcileApprovalPublication(null);
      expect(await storage.getApprovalRequest(), null);
      await storage.beginApprovalPublication(request.qrData);
      await storage.reconcileApprovalPublication(request);
      expect(await storage.getApprovalRequest(), request.qrData);
    },
  );

  test('regeneration replaces the local QR secret and publishes only the public request', () async {
    await local(recipient, 'device-a', pending: true);
    final fresh = await manager.ensureVerificationRequest(regenerate: true);
    final oldSecret = (jsonDecode(request.qrData) as Map)['secret'];
    final newSecret = (jsonDecode(fresh.qrData) as Map)['secret'];
    expect(newSecret, isNot(oldSecret));
    expect(await storage.getApprovalRequest(), fresh.qrData);
    expect(
      backend.firestore.documents[path]!['approval_request'],
      fresh.toJson(),
    );
    expect(jsonEncode(backend.firestore.documents), isNot(contains(newSecret)));
    expect(jsonEncode(backend.firestore.documents), isNot(contains(oldSecret)));
    await manager.cancelApprovalRequest();
    expect(await storage.getApprovalRequest(), null);
    expect(await storage.getAcceptedApproval(), null);
  });
  test('substituted handoff after recipient confirmation is rejected before caching', () async {
    final receipt = await manager.approveDevice(
      request.confirmCode(request.securityCode),
    );
    await local(recipient, 'device-a', pending: true);
    final proof = receipt.confirmCode(receipt.securityCode);
    final attacker = await KeyExchange.generateKeyPair();
    final fake = await AuthenticatedCipher.encryptString(
      request.encodeMasterKey(Uint8List(32)),
      await KeyExchange.deriveSharedSecret(
        attacker.privateKey,
        recipient.publicKey,
      ),
    );
    backend.firestore.documents[path]!.addAll({
      'approved_by_public_key': attacker.publicKeyBase64,
      'wrapped_umk': fake.ciphertext,
      'wrapped_umk_nonce': fake.nonce,
    });
    await expectLater(manager.acceptVerifiedApproval(proof), throwsStateError);
    expect(await storage.getAcceptedApproval(), null);
    expect(await storage.getCachedUMK(), null);
  });
  test('key change between local verification and publication prevents a master-key envelope', () async {
    final proof = request.verifyQr(request.qrData);
    backend.firestore.commit = () async {
      backend.firestore.documents[path]!['public_key'] = base64Encode(
        Uint8List(32),
      );
    };
    await expectLater(manager.approveDevice(proof), throwsStateError);
    expect(
      backend.firestore.documents[path]!.containsKey('wrapped_umk'),
      false,
    );
  });
  test('regeneration and cancellation invalidate earlier locally verified requests', () async {
    final proof = request.verifyQr(request.qrData);
    await local(recipient, 'device-a', pending: true);
    final renewed = await manager.ensureVerificationRequest(regenerate: true);
    expect(renewed.requestId, isNot(request.requestId));
    await local(trusted, 'trusted');
    manager.setCachedUMKForTesting(master);
    await expectLater(manager.approveDevice(proof), throwsStateError);
    request = renewed;
    await local(recipient, 'device-a', pending: true);
    await manager.cancelApprovalRequest();
    expect(backend.firestore.documents.containsKey(path), false);
    expect(await storage.getApprovalRequest(), null);
  });
  test('observed reset invalidates an accepted receipt before an old approval can be replayed', () async {
    final receipt = await manager.approveDevice(
      request.verifyQr(request.qrData),
    );
    final approved = Map<String, dynamic>.from(
      backend.firestore.documents[path]!,
    );
    await local(recipient, 'device-a', pending: true);
    await manager.acceptVerifiedApproval(receipt.verifyQr(receipt.qrData));
    backend.firestore.documents[path]!['status'] = 'pending';
    expect(
      await manager.readServerAuthorization(),
      DeviceAuthorization.pending,
    );
    expect(await storage.getAcceptedApproval(), null);
    expect(await storage.getCachedUMK(), null);
    backend.firestore.documents[path] = approved;
    expect(await manager.tryRetrieveUMK(), false);
    expect(manager.hasUMK.value, false);
  });
  for (final cancel in [false, true]) {
    test(
      '${cancel ? 'cancellation' : 'regeneration'} fences automatic proof acceptance during its native write',
      () async {
        await manager.approveDevice(request.verifyQr(request.qrData));
        await local(recipient, 'device-a', pending: true);
        final delayed = _DelayedKeyWrite({
          'e2ee_device_id': 'device-a',
          'e2ee_device_private_key': recipient.privateKeyBase64,
          'e2ee_device_public_key': recipient.publicKeyBase64,
          'e2ee_approval_request': request.qrData,
          'e2ee_device_status': 'pending',
        }, keyToDelay: 'e2ee_accepted_approval');
        FlutterSecureStoragePlatform.instance = delayed;
        final checking = manager.readServerAuthorization();
        await delayed.started.future;
        final invalidating = cancel
            ? manager.cancelApprovalRequest()
            : manager.ensureVerificationRequest(regenerate: true);
        final invalidated = cancel
            ? invalidating
            : expectLater(invalidating, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        delayed.release.complete();
        expect(await checking, isNot(DeviceAuthorization.approved));
        await invalidated;
        if (cancel) expect(await storage.getAcceptedApproval(), null);
        expect(await storage.getCachedUMK(), null);
        final current = await manager.localVerificationRequest();
        expect(current?.requestId, cancel ? null : request.requestId);
        expect(manager.hasUMK.value, false);
      },
    );
  }
  for (final method in ['manual', 'QR']) {
    for (final cancel in [false, true]) {
      test(
        '$method ${cancel ? 'cancellation' : 'regeneration'} fences an accepted handoff whose key-cache write is still in flight',
        () async {
          if (method == 'code') await useCodeMode();
          final receipt = await manager.approveDevice(
            method == 'code'
                ? request.confirmCode(request.securityCode)
                : request.verifyQr(request.qrData),
          );
          await local(recipient, 'device-a', pending: true);
          final delayed = _DelayedKeyWrite({
            'e2ee_device_id': 'device-a',
            'e2ee_device_private_key': recipient.privateKeyBase64,
            'e2ee_device_public_key': recipient.publicKeyBase64,
            'e2ee_approval_request': request.qrData,
            'e2ee_device_status': 'pending',
          });
          FlutterSecureStoragePlatform.instance = delayed;
          final accepting = method != 'manual'
              ? manager.init()
              : manager.acceptVerifiedApproval(
                  receipt.verifyQr(receipt.qrData),
                );
          final rejected = expectLater(
            accepting,
            throwsA(isA<CloudOperationCancelled>()),
          );
          await delayed.started.future;
          final invalidating = cancel
              ? manager.cancelApprovalRequest()
              : manager.ensureVerificationRequest(regenerate: true);
          final invalidated = cancel
              ? invalidating
              : expectLater(invalidating, throwsStateError);
          // Drain ready microtasks: regeneration reaches the serialized key store
          // while the old native write is deliberately held by this fixture.
          await Future<void>.delayed(Duration.zero);
          delayed.release.complete();
          await rejected;
          await invalidated;
          final fresh = await manager.localVerificationRequest();
          if (cancel) {
            expect(fresh, null);
            expect(await storage.hasDeviceKeys(), false);
          } else {
            expect(fresh!.requestId, request.requestId);
          }
          expect(manager.hasUMK.value, false);
          if (cancel) {
            expect(await storage.getCachedUMK(), null);
            expect(await storage.getAcceptedApproval(), null);
          } else {
            expect(await manager.tryRetrieveUMK(), true);
            expect(manager.getUMK(), master);
          }
          if (cancel) {
            expect(backend.firestore.documents.containsKey(path), false);
          } else {
            expect(backend.firestore.documents[path]!['status'], 'approved');
          }
        },
      );
    }
  }
}

class _DelayedKeyWrite extends TestFlutterSecureStoragePlatform {
  _DelayedKeyWrite(super.data, {this.keyToDelay = 'e2ee_umk_cache'});
  final String keyToDelay;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key == keyToDelay && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.write(key: key, value: value, options: options);
  }
}
