import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/e2ee/device_pairing_code.dart';
import 'package:better_keep/services/e2ee/device_pairing_channel.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceVerificationRequest request() => DeviceVerificationRequest.create(
  account: 'qa-account',
  environment: 'qa-environment',
  deviceId: 'qa-device',
  publicKey: Uint8List.fromList(List.filled(32, 3)),
);
DeviceVerificationRequest public(DeviceVerificationRequest local) =>
    DeviceVerificationRequest.fromJson(local.toJson());

void main() {
  test(
    'eight-digit exchange authenticates the existing automatic key receipt',
    () async {
      final local = request();
      final host = PairingCodeHost(local);
      expect(host.code, matches(RegExp(r'^\d{8}$')));
      final client = PairingCodeClient(public(local), host.code, host.offer);
      final result = (await host.answer(client.response))!;
      final verified = await client.finish(result);
      final receipt = verified.authenticateReceipt(
        DeviceApprovalReceipt(
          request: public(local),
          approverPublicKey: base64Encode(Uint8List(32)),
          ciphertext: base64Encode(Uint8List(100)),
          nonce: base64Encode(Uint8List(24)),
        ),
      );
      expect(
        local.verifyAutomaticReceipt(receipt),
        isA<VerifiedDeviceReceipt>(),
      );
      final network = jsonEncode([
        host.offer,
        client.response,
        result,
        receipt.pairingProof,
      ]);
      expect(network, isNot(contains(host.code)));
      expect(
        network,
        isNot(contains((jsonDecode(local.qrData) as Map)['secret'])),
      );
      expect(await host.answer(client.response), isNull);
      await expectLater(client.finish(result), throwsStateError);
    },
  );

  test(
    'three wrong attempts lock locally; replay cannot reset the budget',
    () async {
      final local = request();
      final host = PairingCodeHost(local);
      final wrong = host.code == '00000000' ? '00000001' : '00000000';
      final oldOffers = <String>[];
      for (var i = 0; i < 3; i++) {
        final offer = host.offer;
        expect(oldOffers, isNot(contains(offer['id'])));
        oldOffers.add(offer['id'] as String);
        final client = PairingCodeClient(public(local), wrong, offer);
        expect(await host.answer(client.response), isNull);
        expect(await host.answer(client.response), isNull);
      }
      expect(host.isValid, false);
      final correct = PairingCodeClient(public(local), host.code, host.offer);
      expect(await host.answer(correct.response), isNull);
    },
  );

  for (final field in [
    'account',
    'environment',
    'deviceId',
    'publicKey',
    'requestId',
  ]) {
    test('substituted $field cannot learn the pairing secret', () async {
      final local = request();
      final host = PairingCodeHost(local);
      final fields = local.toJson();
      fields[field] = field == 'publicKey' || field == 'requestId'
          ? base64UrlEncode(Uint8List(32))
          : 'other';
      final changed = DeviceVerificationRequest.fromJson(fields);
      final client = PairingCodeClient(changed, host.code, host.offer);
      expect(await host.answer(client.response), isNull);
    });
  }

  for (final field in ['M2', 'nonce', 'ciphertext', 'id']) {
    test('altered $field in returned handoff is rejected', () async {
      final local = request();
      final host = PairingCodeHost(local);
      final client = PairingCodeClient(public(local), host.code, host.offer);
      final result = (await host.answer(client.response))!;
      result[field] = field == 'M2'
          ? '0' * 64
          : base64Encode(Uint8List(field == 'nonce' ? 24 : 32));
      await expectLater(client.finish(result), throwsFormatException);
    });
  }

  test('expiry and cancellation fail closed', () async {
    final local = request();
    var now = DateTime.now();
    final host = PairingCodeHost(local, clock: () => now);
    final client = PairingCodeClient(public(local), host.code, host.offer);
    now = now.add(PairingCodeHost.lifetime);
    expect(await host.answer(client.response), isNull);
    final closed = PairingCodeHost(local)..close();
    expect(closed.isValid, false);
  });

  test(
    'malformed and oversized input consumes one attempt, not another response',
    () async {
      final host = PairingCodeHost(request());
      final initial = host.offer;
      expect(
        await host.answer({
          'id': initial['id'],
          'A': 'f' * 10000,
          'M1': '0' * 64,
        }),
        isNull,
      );
      expect(host.offer['id'], isNot(initial['id']));
      expect(
        () => PairingCodeClient(public(host.request), host.code, {
          ...host.offer,
          'B': '0' * 768,
        }),
        throwsFormatException,
      );
      expect(
        () => PairingCodeClient(public(host.request), host.code, {
          ...host.offer,
          'version': 2,
        }),
        throwsFormatException,
      );
    },
  );

  test('concurrent responses never reuse the same ephemeral', () async {
    final host = PairingCodeHost(request());
    final client = PairingCodeClient(
      public(host.request),
      host.code,
      host.offer,
    );
    final results = await Future.wait([
      host.answer(client.response),
      host.answer(client.response),
    ]);
    expect(results.whereType<Map<String, dynamic>>().length, 1);
  });

  test('mailbox exchange completes without reciprocal user action', () async {
    final local = request();
    final mailbox = MemoryPairingMailbox();
    final host = await PendingPairingCode.start(
      local,
      mailbox,
      isCurrent: () => true,
    );
    final verified = await verifyPairingCode(
      public(local),
      host.code,
      mailbox,
      isCurrent: () => true,
    );
    expect(verified.request.canonical, local.canonical);
    expect(host.state, PairingCodeState.shared);
    host.dispose();
    await mailbox.close();
  });

  test(
    'abandoned successful exchange stops waiting and exposes retry',
    () async {
      final local = request();
      final mailbox = MemoryPairingMailbox();
      final host = await PendingPairingCode.start(
        local,
        mailbox,
        isCurrent: () => true,
        handoffTimeout: const Duration(milliseconds: 20),
      );
      final completed = Completer<void>();
      host.addListener(() {
        if (host.state == PairingCodeState.unavailable &&
            !completed.isCompleted) {
          completed.complete();
        }
      });
      await verifyPairingCode(
        public(local),
        host.code,
        mailbox,
        isCurrent: () => true,
      );
      expect(host.handoffInProgress, true);
      await completed.future.timeout(const Duration(seconds: 2));
      expect(host.handoffInProgress, false);
      host.dispose();
      await mailbox.close();
    },
  );

  test('wrong-code retry uses a fresh offer; correct retry works', () async {
    final local = request();
    final mailbox = MemoryPairingMailbox();
    final host = await PendingPairingCode.start(
      local,
      mailbox,
      isCurrent: () => true,
    );
    final wrong = host.code == '00000000' ? '00000001' : '00000000';
    await expectLater(
      verifyPairingCode(public(local), wrong, mailbox, isCurrent: () => true),
      throwsStateError,
    );
    final verified = await verifyPairingCode(
      public(local),
      host.code,
      mailbox,
      isCurrent: () => true,
    );
    expect(verified, isA<VerifiedDeviceApproval>());
    host.dispose();
    await mailbox.close();
  });

  test(
    'a retry arriving before offer acknowledgement is not dropped',
    () async {
      final local = request();
      final mailbox = MemoryPairingMailbox();
      final host = await PendingPairingCode.start(
        local,
        mailbox,
        isCurrent: () => true,
      );
      final initialId = (mailbox.value!['offer'] as Map)['id'];
      final acknowledgement = Completer<void>();
      mailbox.afterChange = (value) async {
        if (value?['offer'] is Map &&
            (value!['offer'] as Map)['id'] != initialId &&
            !value.containsKey('response')) {
          await acknowledgement.future;
        }
      };
      final wrong = host.code == '00000000' ? '00000001' : '00000000';
      await expectLater(
        verifyPairingCode(public(local), wrong, mailbox, isCurrent: () => true),
        throwsStateError,
      );
      final retry = verifyPairingCode(
        public(local),
        host.code,
        mailbox,
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      acknowledgement.complete();
      expect(await retry, isA<VerifiedDeviceApproval>());
      host.dispose();
      await mailbox.close();
    },
  );

  test('cancelled trusted-device UI never returns a verified proof', () async {
    final local = request();
    final mailbox = MemoryPairingMailbox();
    final host = await PendingPairingCode.start(
      local,
      mailbox,
      isCurrent: () => true,
    );
    var current = true;
    final exchange = verifyPairingCode(
      public(local),
      host.code,
      mailbox,
      isCurrent: () => current,
    );
    current = false;
    await expectLater(exchange, throwsStateError);
    host.dispose();
    await mailbox.close();
  });
}

class MemoryPairingMailbox implements PairingCodeMailbox {
  Map<String, dynamic>? value;
  Future<void> Function(Map<String, dynamic>?)? afterChange;
  final events = StreamController<Map<String, dynamic>?>.broadcast(sync: true);
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Stream<Map<String, dynamic>?> watch() => Stream.multi((controller) {
    final sub = events.stream.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.add(value);
    controller.onCancel = sub.cancel;
  });
  @override
  Future<void> change(
    Map<String, dynamic>? Function(Map<String, dynamic>?) update,
  ) async {
    value = update(value);
    events.add(value);
    await afterChange?.call(value);
  }

  Future<void> close() => events.close();
}
