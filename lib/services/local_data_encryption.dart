/// Local data encryption service for protecting notes and attachments at rest.
///
/// This service encrypts sensitive note fields (title, content, plainText) and
/// attachment files before they are stored locally on the device. It uses AES-256-GCM
/// with an in-app key provided via --dart-define.
///
/// This adds protection against:
/// - Other apps accessing the SQLite database (on Android/Linux/Windows)
/// - Physical device access without proper authentication
/// - File system-level attacks
///
/// Note: This is defense-in-depth. iOS/macOS have strong app sandboxing.
/// E2EE for sync is separate and always active when enabled.
library;

import 'dart:convert';

import 'package:better_keep/utils/logger.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Magic bytes to identify encrypted content (prevents double-encryption)
const _encryptedMagic = 'ENC:';

/// Marker for encrypted file headers
const _encryptedFileHeader = [0x45, 0x4E, 0x43, 0x52]; // "ENCR"

/// Service for encrypting/decrypting local data at rest.
class LocalDataEncryption {
  // In-app encryption key for local data (256-bit AES key as hex string)
  // Set via --dart-define=LOCAL_DATA_KEY=<64-char-hex-string>
  static const String _localDataKeyHex = String.fromEnvironment(
    'LOCAL_DATA_KEY',
    defaultValue: '',
  );

  static Uint8List? _keyCache;
  static final _cipher = AesGcm.with256bits();
  static bool? _notesEnabledCache;
  static bool? _filesEnabledCache;

  static LocalDataEncryption? _instance;
  static LocalDataEncryption get instance {
    _instance ??= LocalDataEncryption._();
    return _instance!;
  }

  LocalDataEncryption._();

  /// Whether local data encryption is available (key is configured).
  static bool get isAvailable {
    return _localDataKeyHex.isNotEmpty && _localDataKeyHex.length == 64;
  }

  /// Gets the encryption key, parsing from hex if needed.
  static Uint8List get _key {
    if (_keyCache != null) return _keyCache!;
    if (!isAvailable) {
      throw StateError(
        'LOCAL_DATA_KEY must be a 64-character hex string (256 bits). '
        'Set it via --dart-define=LOCAL_DATA_KEY=<your-key>',
      );
    }
    // Parse hex string to bytes
    final bytes = <int>[];
    for (var i = 0; i < 64; i += 2) {
      bytes.add(int.parse(_localDataKeyHex.substring(i, i + 2), radix: 16));
    }
    _keyCache = Uint8List.fromList(bytes);
    return _keyCache!;
  }

  /// Checks if note content encryption is enabled by user preference.
  /// Defaults to false (opt-in).
  Future<bool> isNotesEnabled() async {
    if (!isAvailable) return false;
    if (_notesEnabledCache != null) return _notesEnabledCache!;
    final prefs = await SharedPreferences.getInstance();
    _notesEnabledCache =
        prefs.getBool('local_encryption_notes_enabled') ?? false;
    return _notesEnabledCache!;
  }

  /// Sets whether note content encryption is enabled.
  Future<void> setNotesEnabled(bool enabled) async {
    if (!isAvailable) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_encryption_notes_enabled', enabled);
    _notesEnabledCache = enabled;
  }

  /// Checks if file/attachment encryption is enabled by user preference.
  /// Defaults to false (opt-in).
  Future<bool> isFilesEnabled() async {
    if (!isAvailable) return false;
    if (_filesEnabledCache != null) return _filesEnabledCache!;
    final prefs = await SharedPreferences.getInstance();
    _filesEnabledCache =
        prefs.getBool('local_encryption_files_enabled') ?? false;
    return _filesEnabledCache!;
  }

  /// Sets whether file/attachment encryption is enabled.
  Future<void> setFilesEnabled(bool enabled) async {
    if (!isAvailable) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('local_encryption_files_enabled', enabled);
    _filesEnabledCache = enabled;
  }

  /// Legacy: Checks if any local encryption is enabled.
  /// Returns true if either notes or files encryption is enabled.
  Future<bool> isEnabled() async {
    return await isNotesEnabled() || await isFilesEnabled();
  }

  /// Legacy: Sets both notes and files encryption.
  Future<void> setEnabled(bool enabled) async {
    await setNotesEnabled(enabled);
    await setFilesEnabled(enabled);
  }

  /// Encrypts a string value for storage in SQLite.
  /// Returns the encrypted string prefixed with magic bytes.
  /// Returns the original string if note encryption is disabled or value is empty.
  Future<String> encryptString(String value) async {
    if (value.isEmpty) return value;
    if (!await isNotesEnabled()) return value;

    // Don't double-encrypt
    if (value.startsWith(_encryptedMagic)) return value;

    try {
      final secretKey = SecretKey(_key);
      final nonce = _cipher.newNonce();
      final secretBox = await _cipher.encrypt(
        utf8.encode(value),
        secretKey: secretKey,
        nonce: nonce,
      );

      // Combine nonce + ciphertext + mac
      final combined = Uint8List.fromList([
        ...secretBox.nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);

      return '$_encryptedMagic${base64Encode(combined)}';
    } catch (e) {
      // On encryption failure, return original to avoid data loss
      AppLogger.error('LocalDataEncryption: Failed to encrypt string', e);
      return value;
    }
  }

  /// Decrypts a string value from SQLite.
  /// Returns the decrypted string, or the original if not encrypted.
  Future<String> decryptString(String value) async {
    if (value.isEmpty) return value;
    if (!value.startsWith(_encryptedMagic)) return value;

    try {
      final encrypted = value.substring(_encryptedMagic.length);
      final combined = base64Decode(encrypted);

      const nonceLength = 12;
      const macLength = 16;

      if (combined.length < nonceLength + macLength) {
        // Invalid data - return empty to avoid corruption
        return '';
      }

      final nonce = combined.sublist(0, nonceLength);
      final cipherText = combined.sublist(
        nonceLength,
        combined.length - macLength,
      );
      final macBytes = combined.sublist(combined.length - macLength);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final secretKey = SecretKey(_key);
      final plaintext = await _cipher.decrypt(secretBox, secretKey: secretKey);

      return utf8.decode(plaintext);
    } catch (e) {
      // On decryption failure, return empty to signal error
      AppLogger.error('LocalDataEncryption: Failed to decrypt string', e);
      return '';
    }
  }

  /// Encrypts binary data (for attachments).
  /// Returns encrypted bytes with header, or original if file encryption is disabled.
  Future<Uint8List> encryptBytes(Uint8List data) async {
    if (data.isEmpty) return data;
    if (!await isFilesEnabled()) return data;

    // Don't double-encrypt (check for header)
    if (_hasEncryptedHeader(data)) return data;

    try {
      final secretKey = SecretKey(_key);
      final nonce = _cipher.newNonce();
      final secretBox = await _cipher.encrypt(
        data,
        secretKey: secretKey,
        nonce: nonce,
      );

      // Format: [ENCR header (4)] + [nonce (12)] + [ciphertext] + [mac (16)]
      final result = Uint8List(
        4 + secretBox.nonce.length + secretBox.cipherText.length + 16,
      );
      result.setRange(0, 4, _encryptedFileHeader);
      result.setRange(4, 4 + secretBox.nonce.length, secretBox.nonce);
      result.setRange(
        4 + secretBox.nonce.length,
        4 + secretBox.nonce.length + secretBox.cipherText.length,
        secretBox.cipherText,
      );
      result.setRange(result.length - 16, result.length, secretBox.mac.bytes);

      return result;
    } catch (e) {
      // On encryption failure, return original to avoid data loss
      AppLogger.error('LocalDataEncryption: Failed to encrypt bytes', e);
      return data;
    }
  }

  /// Decrypts binary data (for attachments).
  /// Returns decrypted bytes, or original if not encrypted.
  Future<Uint8List> decryptBytes(Uint8List data) async {
    if (data.isEmpty) return data;
    if (!_hasEncryptedHeader(data)) return data;

    try {
      const headerLength = 4;
      const nonceLength = 12;
      const macLength = 16;

      if (data.length < headerLength + nonceLength + macLength) {
        // Invalid data
        return Uint8List(0);
      }

      final nonce = data.sublist(headerLength, headerLength + nonceLength);
      final cipherText = data.sublist(
        headerLength + nonceLength,
        data.length - macLength,
      );
      final macBytes = data.sublist(data.length - macLength);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final secretKey = SecretKey(_key);
      final plaintext = await _cipher.decrypt(secretBox, secretKey: secretKey);

      return Uint8List.fromList(plaintext);
    } catch (e) {
      // On decryption failure, return empty
      AppLogger.error('LocalDataEncryption: Failed to decrypt bytes', e);
      return Uint8List(0);
    }
  }

  /// Checks if data has the encrypted file header.
  static bool _hasEncryptedHeader(Uint8List data) {
    if (data.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _encryptedFileHeader[i]) return false;
    }
    return true;
  }

  /// Checks if a string value is encrypted.
  static bool isEncrypted(String value) {
    return value.startsWith(_encryptedMagic);
  }

  /// Checks if binary data is encrypted.
  static bool isBytesEncrypted(Uint8List data) {
    return _hasEncryptedHeader(data);
  }

  /// Migrates existing notes to encrypted format.
  /// Call this after enabling note encryption.
  /// Returns the number of notes that were encrypted.
  Future<int> migrateExistingNotes() async {
    if (!await isNotesEnabled()) return 0;

    // Import Note here to avoid circular dependency at module load
    // ignore: depend_on_referenced_packages
    final notes = await _getAllNotesForMigration();
    int migratedCount = 0;

    for (final noteData in notes) {
      final content = noteData['content'] as String?;
      final id = noteData['id'];

      // Skip if already encrypted or empty
      if (content == null || content.isEmpty || isEncrypted(content)) {
        continue;
      }

      // Encrypt and update
      final encryptedContent = await encryptString(content);
      await _updateNoteContent(id, encryptedContent);
      migratedCount++;
    }

    return migratedCount;
  }

  // Helper to get all notes without going through the model (avoids decryption)
  Future<List<Map<String, dynamic>>> _getAllNotesForMigration() async {
    // Dynamic import to avoid circular dependency
    final state = await _getAppState();
    if (state == null) return [];
    final db = state['db'];
    if (db == null) return [];
    return await (db as dynamic).query('note');
  }

  Future<void> _updateNoteContent(dynamic id, String encryptedContent) async {
    final state = await _getAppState();
    if (state == null) return;
    final db = state['db'];
    if (db == null) return;
    await (db as dynamic).update(
      'note',
      {'content': encryptedContent},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, dynamic>?> _getAppState() async {
    // This is a bit of a hack to access the database without circular imports
    // We use dynamic to avoid compile-time dependency on state.dart
    try {
      // ignore: avoid_dynamic_calls
      return {'db': (await _getDatabase())};
    } catch (_) {
      return null;
    }
  }

  // Will be set by the app during initialization
  static dynamic Function()? _databaseGetter;

  /// Sets the database getter for migration purposes.
  /// Call this during app initialization.
  static void setDatabaseGetter(dynamic Function() getter) {
    _databaseGetter = getter;
  }

  Future<dynamic> _getDatabase() async {
    if (_databaseGetter == null) {
      throw StateError(
        'Database getter not set. Call setDatabaseGetter first.',
      );
    }
    return _databaseGetter!();
  }
}
