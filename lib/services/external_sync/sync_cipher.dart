import 'sync_limits.dart';

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'sync_revision.dart';

/// Separate keys for external content and commits, bound to the account and
/// current master-key generation. No provider receives the master key.
class SyncCipher {
  SyncCipher._(
    this.libraryId,
    this._objectKey,
    this._commitKey,
    this._capabilityKey,
    this._fingerprintKey,
    this._credentialKey,
  );

  final String libraryId;
  final Uint8List _objectKey;
  final Uint8List _commitKey;
  final Uint8List _capabilityKey;
  final Uint8List _fingerprintKey;
  final Uint8List _credentialKey;
  bool _disposed = false;

  static Future<SyncCipher> create(String uid, Uint8List masterKey) async {
    if (uid.isEmpty || masterKey.length != 32) {
      throw ArgumentError('An account and a 256-bit master key are required');
    }
    Future<Uint8List> derive(String purpose) async {
      final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(masterKey),
        nonce: utf8.encode(uid),
        info: utf8.encode('better-keep/external-sync/v1/$purpose'),
      );
      return Uint8List.fromList(await key.extractBytes());
    }

    final identity = await derive('library');
    final cipher = SyncCipher._(
      hashes.sha256.convert(identity).toString(),
      await derive('objects'),
      await derive('commits'),
      await derive('capabilities'),
      await derive('fingerprints'),
      await derive('credentials'),
    );
    identity.fillRange(0, identity.length, 0);
    return cipher;
  }

  /// Keyed, account-scoped fingerprint: remote storage cannot test guesses of
  /// plaintext content against it without the user's master key.
  String contentFingerprint(List<int> bytes) {
    _guard();
    return hashes.Hmac(
      hashes.sha256,
      _fingerprintKey,
    ).convert(bytes).toString();
  }

  /// Backend reset metadata cannot redirect deletion into another account's
  /// library: every post-reset namespace is keyed to this encrypted library.
  String storageNamespace(String provider, String epoch) => epoch.isEmpty
      ? libraryId
      : contentFingerprint(
          utf8.encode('better-keep/storage-space/v1/$provider/$epoch'),
        );

  Future<Uint8List> encryptObject(Uint8List plaintext) async {
    _guard();
    final bytes = await FileEncryption.encryptBytes(plaintext, _objectKey);
    _guard();
    return bytes;
  }

  Future<Uint8List> decryptObject(Uint8List ciphertext) async {
    _guard();
    if (ciphertext.length > SyncLimits.objectBytes) {
      throw const FormatException('Sync object too large');
    }
    try {
      final bytes = await FileEncryption.decryptBytes(ciphertext, _objectKey);
      _guard();
      return bytes;
    } on StateError {
      rethrow;
    } catch (_) {
      _guard();
      throw const FormatException('Invalid encrypted sync object');
    }
  }

  Future<Uint8List> encodeCommit(SyncRevision revision) async {
    _guard();
    final ciphertext = await FileEncryption.encryptBytes(
      Uint8List.fromList(utf8.encode(revision.encode())),
      _commitKey,
    );
    _guard();
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'library': libraryId,
          'ciphertext': base64Encode(ciphertext),
        }),
      ),
    );
  }

  Future<SyncRevision> decodeCommit(Uint8List bytes) async {
    _guard();
    if (bytes.length > SyncLimits.commitBytes) {
      throw const FormatException("Sync commit too large");
    }
    final envelope = jsonDecode(utf8.decode(bytes));
    if (envelope is! Map<String, dynamic> ||
        envelope['version'] != 1 ||
        envelope['library'] != libraryId ||
        envelope['ciphertext'] is! String) {
      throw const FormatException('Wrong sync library or unsupported commit');
    }
    final plaintext = await FileEncryption.decryptBytes(
      base64Decode(envelope['ciphertext'] as String),
      _commitKey,
    );
    _guard();
    return SyncRevision.decode(utf8.decode(plaintext));
  }

  static String newCapability() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<String> encryptCapability(String provider, String capability) async {
    _guard();
    _validateCapability(provider, capability);
    final bytes = await FileEncryption.encryptBytes(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'library': libraryId,
            'provider': provider,
            'capability': capability,
          }),
        ),
      ),
      _capabilityKey,
    );
    _guard();
    return base64Encode(bytes);
  }

  Future<String> decryptCapability(String provider, String encrypted) async {
    _guard();
    if (encrypted.length > 16384) {
      throw const FormatException('Invalid connection capability');
    }
    final bytes = await FileEncryption.decryptBytes(
      base64Decode(encrypted),
      _capabilityKey,
    );
    _guard();
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['library'] != libraryId ||
        value['provider'] != provider ||
        value['capability'] is! String) {
      throw const FormatException('Wrong connection capability context');
    }
    final capability = value['capability'] as String;
    _validateCapability(provider, capability);
    return capability;
  }

  /// A separate purpose key under the same user master key as notes. Context
  /// lives inside the authenticated ciphertext and is checked before use.
  Future<String> encryptCredentials({
    required String provider,
    required int generation,
    required String clientId,
    required Map<String, dynamic> credentials,
  }) async {
    _guard();
    _validateCredentialContext(provider, generation, clientId);
    final plaintext = utf8.encode(
      jsonEncode({
        'version': 1,
        'library': libraryId,
        'provider': provider,
        'generation': generation,
        'clientId': clientId,
        'credentials': credentials,
      }),
    );
    if (plaintext.length > 65536) {
      throw const FormatException('Credentials too large');
    }
    final bytes = await FileEncryption.encryptBytes(
      Uint8List.fromList(plaintext),
      _credentialKey,
    );
    _guard();
    return base64Encode(bytes);
  }

  Future<Map<String, dynamic>> decryptCredentials({
    required String provider,
    required int generation,
    required String clientId,
    required String encrypted,
  }) async {
    _guard();
    _validateCredentialContext(provider, generation, clientId);
    if (encrypted.isEmpty || encrypted.length > 100000) {
      throw const FormatException('Invalid encrypted credentials');
    }
    final bytes = await FileEncryption.decryptBytes(
      base64Decode(encrypted),
      _credentialKey,
    );
    _guard();
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['library'] != libraryId ||
        value['provider'] != provider ||
        value['generation'] != generation ||
        value['clientId'] != clientId ||
        value['credentials'] is! Map<String, dynamic>) {
      throw const FormatException('Wrong credential context');
    }
    return value['credentials'] as Map<String, dynamic>;
  }

  static void _validateCredentialContext(
    String provider,
    int generation,
    String clientId,
  ) {
    if (![
          'google_drive',
          'dropbox',
          'nextcloud',
          'webdav',
        ].contains(provider) ||
        generation < 1 ||
        generation > 9007199254740991 ||
        clientId.length > 512 ||
        (!['nextcloud', 'webdav'].contains(provider) && clientId.isEmpty)) {
      throw const FormatException('Invalid credential context');
    }
  }

  static void _validateCapability(String provider, String capability) {
    if (![
          'google_drive',
          'dropbox',
          'nextcloud',
          'webdav',
        ].contains(provider) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(capability) ||
        base64UrlEncode(base64Url.decode(base64Url.normalize(capability)))
                .replaceAll('=', '') !=
            capability) {
      throw const FormatException('Invalid connection capability');
    }
  }

  void dispose() {
    _disposed = true;
    _objectKey.fillRange(0, _objectKey.length, 0);
    _commitKey.fillRange(0, _commitKey.length, 0);
    _capabilityKey.fillRange(0, _capabilityKey.length, 0);
    _fingerprintKey.fillRange(0, _fingerprintKey.length, 0);
    _credentialKey.fillRange(0, _credentialKey.length, 0);
  }

  void _guard() {
    if (_disposed) throw StateError('Sync encryption session has ended');
  }
}
