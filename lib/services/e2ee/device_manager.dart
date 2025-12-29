/// Device management for E2EE multi-device support.
///
/// Handles device registration, UMK wrapping/unwrapping, and device approval.
library;

import 'dart:async';
import 'dart:convert';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Device status in the E2EE system.
enum DeviceStatus {
  /// Device is pending approval from another device
  pending,

  /// Device is approved and has access to UMK
  approved,

  /// Device has been revoked and can no longer access notes
  revoked,
}

/// Device document stored in Firestore.
class DeviceDocument {
  final String id;
  final String name;
  final String platform;
  final String publicKey;
  final String? wrappedUMK;
  final String? wrappedUMKNonce;
  final DeviceStatus status;
  final DateTime createdAt;
  final DateTime? approvedAt;
  final DateTime? revokedAt;
  // Device identification info
  final Map<String, String?>? deviceDetails;

  DeviceDocument({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    this.wrappedUMK,
    this.wrappedUMKNonce,
    required this.status,
    required this.createdAt,
    this.approvedAt,
    this.revokedAt,
    this.deviceDetails,
  });

  bool get isApproved => status == DeviceStatus.approved;
  bool get isPending => status == DeviceStatus.pending;
  bool get isRevoked => status == DeviceStatus.revoked;
  bool get hasWrappedUMK => wrappedUMK != null && wrappedUMKNonce != null;

  /// Gets the manufacturer from device details.
  String? get manufacturer => deviceDetails?['manufacturer'];

  /// Gets the model from device details.
  String? get model => deviceDetails?['model'];

  /// Gets the OS version from device details.
  String? get osVersion => deviceDetails?['os_version'];

  /// Gets a formatted device description.
  String get deviceDescription {
    final parts = <String>[];
    if (manufacturer != null && manufacturer!.isNotEmpty) {
      parts.add(manufacturer!);
    }
    if (model != null && model!.isNotEmpty) {
      parts.add(model!);
    }
    if (parts.isEmpty) {
      return name;
    }
    return parts.join(' ');
  }

  factory DeviceDocument.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    // Parse device_details map if it exists
    Map<String, String?>? details;
    if (data['device_details'] != null) {
      final rawDetails = data['device_details'] as Map<String, dynamic>;
      details = rawDetails.map(
        (key, value) => MapEntry(key, value?.toString()),
      );
    }
    return DeviceDocument(
      id: doc.id,
      name: data['name'] as String? ?? 'Unknown Device',
      platform: data['platform'] as String? ?? 'unknown',
      publicKey: data['public_key'] as String,
      wrappedUMK: data['wrapped_umk'] as String?,
      wrappedUMKNonce: data['wrapped_umk_nonce'] as String?,
      status: DeviceStatus.values.firstWhere(
        (s) => s.name == (data['status'] as String? ?? 'pending'),
        orElse: () => DeviceStatus.pending,
      ),
      createdAt: DateTime.parse(data['created_at'] as String),
      approvedAt: data['approved_at'] != null
          ? DateTime.parse(data['approved_at'] as String)
          : null,
      revokedAt: data['revoked_at'] != null
          ? DateTime.parse(data['revoked_at'] as String)
          : null,
      deviceDetails: details,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'name': name,
    'platform': platform,
    'public_key': publicKey,
    if (wrappedUMK != null) 'wrapped_umk': wrappedUMK,
    if (wrappedUMKNonce != null) 'wrapped_umk_nonce': wrappedUMKNonce,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (approvedAt != null) 'approved_at': approvedAt!.toIso8601String(),
    if (revokedAt != null) 'revoked_at': revokedAt!.toIso8601String(),
    if (deviceDetails != null) 'device_details': deviceDetails,
  };
}

/// Pending device approval request.
class DeviceApprovalRequest {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String publicKey;
  final DateTime requestedAt;

  DeviceApprovalRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.publicKey,
    required this.requestedAt,
  });

  factory DeviceApprovalRequest.fromDocument(DeviceDocument doc) {
    return DeviceApprovalRequest(
      deviceId: doc.id,
      deviceName: doc.name,
      platform: doc.platform,
      publicKey: doc.publicKey,
      requestedAt: doc.createdAt,
    );
  }
}

/// Manages device registration, approval, and UMK distribution.
class DeviceManager {
  static DeviceManager? _instance;
  static DeviceManager get instance {
    _instance ??= DeviceManager._();
    return _instance!;
  }

  DeviceManager._();
  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: DefaultFirebaseOptions.databaseId,
  );

  final E2EESecureStorage _secureStorage = E2EESecureStorage.instance;
  final Uuid _uuid = const Uuid();

  /// Stream subscriptions for cleanup
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _currentDeviceStatusSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _approvalSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _pendingApprovalsSubscription;

  /// In-memory cache of unwrapped UMK.
  Uint8List? _cachedUMK;

  /// Notifier for UMK availability.
  final ValueNotifier<bool> hasUMK = ValueNotifier(false);

  /// Notifier for pending approval requests (for existing devices).
  final ValueNotifier<List<DeviceApprovalRequest>> pendingApprovals =
      ValueNotifier([]);

  User? get _currentUser => AuthService.currentUser;

  DocumentReference<Map<String, dynamic>> get _userRef =>
      _firestore.collection('users').doc(_currentUser!.uid);

  CollectionReference<Map<String, dynamic>> get _devicesCollection =>
      _userRef.collection('devices');

  /// Initializes the device manager.
  ///
  /// Should be called after user login.
  Future<void> init() async {
    if (_currentUser == null) return;

    // Try to load cached UMK
    final cachedUMK = await _secureStorage.getCachedUMK();
    if (cachedUMK != null) {
      _cachedUMK = cachedUMK;
      hasUMK.value = true;
    }

    // Check if this device is registered
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) {
      // New device - needs registration
      AppLogger.log('E2EE: Device not registered');
      return;
    }

    // Check device status
    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) {
      // Device was removed from server - need to re-register
      await _secureStorage.clearAll();
      AppLogger.log('E2EE: Device removed from server, cleared local keys');
      return;
    }

    final device = DeviceDocument.fromFirestore(deviceDoc);

    if (device.isRevoked) {
      // Device was revoked - clear UMK but keep device ID for status detection
      await _secureStorage.clearCachedUMK();
      _cachedUMK = null;
      hasUMK.value = false;
      AppLogger.log('E2EE: Device was revoked, cleared UMK cache');
      return;
    }

    if (device.isApproved && device.hasWrappedUMK && _cachedUMK == null) {
      // Try to unwrap UMK
      await _unwrapAndCacheUMK(device);
    }

    // Start listening for pending approvals (if this device is approved)
    if (device.isApproved) {
      _listenForPendingApprovals();
      // Also listen for revocation of this device
      _listenForCurrentDeviceStatus(deviceId);
    }
  }

  /// Listens for status changes on the current device (revocation, deletion).
  void _listenForCurrentDeviceStatus(String deviceId) {
    _currentDeviceStatusSubscription?.cancel();
    _currentDeviceStatusSubscription = _devicesCollection
        .doc(deviceId)
        .snapshots()
        .listen((snapshot) async {
          if (!snapshot.exists) {
            // Device was deleted
            AppLogger.log('E2EE: Current device was deleted');
            await _secureStorage.clearCachedUMK();
            _cachedUMK = null;
            hasUMK.value = false;
            _notifyRevoked();
            return;
          }

          final device = DeviceDocument.fromFirestore(snapshot);

          if (device.isRevoked) {
            AppLogger.log('E2EE: Current device was revoked');
            await _secureStorage.clearCachedUMK();
            _cachedUMK = null;
            hasUMK.value = false;
            _notifyRevoked();
          }
        });
  }

  /// Starts listening for status changes and pending approvals for the current device.
  /// Call this after recovery to ensure the device is properly monitored.
  Future<void> startListeningForCurrentDevice() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) {
      AppLogger.log('E2EE: Cannot start listening - no device ID stored');
      return;
    }

    AppLogger.log('E2EE: Starting listeners for current device');
    _listenForCurrentDeviceStatus(deviceId);
    _listenForPendingApprovals();
  }

  /// Checks if this is the first device for the user (no E2EE set up yet).
  Future<bool> isFirstDevice() async {
    if (_currentUser == null) return false;

    final devicesSnapshot = await _devicesCollection.get();
    return devicesSnapshot.docs.isEmpty;
  }

  /// Checks if there are any approved devices for the user.
  /// Returns false if all devices are revoked/pending or there are no devices.
  Future<bool> hasApprovedDevices() async {
    if (_currentUser == null) return false;

    final devicesSnapshot = await _devicesCollection.get();
    if (devicesSnapshot.docs.isEmpty) return false;

    final devices = devicesSnapshot.docs
        .map((doc) => DeviceDocument.fromFirestore(doc))
        .where((d) => d.isApproved)
        .toList();

    return devices.isNotEmpty;
  }

  /// Gets the primary (master) device - the first approved device by creation date.
  /// Returns null if no approved devices exist.
  Future<DeviceDocument?> getPrimaryDevice() async {
    if (_currentUser == null) return null;

    final devicesSnapshot = await _devicesCollection.get();
    if (devicesSnapshot.docs.isEmpty) return null;

    final approvedDevices = devicesSnapshot.docs
        .map((doc) => DeviceDocument.fromFirestore(doc))
        .where((d) => d.isApproved)
        .toList();

    if (approvedDevices.isEmpty) return null;

    // Sort by creation date, first one is the primary
    approvedDevices.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return approvedDevices.first;
  }

  /// Checks if the current device name matches the primary device name.
  ///
  /// This helps detect if the user is logging in from the same physical device
  /// after logout/uninstall/clear data. If true, we should offer recovery
  /// instead of requiring approval from another device.
  Future<bool> currentDeviceMatchesPrimaryName() async {
    if (_currentUser == null) return false;

    // Get the current device name
    final currentDeviceName = await DeviceInfo.getDeviceName();

    // Get the primary device
    final primaryDevice = await getPrimaryDevice();
    if (primaryDevice == null) return false;

    AppLogger.log(
      'E2EE: Comparing device names - Current: "$currentDeviceName", Primary: "${primaryDevice.name}"',
    );

    // Compare device names (case-insensitive)
    return currentDeviceName.toLowerCase() == primaryDevice.name.toLowerCase();
  }

  /// Checks if the current device is registered and approved.
  Future<bool> isDeviceApproved() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) return false;

    final device = DeviceDocument.fromFirestore(deviceDoc);
    return device.isApproved;
  }

  /// Tries to retrieve and cache the UMK if the device is approved.
  /// Returns true if UMK was successfully retrieved or already cached.
  Future<bool> tryRetrieveUMK() async {
    // Already have UMK cached
    if (_cachedUMK != null) return true;

    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) return false;

    final device = DeviceDocument.fromFirestore(deviceDoc);

    if (device.isApproved && device.hasWrappedUMK) {
      try {
        await _unwrapAndCacheUMK(device);
        return true;
      } catch (e) {
        AppLogger.error('E2EE: Failed to retrieve UMK', e);
        return false;
      }
    }

    return false;
  }

  /// Checks if the current device is pending approval.
  Future<bool> isDevicePending() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) return false;

    final device = DeviceDocument.fromFirestore(deviceDoc);
    return device.isPending;
  }

  /// Checks if the current device is revoked.
  Future<bool> isDeviceRevoked() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) return false;

    final device = DeviceDocument.fromFirestore(deviceDoc);
    return device.isRevoked;
  }

  /// Checks if the current device exists on the server.
  Future<bool> deviceExistsOnServer() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    return deviceDoc.exists;
  }

  /// Checks current device authorization status and triggers revocation if needed.
  /// Returns true if device is still authorized, false if revoked/removed.
  Future<bool> checkCurrentDeviceAuthorization() async {
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    try {
      final deviceDoc = await _devicesCollection.doc(deviceId).get();

      if (!deviceDoc.exists) {
        // Device was removed from server
        AppLogger.log('E2EE: Device removed from server during refresh');
        _notifyRevoked();
        return false;
      }

      final device = DeviceDocument.fromFirestore(deviceDoc);

      if (device.isRevoked) {
        // Device was revoked
        AppLogger.log('E2EE: Device revoked detected during refresh');
        await _secureStorage.clearCachedUMK();
        _cachedUMK = null;
        hasUMK.value = false;
        _notifyRevoked();
        return false;
      }

      return device.isApproved;
    } catch (e) {
      AppLogger.error('E2EE: Error checking device authorization', e);
      // Don't trigger revocation on network errors
      return true;
    }
  }

  /// Checks if the current device is the master device (first approved device).
  /// Only the master device can approve other devices.
  Future<bool> isMasterDevice() async {
    if (_currentUser == null) return false;

    final currentDeviceId = await _secureStorage.getDeviceId();
    if (currentDeviceId == null) return false;

    final devicesSnapshot = await _devicesCollection.get();
    if (devicesSnapshot.docs.isEmpty) return true; // First device is master

    final devices = devicesSnapshot.docs
        .map((doc) => DeviceDocument.fromFirestore(doc))
        .where((d) => d.isApproved)
        .toList();

    if (devices.isEmpty) return true; // No approved devices yet

    // Sort by approval date, first approved device is the master
    // This ensures devices approved via device approval don't become master
    // (only first device or recovery with 'set as primary' should be master)
    devices.sort((a, b) {
      final aApproved = a.approvedAt ?? a.createdAt;
      final bApproved = b.approvedAt ?? b.createdAt;
      return aApproved.compareTo(bApproved);
    });
    return devices.first.id == currentDeviceId;
  }

  /// Clears all local E2EE data (for fresh start).
  Future<void> clearLocalData() async {
    await _secureStorage.clearAll();
    _cachedUMK = null;
    hasUMK.value = false;
    wasRevoked.value = false;
    AppLogger.log('E2EE: Cleared all local E2EE data');
  }

  /// Clears all devices from Firestore for fresh start.
  ///
  /// This removes all device registrations, allowing user to start fresh.
  /// Old encrypted notes remain orphaned but are not deleted (in case user
  /// remembers their recovery passphrase later).
  Future<void> clearAllDevices() async {
    if (_currentUser == null) throw StateError('User not logged in');

    AppLogger.log('E2EE: Clearing all devices for fresh start');

    final devicesSnapshot = await _devicesCollection.get();
    for (final doc in devicesSnapshot.docs) {
      await doc.reference.delete();
    }

    AppLogger.log('E2EE: Cleared ${devicesSnapshot.docs.length} devices');
  }

  /// Registers the first device and creates the UMK.
  ///
  /// This should only be called when setting up E2EE for the first time.
  Future<void> registerFirstDevice() async {
    if (_currentUser == null) throw StateError('User not logged in');

    AppLogger.log('E2EE: Registering first device');

    // Generate device keypair
    final keyPair = await KeyExchange.generateKeyPair();

    // Generate device ID
    final deviceId = _uuid.v4();

    // Generate UMK
    final umk = generateUserMasterKey();

    // Wrap UMK for this device (encrypt UMK with a key derived from device's own keypair)
    // For the first device, we use a simple approach: encrypt UMK with a key derived from the private key
    final wrappedResult = await _wrapUMKForDevice(
      umk,
      keyPair.publicKey,
      keyPair.privateKey,
    );

    // Get device name and details
    final deviceName = await DeviceInfo.getDeviceName();
    final platform = DeviceInfo.getCurrentPlatform();
    final deviceDetails = await DeviceInfo.getDeviceDetails();

    // Store device document in Firestore FIRST
    // This ensures we don't have local keys without a server record
    await _devicesCollection.doc(deviceId).set({
      'name': deviceName,
      'platform': platform,
      'public_key': keyPair.publicKeyBase64,
      'wrapped_umk': wrappedResult.ciphertext,
      'wrapped_umk_nonce': wrappedResult.nonce,
      'status': DeviceStatus.approved.name,
      'created_at': DateTime.now().toIso8601String(),
      'approved_at': DateTime.now().toIso8601String(),
      'device_details': deviceDetails,
    });

    // Store device info locally AFTER Firestore write succeeds
    await _secureStorage.storeDevicePrivateKey(keyPair.privateKey);
    await _secureStorage.storeDevicePublicKey(keyPair.publicKey);
    await _secureStorage.storeDeviceId(deviceId);
    await _secureStorage.cacheUnwrappedUMK(umk);

    _cachedUMK = umk;
    hasUMK.value = true;

    AppLogger.log('E2EE: First device registered successfully');

    // Start listening for pending approvals
    _listenForPendingApprovals();
  }

  /// Registers a new device and requests approval from an existing device.
  ///
  /// The device will be in pending state until approved by another device.
  Future<void> registerNewDevice() async {
    if (_currentUser == null) throw StateError('User not logged in');

    // Check if this device already has a stored ID
    final existingDeviceId = await _secureStorage.getDeviceId();
    if (existingDeviceId != null) {
      // Check if this device already exists on server
      final existingDoc = await _devicesCollection.doc(existingDeviceId).get();
      if (existingDoc.exists) {
        final existingDevice = DeviceDocument.fromFirestore(existingDoc);
        if (existingDevice.isPending) {
          // Already registered and pending - just listen for approval
          AppLogger.log(
            'E2EE: Device already registered as pending, listening for approval',
          );
          _listenForApproval(existingDeviceId);
          return;
        }
        // Device exists but not pending - this shouldn't happen in normal flow
        AppLogger.log(
          'E2EE: Device exists with status ${existingDevice.status.name}',
        );
      }
    }

    // Get device name to check for existing pending devices with same name
    final deviceName = await DeviceInfo.getDeviceName();
    final platform = DeviceInfo.getCurrentPlatform();

    // Check if there's already a pending device with the same name and platform
    // This handles the case where user refreshed/cancelled before local storage was written
    // Query by name only and filter in code to avoid needing a composite index
    try {
      final existingDevicesQuery = await _devicesCollection
          .where('name', isEqualTo: deviceName)
          .get();

      // Filter for pending devices with same platform
      final existingPending = existingDevicesQuery.docs.where((doc) {
        final data = doc.data();
        return data['status'] == DeviceStatus.pending.name &&
            data['platform'] == platform;
      }).toList();

      if (existingPending.isNotEmpty) {
        // Found existing pending device with same name - reuse it
        final existingPendingDoc = existingPending.first;
        final existingPendingId = existingPendingDoc.id;
        AppLogger.log(
          'E2EE: Found existing pending device with same name, reusing: $existingPendingId',
        );

        // We need to update the device with new keys since we don't have the old private key
        final keyPair = await KeyExchange.generateKeyPair();

        // Update the device document with new public key
        await _devicesCollection.doc(existingPendingId).update({
          'public_key': keyPair.publicKeyBase64,
          'created_at': DateTime.now().toIso8601String(),
          'device_details': await DeviceInfo.getDeviceDetails(),
        });

        // Store device info locally
        await _secureStorage.storeDevicePrivateKey(keyPair.privateKey);
        await _secureStorage.storeDevicePublicKey(keyPair.publicKey);
        await _secureStorage.storeDeviceId(existingPendingId);

        AppLogger.log(
          'E2EE: Reusing existing pending device, waiting for approval',
        );
        _listenForApproval(existingPendingId);
        return;
      }
    } catch (e) {
      AppLogger.log('E2EE: Error checking for existing pending devices: $e');
      // Continue with creating a new device
    }

    AppLogger.log('E2EE: Registering new device (pending approval)');

    // Generate device keypair
    final keyPair = await KeyExchange.generateKeyPair();

    // Generate device ID
    final deviceId = _uuid.v4();

    // Get device details
    final deviceDetails = await DeviceInfo.getDeviceDetails();

    // Store device document in Firestore FIRST (pending status, no wrapped UMK)
    // This ensures we don't have local keys without a server record
    await _devicesCollection.doc(deviceId).set({
      'name': deviceName,
      'platform': platform,
      'public_key': keyPair.publicKeyBase64,
      'status': DeviceStatus.pending.name,
      'created_at': DateTime.now().toIso8601String(),
      'device_details': deviceDetails,
    });

    // Store device info locally AFTER Firestore write succeeds
    await _secureStorage.storeDevicePrivateKey(keyPair.privateKey);
    await _secureStorage.storeDevicePublicKey(keyPair.publicKey);
    await _secureStorage.storeDeviceId(deviceId);

    AppLogger.log('E2EE: New device registered, waiting for approval');

    // Start listening for approval
    _listenForApproval(deviceId);
  }

  /// Approves a pending device from an existing approved device.
  ///
  /// This wraps the UMK for the new device using ECDH key exchange.
  Future<void> approveDevice(String pendingDeviceId) async {
    if (_cachedUMK == null) {
      throw StateError('Cannot approve device: UMK not available');
    }

    AppLogger.log('E2EE: Approving device $pendingDeviceId');

    // Get pending device's public key
    final pendingDeviceDoc = await _devicesCollection
        .doc(pendingDeviceId)
        .get();
    if (!pendingDeviceDoc.exists) {
      throw StateError('Device not found');
    }

    final pendingDevice = DeviceDocument.fromFirestore(pendingDeviceDoc);
    if (!pendingDevice.isPending) {
      throw StateError('Device is not pending approval');
    }

    // Get our private key for ECDH
    final ourPrivateKey = await _secureStorage.getDevicePrivateKey();
    if (ourPrivateKey == null) {
      throw StateError('Local private key not found');
    }

    // Derive shared secret using ECDH
    final theirPublicKey = base64Decode(pendingDevice.publicKey);
    final sharedSecret = await KeyExchange.deriveSharedSecret(
      ourPrivateKey,
      theirPublicKey,
    );

    // Wrap UMK with shared secret
    final wrappedResult = await AuthenticatedCipher.encryptString(
      base64Encode(_cachedUMK!),
      sharedSecret,
    );

    // Update the pending device with wrapped UMK
    await _devicesCollection.doc(pendingDeviceId).update({
      'wrapped_umk': wrappedResult.ciphertext,
      'wrapped_umk_nonce': wrappedResult.nonce,
      'status': DeviceStatus.approved.name,
      'approved_at': DateTime.now().toIso8601String(),
      // Store our public key so the new device can derive the same shared secret
      'approved_by_public_key': base64Encode(
        await _secureStorage.getDevicePublicKey() ?? Uint8List(0),
      ),
    });

    AppLogger.log('E2EE: Device $pendingDeviceId approved');

    // Refresh pending approvals list
    await _refreshPendingApprovals();
  }

  /// Revokes a device by deleting it from Firebase.
  /// This prevents the device from accessing notes and removes it from the collection.
  Future<void> revokeDevice(String deviceId) async {
    final currentDeviceId = await _secureStorage.getDeviceId();
    if (deviceId == currentDeviceId) {
      throw StateError('Cannot revoke current device');
    }

    AppLogger.log('E2EE: Revoking and deleting device $deviceId');

    await _devicesCollection.doc(deviceId).delete();

    AppLogger.log('E2EE: Device $deviceId revoked and deleted');
  }

  /// Resets a device to pending status, requiring re-approval.
  ///
  /// This removes the wrapped UMK but keeps the device registered.
  /// The device will need to be approved again to access notes.
  Future<void> resetDeviceToPending(String deviceId) async {
    final currentDeviceId = await _secureStorage.getDeviceId();
    if (deviceId == currentDeviceId) {
      throw StateError('Cannot reset current device to pending');
    }

    AppLogger.log('E2EE: Resetting device $deviceId to pending');

    await _devicesCollection.doc(deviceId).update({
      'status': DeviceStatus.pending.name,
      'wrapped_umk': FieldValue.delete(),
      'wrapped_umk_nonce': FieldValue.delete(),
      'approved_at': FieldValue.delete(),
      'approved_by_public_key': FieldValue.delete(),
      'revoked_at': FieldValue.delete(),
    });

    AppLogger.log('E2EE: Device $deviceId reset to pending');

    // Refresh pending approvals list
    await _refreshPendingApprovals();
  }

  /// Requests re-approval for the current device (after being revoked).
  ///
  /// This resets the current device to pending status so it can be
  /// approved again by the master device. If no device ID exists locally,
  /// a new device registration is created.
  Future<void> requestReapproval() async {
    final deviceId = await _secureStorage.getDeviceId();

    // Clear local UMK cache since we need a new one
    await _secureStorage.clearCachedUMK();
    _cachedUMK = null;
    hasUMK.value = false;

    if (deviceId == null) {
      // No device ID found - register as a new device instead
      AppLogger.log(
        'E2EE: No device ID found, registering as new device for re-approval',
      );
      await registerNewDevice();
      return;
    }

    // Check if the device still exists on the server
    final deviceDoc = await _devicesCollection.doc(deviceId).get();
    if (!deviceDoc.exists) {
      // Device was deleted from server - register as a new device
      AppLogger.log(
        'E2EE: Device not found on server, registering as new device for re-approval',
      );
      await _secureStorage.clearAll();
      await registerNewDevice();
      return;
    }

    AppLogger.log('E2EE: Requesting re-approval for current device');

    // Reset device to pending status in Firestore
    await _devicesCollection.doc(deviceId).update({
      'status': DeviceStatus.pending.name,
      'wrapped_umk': FieldValue.delete(),
      'wrapped_umk_nonce': FieldValue.delete(),
      'approved_at': FieldValue.delete(),
      'approved_by_public_key': FieldValue.delete(),
      'revoked_at': FieldValue.delete(),
    });

    AppLogger.log('E2EE: Re-approval request sent');

    // Start listening for approval again
    _listenForApproval(deviceId);
  }

  /// Gets all registered devices for the current user.
  Future<List<DeviceDocument>> getDevices() async {
    final snapshot = await _devicesCollection.get();
    final currentDeviceId = await _secureStorage.getDeviceId();

    return snapshot.docs
        .map((doc) => DeviceDocument.fromFirestore(doc))
        .toList()
      ..sort((a, b) {
        // Current device first, then by creation date
        if (a.id == currentDeviceId) return -1;
        if (b.id == currentDeviceId) return 1;
        return b.createdAt.compareTo(a.createdAt);
      });
  }

  /// Gets the unwrapped UMK for encrypting/decrypting notes.
  Uint8List? getUMK() => _cachedUMK;

  /// Sets the cached UMK (used during recovery).
  /// This should only be called when a UMK has been recovered and stored.
  void setCachedUMK(Uint8List umk) {
    _cachedUMK = umk;
    hasUMK.value = true;
  }

  /// Clears the cached UMK (e.g., on logout).
  Future<void> clearUMK() async {
    _cachedUMK = null;
    hasUMK.value = false;
    await _secureStorage.clearCachedUMK();
  }

  /// Deletes the current device from Firestore.
  /// This should be called during logout to remove the device from the user's devices collection.
  Future<void> deleteCurrentDevice() async {
    if (_currentUser == null) {
      AppLogger.log('E2EE: No user logged in, skipping device deletion');
      return;
    }

    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) {
      AppLogger.log('E2EE: No device ID found, skipping device deletion');
      return;
    }

    try {
      AppLogger.log('E2EE: Deleting current device $deviceId from Firestore');
      await _devicesCollection.doc(deviceId).delete();
      AppLogger.log('E2EE: Device $deviceId deleted successfully');
    } catch (e) {
      AppLogger.error('E2EE: Error deleting device $deviceId', e);
      // Don't rethrow - we still want logout to proceed even if device deletion fails
    }
  }

  /// Disposes of all subscriptions and resources.
  /// Call this when the service is no longer needed.
  Future<void> dispose() async {
    await _currentDeviceStatusSubscription?.cancel();
    await _approvalSubscription?.cancel();
    await _pendingApprovalsSubscription?.cancel();
    _currentDeviceStatusSubscription = null;
    _approvalSubscription = null;
    _pendingApprovalsSubscription = null;
  }

  /// Wraps UMK for a device using its public key.
  Future<CipherResultString> _wrapUMKForDevice(
    Uint8List umk,
    Uint8List devicePublicKey,
    Uint8List devicePrivateKey,
  ) async {
    // Derive a key from the device's own keypair (self-encryption)
    final sharedSecret = await KeyExchange.deriveSharedSecret(
      devicePrivateKey,
      devicePublicKey,
    );

    return await AuthenticatedCipher.encryptString(
      base64Encode(umk),
      sharedSecret,
    );
  }

  /// Unwraps and caches the UMK from a device document.
  Future<void> _unwrapAndCacheUMK(DeviceDocument device) async {
    if (!device.hasWrappedUMK) {
      throw StateError('Device does not have wrapped UMK');
    }

    final privateKey = await _secureStorage.getDevicePrivateKey();
    if (privateKey == null) {
      throw StateError('Local private key not found');
    }

    Uint8List sharedSecret;

    // Check if this was approved by another device or is self-encrypted
    final deviceDoc = await _devicesCollection.doc(device.id).get();
    final approvedByPublicKey =
        deviceDoc.data()?['approved_by_public_key'] as String?;

    if (approvedByPublicKey != null && approvedByPublicKey.isNotEmpty) {
      // Approved by another device - use ECDH with approver's public key
      sharedSecret = await KeyExchange.deriveSharedSecret(
        privateKey,
        base64Decode(approvedByPublicKey),
      );
    } else {
      // Self-encrypted (first device) - use own public key
      final publicKey = await _secureStorage.getDevicePublicKey();
      if (publicKey == null) {
        throw StateError('Local public key not found');
      }
      sharedSecret = await KeyExchange.deriveSharedSecret(
        privateKey,
        publicKey,
      );
    }

    // Decrypt wrapped UMK
    final umkBase64 = await AuthenticatedCipher.decryptString(
      device.wrappedUMK!,
      device.wrappedUMKNonce!,
      sharedSecret,
    );

    final umk = base64Decode(umkBase64);

    // Cache the unwrapped UMK
    await _secureStorage.cacheUnwrappedUMK(umk);
    _cachedUMK = umk;
    hasUMK.value = true;

    AppLogger.log('E2EE: UMK unwrapped and cached');
  }

  /// Listens for approval of the current device.
  void _listenForApproval(String deviceId) {
    _approvalSubscription?.cancel();
    _approvalSubscription = _devicesCollection.doc(deviceId).snapshots().listen((
      snapshot,
    ) async {
      if (!snapshot.exists) {
        // Device was deleted (denied) - treat as revoked
        AppLogger.log('E2EE: Device was deleted/denied');
        await _secureStorage.clearAll();
        _cachedUMK = null;
        hasUMK.value = false;
        // Notify that device was revoked
        _notifyRevoked();
        return;
      }

      final device = DeviceDocument.fromFirestore(snapshot);

      if (device.isApproved && device.hasWrappedUMK) {
        AppLogger.log('E2EE: Device approved, unwrapping UMK');
        await _unwrapAndCacheUMK(device);

        // Start listening for pending approvals now that we're approved
        _listenForPendingApprovals();
      } else if (device.isRevoked) {
        AppLogger.log('E2EE: Device was revoked');
        // Only clear UMK, keep device ID for revoked status detection on refresh
        await _secureStorage.clearCachedUMK();
        _cachedUMK = null;
        hasUMK.value = false;
        // Notify that device was revoked
        _notifyRevoked();
      }
    });
  }

  /// Notifier for when the device is revoked or deleted.
  final ValueNotifier<bool> wasRevoked = ValueNotifier(false);

  void _notifyRevoked() {
    wasRevoked.value = true;
  }

  /// Sets the revoked flag (call when device is detected as revoked).
  void setRevokedFlag() {
    wasRevoked.value = true;
  }

  /// Resets the revoked flag (call after handling revocation).
  void clearRevokedFlag() {
    wasRevoked.value = false;
  }

  /// Listens for pending approval requests from other devices.
  void _listenForPendingApprovals() {
    _pendingApprovalsSubscription?.cancel();
    _pendingApprovalsSubscription = _devicesCollection
        .where('status', isEqualTo: DeviceStatus.pending.name)
        .snapshots()
        .listen((snapshot) {
          final requests = snapshot.docs
              .map((doc) => DeviceDocument.fromFirestore(doc))
              .map((doc) => DeviceApprovalRequest.fromDocument(doc))
              .toList();

          pendingApprovals.value = requests;
        });
  }

  /// Refreshes the pending approvals list.
  Future<void> _refreshPendingApprovals() async {
    final snapshot = await _devicesCollection
        .where('status', isEqualTo: DeviceStatus.pending.name)
        .get();

    final requests = snapshot.docs
        .map((doc) => DeviceDocument.fromFirestore(doc))
        .map((doc) => DeviceApprovalRequest.fromDocument(doc))
        .toList();

    pendingApprovals.value = requests;
  }

  /// Sets the current device as the primary (master) device.
  ///
  /// This revokes all other approved devices and deletes all pending devices,
  /// making the current device the only approved device and thus the master.
  /// Uses batch writes for better performance and atomicity.
  Future<void> setCurrentDeviceAsPrimary() async {
    if (_currentUser == null) throw StateError('User not logged in');

    final currentDeviceId = await _secureStorage.getDeviceId();
    if (currentDeviceId == null) {
      throw StateError('Current device not registered');
    }

    AppLogger.log('E2EE: Setting current device as primary');

    // Get all other devices
    final devicesSnapshot = await _devicesCollection.get();
    final allOtherDevices = devicesSnapshot.docs
        .where((doc) => doc.id != currentDeviceId)
        .toList();

    if (allOtherDevices.isEmpty) {
      AppLogger.log('E2EE: No other devices to revoke/delete');
      return;
    }

    // Use a batch write for better performance and atomicity
    // Important: Use _firestore.batch() not FirebaseFirestore.instance.batch()
    // because we're using a custom database ID
    final batch = _firestore.batch();
    var revokedCount = 0;
    var deletedCount = 0;

    for (final doc in allOtherDevices) {
      final device = DeviceDocument.fromFirestore(doc);
      if (device.isApproved) {
        // Use set with merge to avoid NOT_FOUND errors
        batch.set(_devicesCollection.doc(device.id), {
          'status': DeviceStatus.revoked.name,
          'revoked_at': DateTime.now().toIso8601String(),
        }, SetOptions(merge: true));
        revokedCount++;
      } else if (device.isPending) {
        batch.delete(_devicesCollection.doc(device.id));
        deletedCount++;
      }
    }

    // Commit all operations in a single batch
    if (revokedCount > 0 || deletedCount > 0) {
      await batch.commit();
    }

    AppLogger.log(
      'E2EE: Current device is now primary (revoked $revokedCount approved, deleted $deletedCount pending)',
    );
  }
}
