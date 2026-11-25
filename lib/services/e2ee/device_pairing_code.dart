import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/srp/srp6_client.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

import 'crypto_primitives.dart';
import 'device_verification.dart';

/// Client-only SRP-6a (RFC 5054 3072-bit group, SHA-256). Firebase only relays
/// public SRP values/evidence and ciphertext. The code, verifier, private values
/// and session key must never be persisted or logged. Both roles run on devices.
///
/// A successful exchange transfers the existing one-time QR secret. Master-key
/// acceptance still requires the existing pairing MAC, never a server flag.
class PairingCodeHost {
  PairingCodeHost(this.request, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      code = Random.secure().nextInt(100000000).toString().padLeft(8, '0') {
    request.requireValid(_clock());
    if (!request.hasPairingSecret) {
      throw StateError('Local pairing secret required');
    }
    _expires = _clock().add(lifetime);
    _nextOffer();
  }

  static const lifetime = Duration(minutes: 5);
  static const maxAttempts = 3;
  final DeviceVerificationRequest request;
  final String code;
  final DateTime Function() _clock;
  late final DateTime _expires;
  SRP6Server? _server;
  Map<String, dynamic> _offer = {};
  int _attempts = 0;
  bool _closed = false;
  bool _answering = false;
  bool get isValid =>
      !_closed &&
      _clock().isBefore(_expires) &&
      request.isValidAt(_clock()) &&
      _attempts < maxAttempts;
  Map<String, dynamic> get offer => Map.unmodifiable(_offer);

  void _nextOffer() {
    final salt = _randomBytes(32);
    final verifier = SRP6VerifierGenerator(
      group: _group,
      digest: SHA256Digest(),
    ).generateVerifier(salt, _identity(request), _bytes(code));
    _server = SRP6Server(
      group: _group,
      v: verifier,
      digest: SHA256Digest(),
      random: _random(),
    );
    _offer = {
      'version': 1,
      'id': base64UrlEncode(_randomBytes(32)),
      'salt': base64Encode(salt),
      'B': _hex(_server!.generateServerCredentials()!, 384),
    };
  }

  /// Consume before awaiting: one evidence evaluation per fresh ephemeral, at
  /// most three per code. Limits are local and cannot be reset by mailbox writes.
  Future<Map<String, dynamic>?> answer(Map<String, dynamic> response) async {
    if (!isValid || _answering || response['id'] != _offer['id']) return null;
    _answering = true;
    _attempts++;
    final server = _server!;
    _server = null;
    Uint8List? key;
    try {
      _shape(response, {'id', 'A', 'M1'});
      server.calculateSecret(_public(response['A']));
      if (!server.verifyClientEvidenceMessage(_proof(response['M1']))) {
        throw const FormatException('Pairing code did not match');
      }
      final m2 = _hex(server.calculateServerEvidenceMessage()!, 32);
      key = await _handoffKey(
        server.calculateSessionKey()!,
        request,
        _offer,
        response,
        m2,
      );
      if (_closed ||
          !_clock().isBefore(_expires) ||
          !request.isValidAt(_clock())) {
        return null;
      }
      final encrypted = await AuthenticatedCipher.encryptString(
        request.qrData,
        key,
      );
      if (_closed ||
          !_clock().isBefore(_expires) ||
          !request.isValidAt(_clock())) {
        return null;
      }
      _closed = true;
      return {'id': _offer['id'], 'M2': m2, ...encrypted.toJson()};
    } catch (_) {
      if (isValid) _nextOffer();
      return null;
    } finally {
      key?.fillRange(0, key.length, 0);
      _answering = false;
    }
  }

  void close() {
    _closed = true;
    _server = null;
  }
}

/// Trusted device: code knowledge authenticates the exact pending request.
class PairingCodeClient {
  PairingCodeClient(this.request, String code, Map<String, dynamic> offer)
    : _offer = Map.unmodifiable(offer) {
    request.requireValid(DateTime.now());
    if (!RegExp(r'^\d{8}$').hasMatch(code)) {
      throw const FormatException('Enter an eight-digit pairing code');
    }
    _shape(offer, {'version', 'id', 'salt', 'B'});
    if (offer['version'] != 1) {
      throw const FormatException('Unsupported pairing protocol');
    }
    _base64(offer['id'], 32, url: true);
    final salt = _base64(offer['salt'], 32);
    _client = SRP6Client(
      group: _group,
      digest: SHA256Digest(),
      random: _random(),
    );
    final a = _client.generateClientCredentials(
      salt,
      _identity(request),
      _bytes(code),
    )!;
    _client.calculateSecret(_public(offer['B']));
    response = Map.unmodifiable({
      'id': offer['id'],
      'A': _hex(a, 384),
      'M1': _hex(_client.calculateClientEvidenceMessage()!, 32),
    });
  }

  final DeviceVerificationRequest request;
  final Map<String, dynamic> _offer;
  late final SRP6Client _client;
  late final Map<String, dynamic> response;
  bool _used = false;

  Future<VerifiedDeviceApproval> finish(Map<String, dynamic> result) async {
    if (_used) throw StateError('Pairing exchange already consumed');
    _used = true;
    Uint8List? key;
    try {
      request.requireValid(DateTime.now());
      _shape(result, {'id', 'M2', 'nonce', 'ciphertext'});
      if (result['id'] != _offer['id'] ||
          !_client.verifyServerEvidenceMessage(_proof(result['M2']))) {
        throw const FormatException();
      }
      _base64(result['nonce'], 24);
      final ciphertext = result['ciphertext'];
      if (ciphertext is! String ||
          ciphertext.length > 8192 ||
          base64Decode(ciphertext).length < 16) {
        throw const FormatException();
      }
      key = await _handoffKey(
        _client.calculateSessionKey()!,
        request,
        _offer,
        response,
        result['M2'] as String,
      );
      final qr = await AuthenticatedCipher.decryptString(
        ciphertext,
        result['nonce'] as String,
        key,
      );
      return request.verifyQr(qr);
    } catch (_) {
      throw const FormatException('Device pairing could not be verified');
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  }
}

final _group = SRP6StandardGroups.rfc5054_3072;
Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

FortunaRandom _random() =>
    FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
Uint8List _identity(DeviceVerificationRequest request) => _bytes(
  jsonEncode(['better-keep/pairing-code/srp6a/v1', request.canonical]),
);
String _hex(BigInt value, int bytes) =>
    value.toRadixString(16).padLeft(bytes * 2, '0');
BigInt _number(Object? value, int bytes) {
  if (value is! String ||
      value.length != bytes * 2 ||
      !RegExp(r'^[0-9a-f]+$').hasMatch(value)) {
    throw const FormatException('Invalid pairing value');
  }
  return BigInt.parse(value, radix: 16);
}

BigInt _public(Object? value) {
  final number = _number(value, 384);
  if (number <= BigInt.one || number >= _group.N - BigInt.one) {
    throw const FormatException('Invalid pairing public value');
  }
  return number;
}

BigInt _proof(Object? value) => _number(value, 32);
Uint8List _base64(Object? value, int length, {bool url = false}) {
  if (value is! String || value.length != ((length + 2) ~/ 3) * 4) {
    throw const FormatException('Invalid pairing value');
  }
  final bytes = base64Decode(value);
  if (bytes.length != length ||
      (url ? base64UrlEncode(bytes) : base64Encode(bytes)) != value) {
    throw const FormatException('Invalid pairing value');
  }
  return bytes;
}

void _shape(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !keys.every(value.containsKey)) {
    throw const FormatException('Invalid pairing message');
  }
}

Future<Uint8List> _handoffKey(
  BigInt session,
  DeviceVerificationRequest request,
  Map<String, dynamic> offer,
  Map<String, dynamic> response,
  String m2,
) async {
  final raw = Uint8List.fromList(
    List.generate(
      32,
      (i) => ((session >> ((31 - i) * 8)) & BigInt.from(255)).toInt(),
    ),
  );
  try {
    final key = await crypto.Hkdf(hmac: crypto.Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: crypto.SecretKey(raw),
          nonce: _base64(offer['salt'], 32),
          info: _bytes(
            jsonEncode([
              'better-keep/pairing-code/handoff/v1',
              request.canonical,
              offer['id'],
              offer['B'],
              response['A'],
              response['M1'],
              m2,
            ]),
          ),
        );
    return Uint8List.fromList(await key.extractBytes());
  } finally {
    raw.fillRange(0, raw.length, 0);
  }
}

Future<PairingCodeHost> createPairingCodeHost(
  DeviceVerificationRequest request,
) => compute(_createHost, request);
PairingCodeHost _createHost(DeviceVerificationRequest request) =>
    PairingCodeHost(request);

Future<PairingCodeClient> createPairingCodeClient(
  DeviceVerificationRequest request,
  String code,
  Map<String, dynamic> offer,
) => compute(_createClient, (request, code, offer));
PairingCodeClient _createClient(
  (DeviceVerificationRequest, String, Map<String, dynamic>) input,
) => PairingCodeClient(input.$1, input.$2, input.$3);

Future<(PairingCodeHost, Map<String, dynamic>?)> answerPairingCode(
  PairingCodeHost host,
  Map<String, dynamic> response,
) => compute(_answerHost, (host, response));
Future<(PairingCodeHost, Map<String, dynamic>?)> _answerHost(
  (PairingCodeHost, Map<String, dynamic>) input,
) async => (input.$1, await input.$1.answer(input.$2));
