/// Low-level cryptographic primitives for E2EE.
///
/// This module provides authenticated encryption (XChaCha20-Poly1305),
/// key derivation (Argon2id/PBKDF2), and X25519 key exchange.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:hashlib/hashlib.dart' as hashlib;

/// Authenticated encryption using XChaCha20-Poly1305.
///
/// Provides 256-bit security with a 192-bit nonce for safe random generation.
class AuthenticatedCipher {
  static final _algorithm = Xchacha20.poly1305Aead();

  /// Encrypts [plaintext] using [key] with authenticated encryption.
  ///
  /// Returns a [CipherResult] containing nonce and ciphertext.
  /// A fresh random nonce is generated for each encryption.
  static Future<CipherResult> encrypt(
    Uint8List plaintext,
    Uint8List key,
  ) async {
    final secretKey = SecretKey(key);
    final secretBox = await _algorithm.encrypt(plaintext, secretKey: secretKey);

    return CipherResult(
      nonce: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.concatenation(nonce: false)),
    );
  }

  /// Decrypts [ciphertext] using [key] and [nonce].
  ///
  /// Returns the decrypted plaintext.
  /// Throws if authentication fails (tampering detected).
  static Future<Uint8List> decrypt(
    Uint8List ciphertext,
    Uint8List nonce,
    Uint8List key,
  ) async {
    final secretKey = SecretKey(key);

    // The ciphertext includes the MAC at the end (16 bytes)
    final macLength = 16;
    final actualCiphertext = ciphertext.sublist(
      0,
      ciphertext.length - macLength,
    );
    final mac = Mac(ciphertext.sublist(ciphertext.length - macLength));

    final secretBox = SecretBox(actualCiphertext, nonce: nonce, mac: mac);

    final plaintext = await _algorithm.decrypt(secretBox, secretKey: secretKey);

    return Uint8List.fromList(plaintext);
  }

  /// Encrypts a string and returns base64-encoded result.
  static Future<CipherResultString> encryptString(
    String plaintext,
    Uint8List key,
  ) async {
    final result = await encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
      key,
    );
    return CipherResultString(
      nonce: base64Encode(result.nonce),
      ciphertext: base64Encode(result.ciphertext),
    );
  }

  /// Decrypts base64-encoded ciphertext and returns the string.
  static Future<String> decryptString(
    String ciphertext,
    String nonce,
    Uint8List key,
  ) async {
    final decrypted = await decrypt(
      base64Decode(ciphertext),
      base64Decode(nonce),
      key,
    );
    return utf8.decode(decrypted);
  }
}

/// Result of authenticated encryption.
class CipherResult {
  final Uint8List nonce;
  final Uint8List ciphertext;

  CipherResult({required this.nonce, required this.ciphertext});
}

/// String version of cipher result for easy serialization.
class CipherResultString {
  final String nonce;
  final String ciphertext;

  CipherResultString({required this.nonce, required this.ciphertext});

  Map<String, String> toJson() => {'nonce': nonce, 'ciphertext': ciphertext};

  factory CipherResultString.fromJson(Map<String, dynamic> json) {
    return CipherResultString(
      nonce: json['nonce'] as String,
      ciphertext: json['ciphertext'] as String,
    );
  }
}

/// X25519 key exchange for deriving shared secrets.
class KeyExchange {
  static final _algorithm = X25519();

  /// Generates a new X25519 keypair.
  ///
  /// Returns a [KeyPair] with public and private keys.
  static Future<DeviceKeyPair> generateKeyPair() async {
    final keyPair = await _algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

    return DeviceKeyPair(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(privateKeyBytes),
    );
  }

  /// Derives a shared secret using ECDH.
  ///
  /// Uses the local private key and remote public key to derive
  /// a 32-byte shared secret suitable for symmetric encryption.
  static Future<Uint8List> deriveSharedSecret(
    Uint8List privateKey,
    Uint8List remotePublicKey,
  ) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(privateKey);
    final remotePubKey = SimplePublicKey(
      remotePublicKey,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePubKey,
    );

    return Uint8List.fromList(await sharedSecret.extractBytes());
  }
}

/// Device keypair for X25519 key exchange.
class DeviceKeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;

  DeviceKeyPair({required this.publicKey, required this.privateKey});

  String get publicKeyBase64 => base64Encode(publicKey);
  String get privateKeyBase64 => base64Encode(privateKey);

  factory DeviceKeyPair.fromBase64({
    required String publicKey,
    required String privateKey,
  }) {
    return DeviceKeyPair(
      publicKey: base64Decode(publicKey),
      privateKey: base64Decode(privateKey),
    );
  }
}

/// Key derivation algorithm type.
enum KdfType { argon2id, pbkdf2 }

class KeyDerivation {
  /// Returns the KDF algorithm used for new recovery keys.
  /// Using PBKDF2 on all platforms for cross-platform compatibility.
  static KdfType get currentPlatformKdf => KdfType.pbkdf2;

  /// Derives a 32-byte key from a passphrase using PBKDF2.
  /// Uses PBKDF2 on all platforms for cross-platform recovery compatibility.
  ///
  /// [passphrase] - User-provided password/passphrase
  /// [salt] - Random 16-byte salt (must be stored alongside encrypted data)
  static Future<Uint8List> deriveKeyFromPassphrase(
    String passphrase,
    Uint8List salt,
  ) async {
    return deriveKeyWithKdf(passphrase, salt, currentPlatformKdf);
  }

  /// Derives a key using a specific KDF algorithm.
  /// Use this for recovery to ensure the correct algorithm is used.
  static Future<Uint8List> deriveKeyWithKdf(
    String passphrase,
    Uint8List salt,
    KdfType kdfType,
  ) async {
    switch (kdfType) {
      case KdfType.pbkdf2:
        return _deriveKeyPbkdf2(passphrase, salt);
      case KdfType.argon2id:
        if (kIsWeb) {
          // On web, run Argon2id directly (no isolates) with reduced memory
          return _deriveKeyArgon2idDirect(passphrase, salt);
        }
        // Run Argon2id in a background isolate
        final result = await compute(
          _deriveKeyArgon2idIsolate,
          _Argon2idParams(utf8.encode(passphrase), salt.toList()),
        );
        return result;
    }
  }

  /// PBKDF2 key derivation (for web platform)
  static Future<Uint8List> _deriveKeyPbkdf2(
    String passphrase,
    Uint8List salt,
  ) async {
    // Using SHA-256 with 310,000 iterations as recommended by OWASP for PBKDF2
    final algorithm = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 310000,
      bits: 256,
    );

    final secretKey = await algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );

    return Uint8List.fromList(await secretKey.extractBytes());
  }

  /// Argon2id key derivation (runs directly, for web when recovering with Argon2id)
  /// NOTE: Web cannot handle 64MB Argon2id - this throws on web!
  static Uint8List _deriveKeyArgon2idDirect(String passphrase, Uint8List salt) {
    if (kIsWeb) {
      // 64MB Argon2id crashes browsers - caller should check and show appropriate error
      throw UnsupportedError(
        'Argon2id recovery is not supported on web. Please use a mobile or desktop app to recover.',
      );
    }

    // Must use same parameters as compute() version for compatibility
    final argon2 = hashlib.Argon2(
      type: hashlib.Argon2Type.argon2id,
      hashLength: 32,
      iterations: 3,
      memorySizeKB: 65536, // 64 MB
      parallelism: 4,
      salt: salt.toList(),
    );

    final result = argon2.convert(utf8.encode(passphrase));
    return Uint8List.fromList(result.bytes);
  }

  /// Generates a random 16-byte salt for key derivation.
  static Uint8List generateSalt() {
    return SecureRandom.instance.nextBytes(16);
  }
}

/// Parameters for Argon2id key derivation in isolate.
/// Must be a simple class that can be sent across isolate boundaries.
class _Argon2idParams {
  final List<int> passphraseBytes;
  final List<int> salt;

  _Argon2idParams(this.passphraseBytes, this.salt);
}

/// Top-level function for Argon2id key derivation (required for compute()).
/// Uses hashlib's optimized Argon2id implementation which is 10-50x faster
/// than the cryptography package's pure Dart implementation.
///
/// Note: Uses the same parameters that were used when creating recovery keys.
/// Changing these would break existing recovery keys!
Uint8List _deriveKeyArgon2idIsolate(_Argon2idParams params) {
  // Use hashlib's Argon2 which is much faster than cryptography package
  final argon2 = hashlib.Argon2(
    type: hashlib.Argon2Type.argon2id,
    hashLength: 32,
    iterations: 3, // DO NOT CHANGE (breaks existing keys)
    memorySizeKB: 65536, // 64 MB - DO NOT CHANGE (breaks existing keys)
    parallelism: 4, // DO NOT CHANGE (breaks existing keys)
    salt: params.salt,
  );

  final result = argon2.convert(params.passphraseBytes);

  return Uint8List.fromList(result.bytes);
}

/// Secure random number generator.
class SecureRandom {
  static final instance = SecureRandom._();
  SecureRandom._();

  /// Generates [length] random bytes.
  Uint8List nextBytes(int length) {
    // Use cryptography library's secure random
    final key = SecretKeyData.random(length: length);
    return Uint8List.fromList(key.bytes);
  }
}

/// Generates a random 32-byte User Master Key.
Uint8List generateUserMasterKey() {
  return SecureRandom.instance.nextBytes(32);
}

/// File encryption utilities for attachments.
///
/// Uses the same XChaCha20-Poly1305 algorithm as note encryption.
/// For files, the nonce is prepended to the ciphertext for simplicity.
class FileEncryption {
  /// Nonce size for XChaCha20 (24 bytes / 192 bits).
  static const nonceSize = 24;

  /// MAC size for Poly1305 (16 bytes).
  static const macSize = 16;

  /// Encrypts file bytes and returns ciphertext with prepended nonce.
  ///
  /// Output format: [nonce (24 bytes)][ciphertext][mac (16 bytes)]
  static Future<Uint8List> encryptBytes(
    Uint8List plaintext,
    Uint8List key,
  ) async {
    final result = await AuthenticatedCipher.encrypt(plaintext, key);

    // Combine nonce + ciphertext (which includes MAC)
    final output = Uint8List(result.nonce.length + result.ciphertext.length);
    output.setRange(0, result.nonce.length, result.nonce);
    output.setRange(result.nonce.length, output.length, result.ciphertext);

    return output;
  }

  /// Decrypts file bytes (expects nonce prepended to ciphertext).
  ///
  /// Input format: [nonce (24 bytes)][ciphertext][mac (16 bytes)]
  static Future<Uint8List> decryptBytes(
    Uint8List encryptedData,
    Uint8List key,
  ) async {
    if (encryptedData.length < nonceSize + macSize) {
      throw ArgumentError('Encrypted data too short');
    }

    final nonce = encryptedData.sublist(0, nonceSize);
    final ciphertext = encryptedData.sublist(nonceSize);

    return await AuthenticatedCipher.decrypt(ciphertext, nonce, key);
  }

  /// Checks if data appears to be encrypted (has valid structure).
  ///
  /// This is a heuristic check - encrypted data should be at least
  /// nonce + MAC size, and won't have common file magic bytes.
  static bool looksEncrypted(Uint8List data) {
    if (data.length < nonceSize + macSize) return false;

    // Check for common unencrypted file signatures
    // JPEG: FF D8 FF
    if (data.length >= 3 &&
        data[0] == 0xFF &&
        data[1] == 0xD8 &&
        data[2] == 0xFF) {
      return false;
    }
    // PNG: 89 50 4E 47
    if (data.length >= 4 &&
        data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return false;
    }
    // GIF: 47 49 46 38
    if (data.length >= 4 &&
        data[0] == 0x47 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x38) {
      return false;
    }
    // WebP: 52 49 46 46 (RIFF)
    if (data.length >= 4 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46) {
      return false;
    }
    // MP3: FF FB or ID3
    if (data.length >= 3 &&
        ((data[0] == 0xFF && data[1] == 0xFB) ||
            (data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33))) {
      return false;
    }
    // WAV: RIFF....WAVE
    if (data.length >= 4 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46) {
      return false;
    }
    // M4A/MP4: ftyp
    if (data.length >= 8 &&
        data[4] == 0x66 &&
        data[5] == 0x74 &&
        data[6] == 0x79 &&
        data[7] == 0x70) {
      return false;
    }

    return true;
  }

  /// Calculates the encrypted size for a given plaintext size.
  static int encryptedSize(int plaintextSize) {
    return nonceSize + plaintextSize + macSize;
  }

  /// Calculates the plaintext size for a given encrypted size.
  static int plaintextSize(int encryptedSize) {
    return encryptedSize - nonceSize - macSize;
  }
}
