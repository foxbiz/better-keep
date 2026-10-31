import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 24);
  late DeviceVerificationRequest request;
  setUp(() {
    request = DeviceVerificationRequest.create(
      account: 'user-a',
      environment: 'live',
      deviceId: 'phone',
      publicKey: Uint8List.fromList(List.filled(32, 7)),
      now: now,
    );
  });

  test('QR and full code confirm the same canonical identity', () {
    final reordered = Map<String, dynamic>.fromEntries(
      request.toJson().entries.toList().reversed,
    );
    expect(
      request.verifyQr(jsonEncode(reordered), now: now).request.canonical,
      request.canonical,
    );
    expect(
      request.confirmCode(request.securityCode.toLowerCase(), now: now).request,
      request,
    );
    expect(request.securityCode.replaceAll(' ', '').length, 32);
    expect(
      () => request.confirmCode('123456', now: now),
      throwsFormatException,
    );
  });

  DeviceApprovalReceipt handoff({
    DeviceVerificationRequest? identity,
    String? ciphertext,
    String? nonce,
    String? sender,
    String? tag,
  }) => DeviceApprovalReceipt(
    request: identity ?? request,
    approverPublicKey: sender ?? base64Encode(List.filled(32, 5)),
    ciphertext: ciphertext ?? base64Encode(List.filled(100, 7)),
    nonce: nonce ?? base64Encode(List.filled(24, 3)),
    pairingTag: tag,
  );

  test('pairing secret stays in local QR data and never enters public serialization', () {
    final qr = jsonDecode(request.qrData) as Map<String, dynamic>;
    final secret = qr['secret'] as String;
    expect(base64Url.decode(secret).length, 32);
    final restored = DeviceVerificationRequest.fromLocalData(request.qrData);
    expect(restored.qrData, request.qrData);
    expect(restored.canonical, request.canonical);
    expect(jsonEncode(request.toJson()), isNot(contains(secret)));
    expect(request.encodeMasterKey(Uint8List(32)), isNot(contains(secret)));
    expect(request.canonical, isNot(contains(secret)));
    expect(() => DeviceVerificationRequest.fromJson(qr), throwsFormatException);
    final server = DeviceVerificationRequest.fromJson(request.toJson());
    expect(server.hasPairingSecret, false);
    expect(server.securityCode, request.securityCode);
    expect(server.qrData, isNot(contains(secret)));
  });

  test(
    'only an independently scanned secret authenticates the complete handoff',
    () {
      final public = DeviceVerificationRequest.fromJson(request.toJson());
      final authenticated = public
          .verifyQr(request.qrData, now: now)
          .authenticateReceipt(handoff());
      expect(
        request
            .verifyPairingReceipt(authenticated, now: now)!
            .receipt
            .fingerprint,
        authenticated.fingerprint,
      );
      expect(
        () => public.verifyPairingReceipt(authenticated, now: now),
        throwsStateError,
      );
      final tag = authenticated.pairingProof!['tag'] as String;
      final document = <String, dynamic>{
        'status': 'approved',
        'approval_protocol': DeviceVerificationRequest.version,
        'wrapped_umk_version': DeviceVerificationRequest.version,
        'public_key': request.publicKey,
        'approval_request': request.toJson(),
        'approved_by_public_key': authenticated.approverPublicKey,
        'wrapped_umk': authenticated.ciphertext,
        'wrapped_umk_nonce': authenticated.nonce,
        'pairing_proof': authenticated.pairingProof,
      };
      expect(
        request.verifyPairingReceipt(
          DeviceApprovalReceipt.fromDocument(public, document),
          now: now,
        ),
        isNotNull,
      );
      for (final invalid in [
        {'version': 2, 'tag': tag},
        {'version': 1, 'tag': 'invalid'},
        {'version': 1, 'tag': tag, 'extra': true},
      ]) {
        expect(
          () => DeviceApprovalReceipt.fromDocument(public, {
            ...document,
            'pairing_proof': invalid,
          }),
          throwsFormatException,
        );
      }
      final altered = [
        handoff(ciphertext: base64Encode(List.filled(100, 8)), tag: tag),
        handoff(nonce: base64Encode(List.filled(24, 4)), tag: tag),
        handoff(sender: base64Encode(List.filled(32, 6)), tag: tag),
        handoff(tag: base64UrlEncode(List.filled(32, 0))),
        handoff(
          identity: DeviceVerificationRequest.fromJson({
            ...request.toJson(),
            'account': 'other-user',
          }),
          tag: tag,
        ),
        handoff(
          identity: DeviceVerificationRequest.fromJson({
            ...request.toJson(),
            'environment': 'other-environment',
          }),
          tag: tag,
        ),
        handoff(
          identity: DeviceVerificationRequest.fromJson({
            ...request.toJson(),
            'deviceId': 'other-device',
          }),
          tag: tag,
        ),
      ];
      for (final changed in altered) {
        expect(
          () => request.verifyPairingReceipt(changed, now: now),
          throwsStateError,
        );
      }
      expect(
        () => request.verifyPairingReceipt(
          authenticated,
          now: now.add(const Duration(minutes: 10)),
        ),
        throwsStateError,
      );
      final wrongSecret = jsonEncode({
        ...jsonDecode(request.qrData) as Map,
        'secret': base64UrlEncode(List.filled(32, 9)),
      });
      final wrongProof = public
          .verifyQr(wrongSecret, now: now)
          .authenticateReceipt(handoff());
      expect(
        () => request.verifyPairingReceipt(wrongProof, now: now),
        throwsStateError,
      );
      // Code fallback and legacy public-only QRs still require return verification.
      for (final proof in [
        public.confirmCode(request.securityCode, now: now),
        public.verifyQr(public.qrData, now: now),
      ]) {
        final manual = proof.authenticateReceipt(handoff());
        expect(manual.hasPairingProof, false);
        expect(request.verifyPairingReceipt(manual, now: now), null);
      }
    },
  );

  test(
    'malformed private QR envelopes reject without exposing their contents',
    () {
      final qr = jsonDecode(request.qrData) as Map<String, dynamic>;
      for (final malformed in [
        {...qr, 'version': 2},
        {...qr, 'type': 'other-type'},
        {...qr, 'secret': 'sensitive-invalid-secret'},
        {...qr, 'extra': 'not-supported'},
      ]) {
        try {
          DeviceVerificationRequest.fromLocalData(jsonEncode(malformed));
          fail('Malformed pairing data was accepted');
        } on FormatException catch (error) {
          expect(error.source, null);
          expect(error.toString(), isNot(contains(qr['secret'] as String)));
          expect(error.toString(), isNot(contains('sensitive-invalid-secret')));
        }
      }
    },
  );

  test('rejects substitution of any bound identity field', () {
    final changes = <String, dynamic>{
      'account': 'other-user',
      'environment': 'emulator',
      'deviceId': 'other-phone',
      'publicKey': base64Encode(List.filled(32, 8)),
      'requestId': base64UrlEncode(List.filled(32, 9)),
      'createdAt': now.millisecondsSinceEpoch + 1,
      'version': 1,
    };
    for (final entry in changes.entries) {
      final altered = {...request.toJson(), entry.key: entry.value};
      expect(
        () => request.verifyQr(jsonEncode(altered), now: now),
        throwsFormatException,
        reason: entry.key,
      );
    }
    expect(() => request.verifyQr('not-json', now: now), throwsFormatException);
    expect(() => request.verifyQr('x' * 4097, now: now), throwsFormatException);
  });

  test('expired, future and regenerated requests cannot be approved', () {
    expect(request.isValidAt(now.subtract(const Duration(seconds: 59))), true);
    expect(
      () => request.verifyQr(
        request.qrData,
        now: now.add(const Duration(minutes: 10)),
      ),
      throwsStateError,
    );
    expect(
      () => request.confirmCode(
        request.securityCode,
        now: now.subtract(const Duration(seconds: 61)),
      ),
      throwsStateError,
    );
    final renewed = DeviceVerificationRequest.create(
      account: request.account,
      environment: request.environment,
      deviceId: request.deviceId,
      publicKey: base64Decode(request.publicKey),
      now: now,
    );
    expect(
      () => renewed.verifyQr(request.qrData, now: now),
      throwsFormatException,
    );
  });

  test('recipient rejects replay, downgrade and an expired first approval', () {
    final master = Uint8List.fromList(List.filled(32, 42));
    final payload = request.encodeMasterKey(master);
    expect(
      request.decodeMasterKey(payload, envelopeVersion: 2, now: now),
      master,
    );
    expect(
      () => request.decodeMasterKey(
        base64Encode(master),
        envelopeVersion: 1,
        now: now,
      ),
      throwsStateError,
    );
    final other = DeviceVerificationRequest.create(
      account: request.account,
      environment: request.environment,
      deviceId: request.deviceId,
      publicKey: base64Decode(request.publicKey),
      now: now,
    );
    expect(
      () => other.decodeMasterKey(payload, envelopeVersion: 2, now: now),
      throwsStateError,
    );
    final later = now.add(const Duration(days: 1));
    expect(
      () => request.decodeMasterKey(payload, envelopeVersion: 2, now: later),
      throwsStateError,
    );
    expect(
      request.decodeMasterKey(
        payload,
        envelopeVersion: 2,
        previouslyAcceptedRequestId: request.requestId,
        now: later,
      ),
      master,
    );
  });

  test('only the verified recipient can unwrap the bound master key', () async {
    final approver = await KeyExchange.generateKeyPair();
    final recipient = await KeyExchange.generateKeyPair();
    final attacker = await KeyExchange.generateKeyPair();
    final local = DeviceVerificationRequest.create(
      account: 'user',
      environment: 'live',
      deviceId: 'phone',
      publicKey: recipient.publicKey,
      now: now,
    );
    final proof = local.verifyQr(local.qrData, now: now);
    final outgoingKey = await KeyExchange.deriveSharedSecret(
      approver.privateKey,
      base64Decode(proof.request.publicKey),
    );
    final master = Uint8List.fromList(List.filled(32, 41));
    final wrapped = await AuthenticatedCipher.encryptString(
      proof.request.encodeMasterKey(master),
      outgoingKey,
    );
    final incomingKey = await KeyExchange.deriveSharedSecret(
      recipient.privateKey,
      approver.publicKey,
    );
    final plaintext = await AuthenticatedCipher.decryptString(
      wrapped.ciphertext,
      wrapped.nonce,
      incomingKey,
    );
    expect(
      local.decodeMasterKey(plaintext, envelopeVersion: 2, now: now),
      master,
    );
    final attackerKey = await KeyExchange.deriveSharedSecret(
      attacker.privateKey,
      approver.publicKey,
    );
    await expectLater(
      AuthenticatedCipher.decryptString(
        wrapped.ciphertext,
        wrapped.nonce,
        attackerKey,
      ),
      throwsA(anything),
    );
  });
  test('return confirmation authenticates exact handoff and rejects substituted master key', () async {
    final recipient = await KeyExchange.generateKeyPair();
    final trusted = await KeyExchange.generateKeyPair();
    final attacker = await KeyExchange.generateKeyPair();
    final local = DeviceVerificationRequest.create(
      account: 'user',
      environment: 'live',
      deviceId: 'new-device',
      publicKey: recipient.publicKey,
      now: now,
    );
    Future<DeviceApprovalReceipt> handoff(
      DeviceKeyPair sender,
      int masterByte,
    ) async {
      final key = await KeyExchange.deriveSharedSecret(
        sender.privateKey,
        recipient.publicKey,
      );
      final wrapped = await AuthenticatedCipher.encryptString(
        local.encodeMasterKey(Uint8List.fromList(List.filled(32, masterByte))),
        key,
      );
      return DeviceApprovalReceipt(
        request: local,
        approverPublicKey: sender.publicKeyBase64,
        ciphertext: wrapped.ciphertext,
        nonce: wrapped.nonce,
      );
    }

    final genuine = await handoff(trusted, 42);
    final substituted = await handoff(attacker, 7);
    expect(() => genuine.requireAccepted(null), throwsStateError);
    expect(
      () => substituted.verifyQr(genuine.qrData, now: now),
      throwsFormatException,
    );
    expect(
      () => substituted.confirmCode(genuine.securityCode, now: now),
      throwsFormatException,
    );
    final proof = genuine.verifyQr(genuine.qrData, now: now);
    genuine.requireAccepted(proof.receipt.fingerprint);
    expect(
      () => substituted.requireAccepted(proof.receipt.fingerprint),
      throwsStateError,
    );
    // Even the same sender and master key produce a different encrypted
    // handoff; confirmation cannot authorize a later replacement or replay.
    final replacement = await handoff(trusted, 42);
    expect(
      () => replacement.requireAccepted(genuine.fingerprint),
      throwsStateError,
    );
    expect(
      () => genuine.verifyQr(local.qrData, now: now),
      throwsFormatException,
    );
    expect(
      () => genuine.confirmCode(
        genuine.securityCode,
        now: now.add(const Duration(minutes: 10)),
      ),
      throwsStateError,
    );
    expect(genuine.qrData, isNot(contains(genuine.ciphertext)));
    expect(genuine.securityCode.replaceAll(' ', ''), hasLength(32));
    final data = {
      'status': 'approved',
      'wrapped_umk_version': 2,
      'approval_protocol': 2,
      'public_key': local.publicKey,
      'approval_request': local.toJson(),
      'approved_by_public_key': genuine.approverPublicKey,
      'wrapped_umk': genuine.ciphertext,
      'wrapped_umk_nonce': genuine.nonce,
    };
    expect(
      DeviceApprovalReceipt.fromDocument(local, data).fingerprint,
      genuine.fingerprint,
    );
    for (final entry in {
      'status': 'pending',
      'wrapped_umk_version': 1,
      'approval_protocol': 1,
      'public_key': attacker.publicKeyBase64,
    }.entries) {
      expect(
        () => DeviceApprovalReceipt.fromDocument(local, {
          ...data,
          entry.key: entry.value,
        }),
        throwsStateError,
      );
    }
  });
}
