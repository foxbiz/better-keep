import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// An independently verified challenge. Request QR data may contain a temporary
/// pairing secret and must never be uploaded or logged.
abstract interface class DeviceVerificationChallenge<T> {
  String get qrData;
  String get securityCode;
  bool isValidAt(DateTime now);
  T verifyQr(String value, {DateTime? now});
  T confirmCode(String completeCode, {DateTime? now});
}

class DeviceVerificationRequest
    implements DeviceVerificationChallenge<VerifiedDeviceApproval> {
  DeviceVerificationRequest._({
    required this.account,
    required this.environment,
    required this.deviceId,
    required this.publicKey,
    required this.requestId,
    required this.createdAt,
    this._pairingSecret,
  });

  static const version = 2;
  static const lifetime = Duration(minutes: 10);
  final String account;
  final String environment;
  final String deviceId;
  final String publicKey;
  final String requestId;
  final int createdAt;
  final String? _pairingSecret;
  bool get hasPairingSecret => _pairingSecret != null;

  factory DeviceVerificationRequest.create({
    required String account,
    required String environment,
    required String deviceId,
    required Uint8List publicKey,
    DateTime? now,
  }) {
    final random = Random.secure();
    final request = DeviceVerificationRequest.fromJson({
      'version': version,
      'account': account,
      'environment': environment,
      'deviceId': deviceId,
      'publicKey': base64Encode(publicKey),
      'requestId': base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ),
      'createdAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
    });
    return request._withSecret(
      base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256))),
    );
  }

  DeviceVerificationRequest _withSecret(String? secret) =>
      DeviceVerificationRequest._(
        account: account,
        environment: environment,
        deviceId: deviceId,
        publicKey: publicKey,
        requestId: requestId,
        createdAt: createdAt,
        pairingSecret: secret,
      );

  /// Only for native secure storage / browser memory. Server records must use
  /// fromJson, which rejects the private QR wrapper and extra fields.
  factory DeviceVerificationRequest.fromLocalData(String value) =>
      _readQr(value);

  static DeviceVerificationRequest _readQr(String value) {
    try {
      if (value.length > 4096) throw const FormatException();
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic>) throw const FormatException();
      if (!data.containsKey('type')) {
        return DeviceVerificationRequest.fromJson(data);
      }
      if (data.length != 4 ||
          data['type'] != 'better-keep/device-pairing' ||
          data['version'] != 1 ||
          data['request'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      _decodePairingValue(data['secret']);
      return DeviceVerificationRequest.fromJson(
        data['request'] as Map<String, dynamic>,
      )._withSecret(data['secret'] as String);
    } catch (_) {
      // Parser exceptions must not carry the QR / local secret into logs.
      throw const FormatException('Invalid device pairing data');
    }
  }

  factory DeviceVerificationRequest.fromJson(Map<String, dynamic> json) {
    if (json.length != 7 || json['version'] != version) {
      throw const FormatException('Unsupported device verification request');
    }
    for (final key in [
      'account',
      'environment',
      'deviceId',
      'publicKey',
      'requestId',
    ]) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > 512) {
        throw const FormatException('Invalid device verification request');
      }
    }
    final publicKey = json['publicKey'] as String;
    final requestId = json['requestId'] as String;
    if (base64Decode(publicKey).length != 32 ||
        base64Encode(base64Decode(publicKey)) != publicKey ||
        base64Url.decode(requestId).length != 32 ||
        base64UrlEncode(base64Url.decode(requestId)) != requestId ||
        json['createdAt'] is! int ||
        (json['createdAt'] as int) < 0 ||
        (json['createdAt'] as int) > 8640000000000000) {
      throw const FormatException('Invalid device verification request');
    }
    return DeviceVerificationRequest._(
      account: json['account'] as String,
      environment: json['environment'] as String,
      deviceId: json['deviceId'] as String,
      publicKey: publicKey,
      requestId: requestId,
      createdAt: json['createdAt'] as int,
    );
  }

  /// Public server representation: deliberately excludes the pairing secret.
  Map<String, dynamic> toJson() => {
    'version': version,
    'account': account,
    'environment': environment,
    'deviceId': deviceId,
    'publicKey': publicKey,
    'requestId': requestId,
    'createdAt': createdAt,
  };

  String get canonical => jsonEncode([
    'better-keep/device-approval',
    version,
    environment,
    account,
    deviceId,
    publicKey,
    requestId,
    createdAt,
  ]);
  @override
  String get qrData => _pairingSecret == null
      ? jsonEncode(toJson())
      : jsonEncode({
          'type': 'better-keep/device-pairing',
          'version': 1,
          'request': toJson(),
          'secret': _pairingSecret,
        });

  /// Authentication by the out-of-band QR secret replaces the return scan.
  /// No server-supplied flag or unkeyed fingerprint can produce this proof.
  VerifiedDeviceReceipt? verifyPairingReceipt(
    DeviceApprovalReceipt receipt, {
    DateTime? now,
  }) {
    if (!receipt.hasPairingProof) return null;
    requireValid(now ?? DateTime.now());
    if (_pairingSecret == null || receipt.request.canonical != canonical) {
      throw StateError('Pairing secret unavailable or request changed');
    }
    final expected = _pairingMac(_pairingSecret, receipt.fingerprint);
    final actual = _decodePairingValue(receipt._pairingTag);
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    if (difference != 0) {
      throw StateError('Device pairing authentication failed');
    }
    return VerifiedDeviceReceipt._(receipt);
  }

  @override
  String get securityCode {
    final hex = sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 32)
        .toUpperCase();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
        .join(' ');
  }

  @override
  bool isValidAt(DateTime now) {
    final age = now.millisecondsSinceEpoch - createdAt;
    return age >= -const Duration(minutes: 1).inMilliseconds &&
        age < lifetime.inMilliseconds;
  }

  void requireValid(DateTime now) {
    if (!isValidAt(now)) throw StateError('Device verification expired');
  }

  String encodeMasterKey(Uint8List masterKey) {
    if (masterKey.length != 32) {
      throw const FormatException('Invalid master key');
    }
    return jsonEncode({
      'version': version,
      'request': toJson(),
      'masterKey': base64Encode(masterKey),
    });
  }

  Uint8List decodeMasterKey(
    String plaintext, {
    required int? envelopeVersion,
    String? previouslyAcceptedRequestId,
    DateTime? now,
  }) {
    if (envelopeVersion != version) {
      throw StateError(
        'Verified device approval required. Update the approving device.',
      );
    }
    final value = jsonDecode(plaintext);
    if (value is! Map ||
        value['version'] != version ||
        value['request'] is! Map ||
        value['masterKey'] is! String ||
        DeviceVerificationRequest.fromJson(
              Map<String, dynamic>.from(value['request'] as Map),
            ).canonical !=
            canonical) {
      throw StateError('Approval does not match the local device request');
    }
    if (previouslyAcceptedRequestId != requestId) {
      requireValid(now ?? DateTime.now());
    }
    final key = base64Decode(value['masterKey'] as String);
    if (key.length != 32) throw const FormatException('Invalid master key');
    return key;
  }

  @override
  VerifiedDeviceApproval verifyQr(String value, {DateTime? now}) {
    requireValid(now ?? DateTime.now());
    final scanned = _readQr(value);
    if (scanned.canonical != canonical) {
      throw const FormatException('Device verification does not match');
    }
    return VerifiedDeviceApproval._(this, scanned._pairingSecret);
  }

  /// Only call after the user explicitly confirms the complete displayed code
  /// against the new device. A short PIN is deliberately not supported.
  @override
  VerifiedDeviceApproval confirmCode(String completeCode, {DateTime? now}) {
    requireValid(now ?? DateTime.now());
    if (completeCode.replaceAll(RegExp(r'\s'), '').toUpperCase() !=
        securityCode.replaceAll(' ', '')) {
      throw const FormatException('Device verification does not match');
    }
    return VerifiedDeviceApproval._(this);
  }
}

/// Cannot be constructed from a server-supplied "verified" boolean.
class VerifiedDeviceApproval {
  VerifiedDeviceApproval._(this.request, [this._pairingSecret]);
  final DeviceVerificationRequest request;
  final String? _pairingSecret;

  DeviceApprovalReceipt authenticateReceipt(DeviceApprovalReceipt receipt) {
    if (receipt.request.canonical != request.canonical) {
      throw StateError('Device pairing request changed');
    }
    if (_pairingSecret == null) return receipt;
    return DeviceApprovalReceipt(
      request: receipt.request,
      approverPublicKey: receipt.approverPublicKey,
      ciphertext: receipt.ciphertext,
      nonce: receipt.nonce,
      pairingTag: base64UrlEncode(
        _pairingMac(_pairingSecret, receipt.fingerprint),
      ),
    );
  }
}

/// The return challenge authenticates the exact encrypted handoff. Its QR only
/// contains public fingerprints, never the master key or provider credentials.
class DeviceApprovalReceipt
    implements DeviceVerificationChallenge<VerifiedDeviceReceipt> {
  DeviceApprovalReceipt({
    required this.request,
    required this.approverPublicKey,
    required this.ciphertext,
    required this.nonce,
    String? pairingTag,
  }) : _pairingTag = pairingTag {
    if (pairingTag != null) _decodePairingValue(pairingTag);
    if (base64Decode(approverPublicKey).length != 32 ||
        base64Encode(base64Decode(approverPublicKey)) != approverPublicKey ||
        ciphertext.length > 16384 ||
        base64Decode(ciphertext).length < 16 ||
        base64Decode(nonce).length != 24) {
      throw const FormatException('Invalid device approval handoff');
    }
  }

  factory DeviceApprovalReceipt.fromDocument(
    DeviceVerificationRequest request,
    Map<String, dynamic> data,
  ) {
    if (data['status'] != 'approved' ||
        data['wrapped_umk_version'] != DeviceVerificationRequest.version ||
        data['approval_protocol'] != DeviceVerificationRequest.version ||
        data['public_key'] != request.publicKey ||
        data['approval_request'] is! Map ||
        DeviceVerificationRequest.fromJson(
              Map<String, dynamic>.from(data['approval_request'] as Map),
            ).canonical !=
            request.canonical) {
      throw StateError(
        'Verified device approval required. Update the approving device.',
      );
    }
    final proof = data['pairing_proof'];
    if (proof != null &&
        (proof is! Map || proof.length != 2 || proof['version'] != 1)) {
      throw const FormatException('Unsupported device pairing proof');
    }
    if (proof != null) _decodePairingValue(proof['tag']);
    return DeviceApprovalReceipt(
      request: request,
      approverPublicKey: data['approved_by_public_key'] as String,
      ciphertext: data['wrapped_umk'] as String,
      nonce: data['wrapped_umk_nonce'] as String,
      pairingTag: proof == null ? null : proof['tag'] as String,
    );
  }

  final DeviceVerificationRequest request;
  final String approverPublicKey;
  final String ciphertext;
  final String nonce;
  final String? _pairingTag;
  bool get hasPairingProof => _pairingTag != null;
  Map<String, dynamic>? get pairingProof =>
      _pairingTag == null ? null : {'version': 1, 'tag': _pairingTag};
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'better-keep/device-approval-receipt',
            DeviceVerificationRequest.version,
            request.canonical,
            approverPublicKey,
            ciphertext,
            nonce,
          ]),
        ),
      )
      .toString();

  @override
  String get qrData => jsonEncode({
    'type': 'better-keep/device-approval-receipt',
    'version': DeviceVerificationRequest.version,
    'fingerprint': fingerprint,
  });
  @override
  String get securityCode {
    final hex = fingerprint.substring(0, 32).toUpperCase();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
        .join(' ');
  }

  @override
  bool isValidAt(DateTime now) => request.isValidAt(now);
  @override
  VerifiedDeviceReceipt verifyQr(String value, {DateTime? now}) {
    request.requireValid(now ?? DateTime.now());
    if (value.length > 1024) throw const FormatException('Invalid handoff QR');
    final decoded = jsonDecode(value);
    if (decoded is! Map ||
        decoded.length != 3 ||
        decoded['type'] != 'better-keep/device-approval-receipt' ||
        decoded['version'] != DeviceVerificationRequest.version ||
        decoded['fingerprint'] != fingerprint) {
      throw const FormatException('Trusted device verification does not match');
    }
    return VerifiedDeviceReceipt._(this);
  }

  @override
  VerifiedDeviceReceipt confirmCode(String completeCode, {DateTime? now}) {
    request.requireValid(now ?? DateTime.now());
    if (completeCode.replaceAll(RegExp(r'\s'), '').toUpperCase() !=
        securityCode.replaceAll(' ', '')) {
      throw const FormatException('Trusted device verification does not match');
    }
    return VerifiedDeviceReceipt._(this);
  }

  void requireAccepted(String? acceptedFingerprint) {
    if (acceptedFingerprint != fingerprint) {
      throw StateError(
        'Confirm the trusted device before accepting its master key',
      );
    }
  }
}

class VerifiedDeviceReceipt {
  VerifiedDeviceReceipt._(this.receipt);
  final DeviceApprovalReceipt receipt;
}

Uint8List _decodePairingValue(Object? value) {
  try {
    if (value is! String || value.length != 44) throw const FormatException();
    final bytes = base64Url.decode(value);
    if (bytes.length != 32 || base64UrlEncode(bytes) != value) {
      throw const FormatException();
    }
    return bytes;
  } catch (_) {
    throw const FormatException('Invalid device pairing value');
  }
}

List<int> _pairingMac(String secret, String fingerprint) =>
    Hmac(sha256, _decodePairingValue(secret))
        .convert(
          utf8.encode(
            jsonEncode(['better-keep/device-pairing-proof', 1, fingerprint]),
          ),
        )
        .bytes;
