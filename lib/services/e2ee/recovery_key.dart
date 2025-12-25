/// Recovery key system for E2EE.
///
/// Allows users to create a recovery passphrase that can restore
/// access to encrypted notes if all devices are lost.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// KDF algorithm used for key derivation
enum KdfAlgorithm {
  /// Argon2id - used on native platforms (mobile/desktop)
  argon2id,

  /// PBKDF2 with SHA-256 - used on web platform
  pbkdf2,
}

/// Recovery key data stored in Firestore.
class RecoveryKeyData {
  /// Encrypted UMK (base64-encoded ciphertext).
  final String encryptedUMK;

  /// Nonce for UMK encryption (base64-encoded).
  final String nonce;

  /// Salt used for key derivation (base64-encoded).
  final String salt;

  /// Hint for the recovery passphrase (optional).
  final String? hint;

  /// When the recovery key was created.
  final DateTime createdAt;

  /// KDF algorithm used (null for legacy keys - assume based on platform heuristic)
  final KdfAlgorithm? kdfAlgorithm;

  RecoveryKeyData({
    required this.encryptedUMK,
    required this.nonce,
    required this.salt,
    this.hint,
    required this.createdAt,
    this.kdfAlgorithm,
  });

  Map<String, dynamic> toFirestore() => {
    'encrypted_umk': encryptedUMK,
    'nonce': nonce,
    'salt': salt,
    if (hint != null) 'hint': hint,
    'created_at': createdAt.toIso8601String(),
    if (kdfAlgorithm != null) 'kdf_algorithm': kdfAlgorithm!.name,
  };

  factory RecoveryKeyData.fromFirestore(Map<String, dynamic> data) {
    KdfAlgorithm? algorithm;
    final kdfName = data['kdf_algorithm'] as String?;
    if (kdfName != null) {
      algorithm = KdfAlgorithm.values.firstWhere(
        (e) => e.name == kdfName,
        orElse: () => KdfAlgorithm.argon2id,
      );
    }

    return RecoveryKeyData(
      encryptedUMK: data['encrypted_umk'] as String,
      nonce: data['nonce'] as String,
      salt: data['salt'] as String,
      hint: data['hint'] as String?,
      createdAt: DateTime.parse(data['created_at'] as String),
      kdfAlgorithm: algorithm,
    );
  }
}

/// Service for managing recovery keys.
class RecoveryKeyService {
  static RecoveryKeyService? _instance;
  static RecoveryKeyService get instance {
    _instance ??= RecoveryKeyService._();
    return _instance!;
  }

  RecoveryKeyService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: DefaultFirebaseOptions.databaseId,
  );
  final DeviceManager _deviceManager = DeviceManager.instance;
  final E2EESecureStorage _secureStorage = E2EESecureStorage.instance;

  User? get _currentUser => AuthService.currentUser;

  DocumentReference<Map<String, dynamic>> get _userRef =>
      _firestore.collection('users').doc(_currentUser!.uid);

  DocumentReference<Map<String, dynamic>> get _recoveryKeyRef =>
      _userRef.collection('e2ee').doc('recovery_key');

  /// Checks if a recovery key has been set up.
  Future<bool> hasRecoveryKey() async {
    if (_currentUser == null) return false;
    final doc = await _recoveryKeyRef.get();
    return doc.exists;
  }

  /// Gets the recovery key hint (if set).
  Future<String?> getRecoveryKeyHint() async {
    if (_currentUser == null) return null;
    final doc = await _recoveryKeyRef.get();
    if (!doc.exists) return null;
    return doc.data()?['hint'] as String?;
  }

  /// Verifies a passphrase against the stored recovery key.
  /// Returns true if the passphrase is correct.
  Future<bool> verifyPassphrase(String passphrase) async {
    if (_currentUser == null) return false;

    final doc = await _recoveryKeyRef.get();
    if (!doc.exists) return false;

    final recoveryData = RecoveryKeyData.fromFirestore(doc.data()!);
    final salt = base64Decode(recoveryData.salt);

    // Try to derive and decrypt with the appropriate algorithm(s)
    final result = await _tryDecryptWithAlgorithms(
      passphrase,
      salt,
      recoveryData,
    );

    return result != null;
  }

  /// Attempts to decrypt UMK with the stored algorithm, or tries both for legacy keys.
  /// Returns the decrypted UMK bytes on success, null on failure.
  /// Throws UnsupportedError if Argon2id is needed on web.
  Future<Uint8List?> _tryDecryptWithAlgorithms(
    String passphrase,
    Uint8List salt,
    RecoveryKeyData recoveryData,
  ) async {
    if (recoveryData.kdfAlgorithm != null) {
      // New format - use the stored algorithm
      final kdfType = recoveryData.kdfAlgorithm == KdfAlgorithm.pbkdf2
          ? KdfType.pbkdf2
          : KdfType.argon2id;

      AppLogger.log('E2EE: Using stored KDF algorithm: $kdfType');

      final derivedKey = await KeyDerivation.deriveKeyWithKdf(
        passphrase,
        salt,
        kdfType,
      );

      try {
        final umkBase64 = await AuthenticatedCipher.decryptString(
          recoveryData.encryptedUMK,
          recoveryData.nonce,
          derivedKey,
        );
        return base64Decode(umkBase64);
      } catch (e) {
        AppLogger.log('E2EE: Decryption failed with $kdfType');
        return null;
      }
    }

    // Legacy key - try PBKDF2 first (works on all platforms), then Argon2id
    AppLogger.log('E2EE: Legacy key - trying PBKDF2 first');

    // Try PBKDF2
    try {
      final derivedKey = await KeyDerivation.deriveKeyWithKdf(
        passphrase,
        salt,
        KdfType.pbkdf2,
      );
      final umkBase64 = await AuthenticatedCipher.decryptString(
        recoveryData.encryptedUMK,
        recoveryData.nonce,
        derivedKey,
      );
      AppLogger.log('E2EE: PBKDF2 succeeded');
      return base64Decode(umkBase64);
    } catch (e) {
      AppLogger.log('E2EE: PBKDF2 failed, trying Argon2id');
    }

    // Try Argon2id (may throw UnsupportedError on web)
    final derivedKey = await KeyDerivation.deriveKeyWithKdf(
      passphrase,
      salt,
      KdfType.argon2id,
    );
    try {
      final umkBase64 = await AuthenticatedCipher.decryptString(
        recoveryData.encryptedUMK,
        recoveryData.nonce,
        derivedKey,
      );
      AppLogger.log('E2EE: Argon2id succeeded');
      return base64Decode(umkBase64);
    } catch (e) {
      AppLogger.log('E2EE: Argon2id also failed');
      return null;
    }
  }

  /// Creates a recovery key from a passphrase.
  ///
  /// The passphrase is used to derive a key that encrypts the UMK.
  /// The encrypted UMK is stored in Firestore with the KDF algorithm used.
  ///
  /// [passphrase] - User-chosen recovery passphrase (should be strong).
  /// [hint] - Optional hint to help user remember the passphrase.
  Future<void> createRecoveryKey(String passphrase, {String? hint}) async {
    if (_currentUser == null) throw StateError('User not logged in');

    final umk = _deviceManager.getUMK();
    if (umk == null) throw StateError('UMK not available');

    AppLogger.log('E2EE: Creating recovery key');

    // Generate salt for key derivation
    final salt = KeyDerivation.generateSalt();

    // Derive encryption key from passphrase using platform-appropriate KDF
    final derivedKey = await KeyDerivation.deriveKeyFromPassphrase(
      passphrase,
      salt,
    );

    // Encrypt UMK with derived key
    final encrypted = await AuthenticatedCipher.encryptString(
      base64Encode(umk),
      derivedKey,
    );

    // Determine which KDF algorithm is being used
    final kdfAlgorithm = KeyDerivation.currentPlatformKdf == KdfType.pbkdf2
        ? KdfAlgorithm.pbkdf2
        : KdfAlgorithm.argon2id;

    // Store in Firestore with KDF algorithm
    final recoveryData = RecoveryKeyData(
      encryptedUMK: encrypted.ciphertext,
      nonce: encrypted.nonce,
      salt: base64Encode(salt),
      hint: hint,
      createdAt: DateTime.now(),
      kdfAlgorithm: kdfAlgorithm,
    );

    await _recoveryKeyRef.set(recoveryData.toFirestore());

    AppLogger.log('E2EE: Recovery key created with $kdfAlgorithm');
  }

  /// Updates the recovery key with a new passphrase.
  ///
  /// [currentPassphrase] - The current passphrase (required for security).
  /// [newPassphrase] - The new passphrase to set.
  /// [hint] - Optional hint for the new passphrase.
  ///
  /// Throws if the current passphrase is incorrect.
  Future<void> updateRecoveryKey(
    String currentPassphrase,
    String newPassphrase, {
    String? hint,
  }) async {
    // Verify current passphrase first
    final isValid = await verifyPassphrase(currentPassphrase);
    if (!isValid) {
      throw StateError('Current passphrase is incorrect');
    }

    await createRecoveryKey(newPassphrase, hint: hint);
    AppLogger.log('E2EE: Recovery key updated');
  }

  /// Removes the recovery key.
  ///
  /// [currentPassphrase] - The current passphrase (required for security).
  ///
  /// Warning: This means the user cannot recover their notes if all devices are lost.
  Future<void> removeRecoveryKey(String currentPassphrase) async {
    if (_currentUser == null) throw StateError('User not logged in');

    // Verify current passphrase first
    final isValid = await verifyPassphrase(currentPassphrase);
    if (!isValid) {
      throw StateError('Current passphrase is incorrect');
    }

    await _recoveryKeyRef.delete();
    AppLogger.log('E2EE: Recovery key removed');
  }

  /// Recovers the UMK using the recovery passphrase.
  ///
  /// This is used when a user has lost all their devices and needs to
  /// restore access to their encrypted notes.
  ///
  /// Returns true if recovery was successful.
  /// Throws [UnsupportedError] if trying to recover Argon2id key on web.
  Future<bool> recoverWithPassphrase(
    String passphrase, {
    Function(String)? onStatusChange,
  }) async {
    if (_currentUser == null) throw StateError('User not logged in');

    AppLogger.log('E2EE: Attempting recovery with passphrase');
    onStatusChange?.call('Fetching recovery data...');

    // Get recovery key data
    final doc = await _recoveryKeyRef.get();
    if (!doc.exists) {
      AppLogger.log('E2EE: No recovery key found');
      return false;
    }

    final recoveryData = RecoveryKeyData.fromFirestore(doc.data()!);
    final salt = base64Decode(recoveryData.salt);

    try {
      onStatusChange?.call('Decrypting recovery key...');
      // Try to decrypt with the appropriate algorithm(s)
      final umk = await _tryDecryptWithAlgorithms(
        passphrase,
        salt,
        recoveryData,
      );

      if (umk == null) {
        AppLogger.log('E2EE: Decryption failed - incorrect passphrase');
        return false;
      }

      onStatusChange?.call('Registering device...');
      // Now we need to register this device with the recovered UMK
      await _registerDeviceWithRecoveredUMK(
        umk,
        onStatusChange: onStatusChange,
      );

      AppLogger.log('E2EE: Recovery successful');
      return true;
    } on UnsupportedError {
      // Re-throw UnsupportedError (e.g., Argon2id on web)
      rethrow;
    } catch (e, stack) {
      AppLogger.error('E2EE: Recovery failed', e, stack);
      return false;
    }
  }

  /// Registers a new device using a recovered UMK.
  Future<void> _registerDeviceWithRecoveredUMK(
    Uint8List umk, {
    Function(String)? onStatusChange,
  }) async {
    AppLogger.log('E2EE: Registering device with recovered UMK');
    onStatusChange?.call('Setting up encryption keys...');

    // Check if there's an existing pending device that needs to be cleaned up
    final existingDeviceId = await _secureStorage.getDeviceId();
    if (existingDeviceId != null) {
      try {
        // Delete the old pending device from Firestore
        await _userRef.collection('devices').doc(existingDeviceId).delete();
        AppLogger.log(
          'E2EE: Deleted existing pending device $existingDeviceId before recovery',
        );
      } catch (e) {
        // If deletion fails (e.g., device doesn't exist), just log and continue
        AppLogger.log(
          'E2EE: Could not delete existing device $existingDeviceId: $e',
        );
      }
      // Clear local storage for the old device
      await _secureStorage.clearAll();
    }

    onStatusChange?.call('Generating device keys...');
    // Generate device keypair
    final keyPair = await KeyExchange.generateKeyPair();

    // Generate device ID
    const uuid = Uuid();
    final deviceId = uuid.v4();

    // Wrap UMK for this device
    final sharedSecret = await KeyExchange.deriveSharedSecret(
      keyPair.privateKey,
      keyPair.publicKey,
    );
    final wrappedResult = await AuthenticatedCipher.encryptString(
      base64Encode(umk),
      sharedSecret,
    );

    // Get device name
    final deviceName = await DeviceInfo.getDeviceName();
    final platform = DeviceInfo.getCurrentPlatform();

    onStatusChange?.call('Saving device to cloud...');
    // Store device document in Firestore FIRST
    // This ensures we don't have local keys without a server record
    await _userRef.collection('devices').doc(deviceId).set({
      'name': deviceName,
      'platform': platform,
      'public_key': keyPair.publicKeyBase64,
      'wrapped_umk': wrappedResult.ciphertext,
      'wrapped_umk_nonce': wrappedResult.nonce,
      'status': DeviceStatus.approved.name,
      'created_at': DateTime.now().toIso8601String(),
      'approved_at': DateTime.now().toIso8601String(),
      'recovered': true, // Mark as recovered device
    });

    onStatusChange?.call('Saving encryption keys locally...');
    // Store device info locally AFTER Firestore write succeeds
    await _secureStorage.storeDevicePrivateKey(keyPair.privateKey);
    await _secureStorage.storeDevicePublicKey(keyPair.publicKey);
    await _secureStorage.storeDeviceId(deviceId);
    await _secureStorage.cacheUnwrappedUMK(umk);

    // Update device manager state - set both the cached UMK and the flag
    _deviceManager.setCachedUMK(umk);

    onStatusChange?.call('Completing setup...');
    // Start listening for status changes and pending approvals
    await _deviceManager.startListeningForCurrentDevice();

    AppLogger.log('E2EE: Device registered with recovered UMK');
  }

  /// Exports the recovery key data as a string for backup.
  ///
  /// This includes the encrypted UMK and salt, which the user can
  /// store securely offline. The passphrase is still required to decrypt.
  Future<String?> exportRecoveryData() async {
    if (_currentUser == null) return null;

    final doc = await _recoveryKeyRef.get();
    if (!doc.exists) return null;

    final data = doc.data()!;
    // Export as a JSON string that can be saved
    return json.encode({
      'version': 1,
      'encrypted_umk': data['encrypted_umk'],
      'nonce': data['nonce'],
      'salt': data['salt'],
      'created_at': data['created_at'],
    });
  }

  /// Imports recovery key data from an exported backup.
  ///
  /// Returns true if import was successful.
  Future<bool> importRecoveryData(String exportedData) async {
    if (_currentUser == null) throw StateError('User not logged in');

    try {
      final data = json.decode(exportedData) as Map<String, dynamic>;

      // Validate required fields
      if (!data.containsKey('encrypted_umk') ||
          !data.containsKey('nonce') ||
          !data.containsKey('salt')) {
        AppLogger.log('E2EE: Invalid recovery data format');
        return false;
      }

      // Store in Firestore
      await _recoveryKeyRef.set({
        'encrypted_umk': data['encrypted_umk'],
        'nonce': data['nonce'],
        'salt': data['salt'],
        'created_at': data['created_at'] ?? DateTime.now().toIso8601String(),
        'imported': true,
      });

      AppLogger.log('E2EE: Recovery data imported');
      return true;
    } catch (e, stack) {
      AppLogger.error('E2EE: Failed to import recovery data', e, stack);
      return false;
    }
  }
}

/// UUID generator (using the uuid package).
class Uuid {
  const Uuid();

  String v4() {
    // Generate a v4 UUID
    final random = SecureRandom.instance;
    final bytes = random.nextBytes(16);

    // Set version to 4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant to RFC4122
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
