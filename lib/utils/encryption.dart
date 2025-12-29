import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as legacy_crypto;
import 'package:cryptography/cryptography.dart';

/// AES-GCM algorithm for secure local PIN encryption.
/// Uses 256-bit key derived from password via SHA-256.
final _algorithm = AesGcm.with256bits();

/// Derives a 256-bit key from a password using SHA-256.
Future<SecretKey> _deriveKey(String password) async {
  final hash = await Sha256().hash(utf8.encode(password));
  return SecretKey(hash.bytes);
}

/// Legacy XOR decryption for backward compatibility with existing notes.
/// DO NOT use for new encryption - only for decrypting old data.
String _legacyDecrypt(String encryptedData, String password) {
  final key = legacy_crypto.sha256.convert(utf8.encode(password)).bytes;
  final cipher = base64Decode(encryptedData);
  final bytes = List<int>.generate(
    cipher.length,
    (i) => cipher[i] ^ key[i % key.length],
  );
  return utf8.decode(bytes, allowMalformed: false);
}

/// Encrypts data using AES-GCM with a password-derived key.
/// Used for local PIN protection of notes.
///
/// Format: base64(nonce + ciphertext + mac)
/// - nonce: 12 bytes
/// - ciphertext: variable length
/// - mac: 16 bytes
Future<String> encryptAsync(String data, String password) async {
  if (data.isEmpty) return '';
  if (password.isEmpty) {
    throw ArgumentError('Password cannot be empty');
  }

  final key = await _deriveKey(password);
  final plaintext = utf8.encode(data);

  final secretBox = await _algorithm.encrypt(plaintext, secretKey: key);

  // Combine nonce + ciphertext + mac into single bytes
  final combined = Uint8List(
    secretBox.nonce.length +
        secretBox.cipherText.length +
        secretBox.mac.bytes.length,
  );
  combined.setRange(0, secretBox.nonce.length, secretBox.nonce);
  combined.setRange(
    secretBox.nonce.length,
    secretBox.nonce.length + secretBox.cipherText.length,
    secretBox.cipherText,
  );
  combined.setRange(
    secretBox.nonce.length + secretBox.cipherText.length,
    combined.length,
    secretBox.mac.bytes,
  );

  return base64Encode(combined);
}

/// Decrypts data with AES-GCM, falling back to legacy XOR for old notes.
/// Throws [FormatException] if the encrypted data is invalid or password is wrong.
/// Throws [ArgumentError] if password is empty.
Future<String> decryptAsync(String encryptedData, String password) async {
  if (encryptedData.isEmpty) return '';
  if (password.isEmpty) {
    throw ArgumentError('Password cannot be empty');
  }

  // Try AES-GCM first (new format)
  try {
    final key = await _deriveKey(password);
    final combined = base64Decode(encryptedData);

    // AES-GCM format: nonce (12 bytes) + ciphertext + mac (16 bytes)
    const nonceLength = 12;
    const macLength = 16;

    if (combined.length >= nonceLength + macLength) {
      final nonce = combined.sublist(0, nonceLength);
      final cipherText = combined.sublist(
        nonceLength,
        combined.length - macLength,
      );
      final macBytes = combined.sublist(combined.length - macLength);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

      final plaintext = await _algorithm.decrypt(secretBox, secretKey: key);

      return utf8.decode(plaintext, allowMalformed: false);
    }
  } on SecretBoxAuthenticationError {
    // AES-GCM failed - might be legacy XOR format, try below
  } catch (_) {
    // AES-GCM failed - might be legacy XOR format, try below
  }

  // Fall back to legacy XOR decryption for backward compatibility
  try {
    return _legacyDecrypt(encryptedData, password);
  } catch (e) {
    throw const FormatException('Invalid encrypted data or incorrect password');
  }
}

/// Encrypts data using AES-GCM. Alias for [encryptAsync].
Future<String> encrypt(String data, String password) =>
    encryptAsync(data, password);

/// Decrypts data with AES-GCM or legacy XOR. Alias for [decryptAsync].
Future<String> decrypt(String encryptedData, String password) =>
    decryptAsync(encryptedData, password);

/// Header bytes for encrypted binary data: "ENCP" (Encrypted with Password)
const _encryptedPasswordHeader = [0x45, 0x4E, 0x43, 0x50];

/// Encrypts binary data using AES-GCM with a password-derived key.
/// Used for encrypting attachments when a note is locked.
///
/// Format: [ENCP header (4)] + [nonce (12)] + [ciphertext] + [mac (16)]
Future<Uint8List> encryptBytesWithPassword(
  Uint8List data,
  String password,
) async {
  if (data.isEmpty) return data;
  if (password.isEmpty) {
    throw ArgumentError('Password cannot be empty');
  }

  final key = await _deriveKey(password);
  final secretBox = await _algorithm.encrypt(data, secretKey: key);

  // Format: header + nonce + ciphertext + mac
  final result = Uint8List(
    4 + secretBox.nonce.length + secretBox.cipherText.length + 16,
  );
  result.setRange(0, 4, _encryptedPasswordHeader);
  result.setRange(4, 4 + secretBox.nonce.length, secretBox.nonce);
  result.setRange(
    4 + secretBox.nonce.length,
    4 + secretBox.nonce.length + secretBox.cipherText.length,
    secretBox.cipherText,
  );
  result.setRange(result.length - 16, result.length, secretBox.mac.bytes);

  return result;
}

/// Decrypts binary data encrypted with [encryptBytesWithPassword].
/// Returns the original data if decryption succeeds, throws on failure.
Future<Uint8List> decryptBytesWithPassword(
  Uint8List encryptedData,
  String password,
) async {
  if (encryptedData.isEmpty) return encryptedData;
  if (password.isEmpty) {
    throw ArgumentError('Password cannot be empty');
  }

  // Check for ENCP header
  if (!isBytesPasswordEncrypted(encryptedData)) {
    throw const FormatException('Data is not password-encrypted');
  }

  const nonceLength = 12;
  const macLength = 16;
  const headerLength = 4;

  if (encryptedData.length < headerLength + nonceLength + macLength) {
    throw const FormatException('Invalid encrypted data: too short');
  }

  final key = await _deriveKey(password);

  final nonce = encryptedData.sublist(headerLength, headerLength + nonceLength);
  final cipherText = encryptedData.sublist(
    headerLength + nonceLength,
    encryptedData.length - macLength,
  );
  final macBytes = encryptedData.sublist(encryptedData.length - macLength);

  final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

  try {
    final plaintext = await _algorithm.decrypt(secretBox, secretKey: key);
    return Uint8List.fromList(plaintext);
  } on SecretBoxAuthenticationError {
    throw const FormatException('Incorrect password or corrupted data');
  }
}

/// Checks if binary data has the password-encrypted header "ENCP".
bool isBytesPasswordEncrypted(Uint8List data) {
  if (data.length < 4) return false;
  return data[0] == _encryptedPasswordHeader[0] &&
      data[1] == _encryptedPasswordHeader[1] &&
      data[2] == _encryptedPasswordHeader[2] &&
      data[3] == _encryptedPasswordHeader[3];
}
