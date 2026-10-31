/// Device management for E2EE multi-device support.
///
/// Handles device registration, UMK wrapping/unwrapping, and device approval.
library;

import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_read.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';

import 'dart:async';
import 'dart:convert';

import 'device_verification.dart';

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
  static const reminderV2Capability = 'reminder_v2';

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
  final Set<String> capabilities;
  final String? appVersion;
  final DeviceVerificationRequest? approvalRequest;

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
    this.capabilities = const <String>{},
    this.appVersion,
    this.approvalRequest,
  });

  bool get isApproved => status == DeviceStatus.approved;
  bool get isPending => status == DeviceStatus.pending;
  bool canApproveAt(DateTime now) =>
      isPending &&
      approvalRequest?.deviceId == id &&
      approvalRequest?.publicKey == publicKey &&
      approvalRequest?.isValidAt(now) == true;

  static DeviceVerificationRequest? _readApprovalRequest(Object? data) {
    try {
      return data is Map
          ? DeviceVerificationRequest.fromJson(Map<String, dynamic>.from(data))
          : null;
    } catch (_) {
      return null;
    }
  }

  bool get isRevoked => status == DeviceStatus.revoked;
  bool get hasWrappedUMK => wrappedUMK != null && wrappedUMKNonce != null;
  bool get supportsReminderV2 => capabilities.contains(reminderV2Capability);

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
      capabilities:
          (data['capabilities'] as List<dynamic>?)
              ?.map((value) => value.toString())
              .toSet() ??
          const <String>{},
      appVersion: data['app_version'] as String?,
      approvalRequest: _readApprovalRequest(data['approval_request']),
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
    if (capabilities.isNotEmpty) 'capabilities': capabilities.toList(),
    if (appVersion != null) 'app_version': appVersion,
    if (approvalRequest != null) 'approval_request': approvalRequest!.toJson(),
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

  FirebaseFirestore get _firestore => FirebaseBackend.firestore;

  final E2EESecureStorage _secureStorage = E2EESecureStorage.instance;
  final Uuid _uuid = const Uuid();
  int _sessionGeneration = 0;
  int _verificationGeneration = 0;
  String? _publishedCapabilities;
  String? _lastAuthorizationDiagnostic;
  final Map<String, Future<void>> _capabilityPublications = {};

  /// Stream subscriptions for cleanup
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _currentDeviceStatusSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _approvalSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _pendingApprovalsSubscription;

  Timer? _pendingApprovalsExpiry;

  /// In-memory cache of unwrapped UMK.
  Uint8List? _cachedUMK;

  /// Notifier for UMK availability.
  final ValueNotifier<bool> hasUMK = ValueNotifier(false);

  /// Notifier for pending approval requests (for existing devices).
  final ValueNotifier<List<DeviceApprovalRequest>> pendingApprovals =
      ValueNotifier([]);

  User? get _currentUser => AuthService.currentUser;

  DocumentReference<Map<String, dynamic>> get _userRef {
    requireCloudOperation();
    return _firestore.collection('users').doc(_currentUser!.uid);
  }

  CollectionReference<Map<String, dynamic>> get _devicesCollection =>
      _userRef.collection('devices');

  bool Function() _captureSession([bool Function()? isCurrent]) {
    final uid = _currentUser?.uid;
    final generation = _sessionGeneration;
    final accountCurrent = AuthService.captureSession();
    return () =>
        uid != null &&
        uid == _currentUser?.uid &&
        generation == _sessionGeneration &&
        accountCurrent() &&
        (isCurrent?.call() ?? true);
  }

  bool Function() _captureVerificationSession([bool Function()? isCurrent]) {
    final current = _captureSession(isCurrent);
    final generation = _verificationGeneration;
    return () => current() && generation == _verificationGeneration;
  }

  void invalidateSession() {
    _sessionGeneration++;
    _publishedCapabilities = null;
    _lastAuthorizationDiagnostic = null;
    _capabilityPublications.clear();
    _cachedUMK = null;
    hasUMK.value = false;
    unawaited(_currentDeviceStatusSubscription?.cancel());
    unawaited(_approvalSubscription?.cancel());
    unawaited(_pendingApprovalsSubscription?.cancel());
    _currentDeviceStatusSubscription = null;
    _approvalSubscription = null;
    _pendingApprovalsSubscription = null;
    _pendingApprovalsExpiry?.cancel();
    pendingApprovals.value = [];
  }

  /// Loads persisted encryption material without contacting Firebase.
  Future<bool> loadLocalKey({bool Function()? isCurrent}) async {
    final uid = _currentUser?.uid;
    if (uid == null) return false;
    if (await _secureStorage.getApprovalRequest() != null &&
        await _secureStorage.getAcceptedApproval() == null) {
      return false;
    }
    final key = await _secureStorage.getCachedUMK();
    if (_currentUser?.uid != uid || !(isCurrent?.call() ?? true)) return false;
    if (key == null) return false;
    if (key.length != 32) throw const FormatException('Invalid master key');
    _cachedUMK = key;
    hasUMK.value = true;
    return true;
  }

  Future<DeviceAuthorization> readServerAuthorization() async {
    final current = _captureSession();
    final pairingCurrent = _captureVerificationSession(current);
    final uid = _currentUser?.uid;
    final deviceId = await _secureStorage.getDeviceId();
    if (uid == null || deviceId == null || _currentUser?.uid != uid) {
      return DeviceAuthorization.initializing;
    }
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceId)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
    if (!current()) return DeviceAuthorization.unavailable;
    final metadata = snapshot.metadata;
    DeviceAuthorization result(DeviceAuthorization authorization) {
      final diagnostic =
          '${authorization.name}: '
          'cache=${metadata.isFromCache}, pendingWrites=${metadata.hasPendingWrites}';
      if (_lastAuthorizationDiagnostic != diagnostic) {
        _lastAuthorizationDiagnostic = diagnostic;
        AppLogger.log('[DEVICE_AUTH] $diagnostic');
      }
      return authorization;
    }

    if (!isAuthoritativeDeviceSnapshot(
      isFromCache: snapshot.metadata.isFromCache,
      hasPendingWrites: snapshot.metadata.hasPendingWrites,
    )) {
      return result(DeviceAuthorization.unconfirmed);
    }
    if (!snapshot.exists) {
      // Registration persists its identity before the server write. Do not
      // treat that unconfirmed identity as a previously deleted device.
      final unconfirmed =
          await _secureStorage.getCachedDeviceStatus() == null &&
          await _secureStorage.wasSignInInterrupted();
      if (!current()) return DeviceAuthorization.unavailable;
      return result(
        unconfirmed
            ? DeviceAuthorization.initializing
            : DeviceAuthorization.deleted,
      );
    }
    final device = DeviceDocument.fromFirestore(snapshot);
    if (device.isRevoked) return result(DeviceAuthorization.revoked);
    if (device.isPending &&
        (_cachedUMK != null ||
            await _secureStorage.getAcceptedApproval() != null)) {
      // Once this device observes a reset, the previous receipt cannot be
      // replayed to silently undo it. Reapproval needs a fresh local request.
      await runCloudOperation(current, () async {
        final publicKey = await _secureStorage.getDevicePublicKey();
        requireCurrentSession(current);
        if (publicKey == null) throw StateError('Local keys unavailable');
        // Persist a new binding before any network operation. Keeping a local
        // request also prevents a replay from falling back to legacy unwrap.
        await _secureStorage.storeApprovalRequest(
          DeviceVerificationRequest.create(
            account: uid,
            environment: _verificationEnvironment,
            deviceId: deviceId,
            publicKey: publicKey,
          ).qrData,
        );
        await clearUMK();
        await _ensureVerificationRequest(regenerate: true);
      });
    }
    final localRequest = await localVerificationRequest();
    if (device.isApproved && localRequest != null) {
      try {
        await _requireAcceptedReceipt(
          localRequest,
          snapshot.data()!,
          isCurrent: pairingCurrent,
        );
      } on FormatException {
        return result(DeviceAuthorization.pending);
      } on StateError {
        return result(
          pairingCurrent()
              ? DeviceAuthorization.pending
              : DeviceAuthorization.unavailable,
        );
      } catch (_) {
        return result(DeviceAuthorization.unavailable);
      }
    }
    if (!current()) return DeviceAuthorization.unavailable;
    return result(
      device.isApproved
          ? DeviceAuthorization.approved
          : DeviceAuthorization.pending,
    );
  }

  /// Initializes the device manager.
  ///
  /// Should be called after user login.
  Future<void> init({bool Function()? isCurrent}) async {
    final current = _captureSession(isCurrent);
    requireCurrentSession(current);
    final deviceId = await _secureStorage.getDeviceId();
    requireCurrentSession(current);
    if (deviceId == null) return;
    final deviceDoc = await readCloudDocument(
      _devicesCollection.doc(deviceId),
      isCurrent: current,
    );
    if (!deviceDoc.exists) return;
    final device = DeviceDocument.fromFirestore(deviceDoc);
    if (!device.isApproved) return;
    await loadLocalKey(isCurrent: current);
    requireCurrentSession(current);
    if (_cachedUMK == null && device.hasWrappedUMK) {
      await _unwrapAndCacheUMK(device, isCurrent: current);
      requireCurrentSession(current);
    }
    _listenForPendingApprovals();
    _listenForCurrentDeviceStatus(deviceId);
  }

  /// Listens for status changes on the current device (revocation, deletion).
  void _listenForCurrentDeviceStatus(String deviceId) {
    requireCloudOperation();
    final current = _captureSession();
    _currentDeviceStatusSubscription?.cancel();
    _currentDeviceStatusSubscription = runCloudCallback(
      current,
      () => _devicesCollection
          .doc(deviceId)
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snapshot) {
              if (!current() ||
                  !isAuthoritativeDeviceSnapshot(
                    isFromCache: snapshot.metadata.isFromCache,
                    hasPendingWrites: snapshot.metadata.hasPendingWrites,
                  )) {
                return;
              }
              unawaited(_verifyCurrentDevice(current));
            },
            onError: (Object error, StackTrace stack) {
              if (!current()) return;
              unawaited(_currentDeviceStatusSubscription?.cancel());
              _currentDeviceStatusSubscription = null;
              _handleListenerError(error, stack, current);
            },
          ),
    );
  }

  void _handleListenerError(
    Object error,
    StackTrace stack,
    bool Function() current,
  ) {
    if (!current() || error is CloudOperationCancelled) return;
    if (isCloudConnectionFailure(error)) {
      AuthService.cloudRecovery.connectionLost();
    }
    AppLogger.error('E2EE: Device listener deferred', error, stack);
  }

  Future<void> _verifyCurrentDevice(bool Function() current) async {
    try {
      final authorization = await E2EEService.instance
          .verifyLocalSessionAuthorization(isCurrent: current);
      if (current() &&
          authorization == DeviceAuthorization.approved &&
          AuthService.cloudRecovery.state.value != CloudSessionState.ready) {
        await E2EEService.instance.recheckCloudReadinessAfterDeviceChange();
      }
    } catch (error, stack) {
      _handleListenerError(error, stack, current);
    }
  }

  /// Starts listening for status changes and pending approvals for the current device.
  /// Call this after recovery to ensure the device is properly monitored.
  Future<void> startListeningForCurrentDevice({
    bool Function()? isCurrent,
  }) async {
    final current = _captureSession(isCurrent);
    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) {
      AppLogger.log('E2EE: Cannot start listening - no device ID stored');
      return;
    }

    requireCurrentSession(current);
    AppLogger.log('E2EE: Starting listeners for current device');
    unawaited(_publishCurrentCapabilities(deviceId));
    unawaited(_approvalSubscription?.cancel());
    _approvalSubscription = null;
    if (_currentDeviceStatusSubscription == null) {
      _listenForCurrentDeviceStatus(deviceId);
    }
    if (_pendingApprovalsSubscription == null) _listenForPendingApprovals();
  }

  Future<void> startListeningForApproval({bool Function()? isCurrent}) async {
    final current = _captureSession(isCurrent);
    final deviceId = await _secureStorage.getDeviceId();
    requireCurrentSession(current);
    if (deviceId != null) _listenForApproval(deviceId);
  }

  /// Checks if this is the first device for the user (no E2EE set up yet).
  Future<bool> isFirstDevice() async {
    if (_currentUser == null) return false;

    final devicesSnapshot = await _devicesCollection
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
    if (devicesSnapshot.metadata.isFromCache ||
        devicesSnapshot.metadata.hasPendingWrites) {
      throw const CloudVerificationUnavailable();
    }
    return devicesSnapshot.docs.isEmpty;
  }

  /// Checks if there are any approved devices for the user.
  /// Returns false if all devices are revoked/pending or there are no devices.
  Future<bool> hasApprovedDevices() async {
    if (_currentUser == null) return false;

    final devicesSnapshot = await _devicesCollection
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
    requireCloudOperation();
    if (devicesSnapshot.metadata.isFromCache ||
        devicesSnapshot.metadata.hasPendingWrites) {
      throw const CloudVerificationUnavailable();
    }
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

    final devicesSnapshot = await _devicesCollection
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
    requireCloudOperation();
    if (devicesSnapshot.metadata.isFromCache ||
        devicesSnapshot.metadata.hasPendingWrites) {
      throw const CloudVerificationUnavailable();
    }
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
    final authorization = await readServerAuthorization();
    return authorization == DeviceAuthorization.approved;
  }

  /// Tries to retrieve and cache the UMK if the device is approved.
  /// Returns true if UMK was successfully retrieved or already cached.
  Future<bool> tryRetrieveUMK() async {
    // Already have UMK cached
    if (_cachedUMK != null) return true;

    final deviceId = await _secureStorage.getDeviceId();
    if (deviceId == null) return false;

    final deviceDoc = await _devicesCollection
        .doc(deviceId)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 10));
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
    final authorization = await readServerAuthorization();
    return authorization == DeviceAuthorization.pending;
  }

  /// Checks if the current device is revoked.
  Future<bool> isDeviceRevoked() async {
    final authorization = await readServerAuthorization();
    return authorization == DeviceAuthorization.revoked;
  }

  /// Checks if the current device exists on the server.
  Future<bool> deviceExistsOnServer() async {
    final authorization = await readServerAuthorization();
    return authorization != DeviceAuthorization.deleted &&
        authorization != DeviceAuthorization.unavailable &&
        authorization != DeviceAuthorization.unconfirmed &&
        authorization != DeviceAuthorization.initializing;
  }

  /// Checks current device authorization status and triggers revocation if needed.
  /// Returns the same authoritative result used by startup and recovery.
  Future<DeviceAuthorization> checkCurrentDeviceAuthorization() =>
      E2EEService.instance.verifyLocalSessionAuthorization();

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
  Future<void> registerFirstDevice() => runCloudOperation(
    _captureSession(captureCloudOperation()),
    _registerFirstDevice,
  );

  Future<void> _registerFirstDevice() async {
    if (_currentUser == null) throw StateError('User not logged in');
    final hasKeys = await _secureStorage.hasDeviceKeys();
    final keys = hasKeys
        ? DeviceKeyPair(
            publicKey: (await _secureStorage.getDevicePublicKey())!,
            privateKey: (await _secureStorage.getDevicePrivateKey())!,
          )
        : await KeyExchange.generateKeyPair();
    final deviceId = hasKeys
        ? (await _secureStorage.getDeviceId())!
        : _uuid.v4();
    final cached = await _secureStorage.getCachedUMK();
    if (hasKeys && cached == null) {
      throw const FormatException('Incomplete first-device initialization');
    }
    final umk = cached ?? generateUserMasterKey();
    final wrapped = await _wrapUMKForDevice(
      umk,
      keys.publicKey,
      keys.privateKey,
    );
    final data = await _registrationData(keys);
    data.addAll({
      'wrapped_umk': wrapped.ciphertext,
      'wrapped_umk_nonce': wrapped.nonce,
      'status': DeviceStatus.approved.name,
      'approved_at': DateTime.now().toIso8601String(),
    });
    // Persist the identity before sending it. A delayed server write can then
    // be recovered with these same keys after a timeout or process restart.
    if (!hasKeys) {
      await _secureStorage.setSignInProgress(true);
      await _secureStorage.storeDevicePrivateKey(keys.privateKey);
      await _secureStorage.storeDevicePublicKey(keys.publicKey);
      await _secureStorage.storeDeviceId(deviceId);
      await _secureStorage.cacheUnwrappedUMK(umk);
    }
    requireCloudOperation();
    await _devicesCollection
        .doc(deviceId)
        .set(data)
        .timeout(const Duration(seconds: 10));
    requireCloudOperation();
    _cachedUMK = umk;
    hasUMK.value = true;
    _listenForPendingApprovals();
  }

  Future<Map<String, dynamic>> _registrationData(DeviceKeyPair keys) async {
    final name = await DeviceInfo.getDeviceName();
    final details = ReviewAccess.isAuthorizedSessionFor(_currentUser)
        ? <String, String?>{}
        : await DeviceInfo.getDeviceDetails();
    final version = await _appVersion();
    requireCloudOperation();
    return {
      'name': name,
      'platform': DeviceInfo.getCurrentPlatform(),
      'public_key': keys.publicKeyBase64,
      'created_at': DateTime.now().toIso8601String(),
      'device_details': details,
      'capabilities': const [DeviceDocument.reminderV2Capability],
      'app_version': version,
    };
  }

  /// Resume only an unconfirmed registration, using its already stored identity.
  /// Previously approved/revoked/deleted devices never enter this path.
  Future<void> resumeInterruptedRegistration() async {
    if (await _secureStorage.getCachedDeviceStatus() != null ||
        !await _secureStorage.wasSignInInterrupted() ||
        !await _secureStorage.hasDeviceKeys()) {
      return;
    }
    final deviceId = (await _secureStorage.getDeviceId())!;
    final document = await readCloudDocument(
      _devicesCollection.doc(deviceId),
      isCurrent: cloudOperationIsCurrent,
    );
    if (document.exists) return;
    if (await _secureStorage.getCachedUMK() != null) {
      if (!await isFirstDevice()) return;
      await _registerFirstDevice();
    } else {
      await _registerNewDevice();
    }
  }

  /// Creates or restores encryption material for the isolated review session.
  ///
  /// Review keys are intentionally local-only. No device document is created,
  /// no existing device is modified, and no approval listener is started.
  Future<void> initializeLocalReviewDevice() => runCloudOperation(
    _captureSession(captureCloudOperation()),
    _initializeLocalReviewDevice,
  );

  Future<void> _initializeLocalReviewDevice() async {
    if (_currentUser == null) throw StateError('User not logged in');
    if (!ReviewAccess.isAuthorizedSessionFor(_currentUser)) {
      throw StateError('Review session is not authorized');
    }

    await _secureStorage.init();

    final hasKeys = await _secureStorage.hasDeviceKeys();
    final cachedUMK = await _secureStorage.getCachedUMK();
    if (hasKeys && cachedUMK != null) {
      requireCloudOperation();
      _cachedUMK = cachedUMK;
      hasUMK.value = true;
      AppLogger.log('E2EE: Restored local review encryption keys');
      return;
    }

    if (hasKeys || cachedUMK != null) {
      throw const FormatException('Incomplete review encryption material');
    }

    final keyPair = await KeyExchange.generateKeyPair();
    final umk = generateUserMasterKey();
    final deviceId = _uuid.v4();

    await _secureStorage.storeDevicePrivateKey(keyPair.privateKey);
    await _secureStorage.storeDevicePublicKey(keyPair.publicKey);
    await _secureStorage.storeDeviceId(deviceId);
    await _secureStorage.cacheUnwrappedUMK(umk);

    requireCloudOperation();
    _cachedUMK = umk;
    hasUMK.value = true;
    AppLogger.log('E2EE: Created local-only review encryption keys');
  }

  /// Registers a new device and requests approval from an existing device.
  ///
  /// The device will be in pending state until approved by another device.
  Future<void> registerNewDevice() => runCloudOperation(
    _captureSession(captureCloudOperation()),
    _registerNewDevice,
  );

  Future<void> _registerNewDevice() async {
    if (_currentUser == null) throw StateError('User not logged in');
    final hasKeys = await _secureStorage.hasDeviceKeys();
    var deviceId = await _secureStorage.getDeviceId();
    if (deviceId != null) {
      final existing = await readCloudDocument(
        _devicesCollection.doc(deviceId),
        isCurrent: cloudOperationIsCurrent,
      );
      if (existing.exists) {
        final device = DeviceDocument.fromFirestore(existing);
        if (device.isPending) {
          await _ensureVerificationRequest();
          _listenForApproval(deviceId);
        }
        return;
      }
      if (await _secureStorage.getCachedDeviceStatus() != null) {
        throw StateError('Existing device requires explicit recovery');
      }
    }
    final keys = hasKeys
        ? DeviceKeyPair(
            publicKey: (await _secureStorage.getDevicePublicKey())!,
            privateKey: (await _secureStorage.getDevicePrivateKey())!,
          )
        : await KeyExchange.generateKeyPair();
    final data = await _registrationData(keys);
    deviceId ??= _uuid.v4();
    if (!hasKeys) {
      await _secureStorage.setSignInProgress(true);
      await _secureStorage.storeDevicePrivateKey(keys.privateKey);
      await _secureStorage.storeDevicePublicKey(keys.publicKey);
      await _secureStorage.storeDeviceId(deviceId);
    }
    final request = DeviceVerificationRequest.create(
      account: _currentUser!.uid,
      environment: _verificationEnvironment,
      deviceId: deviceId,
      publicKey: keys.publicKey,
    );
    await _secureStorage.storeApprovalRequest(request.qrData);
    await _secureStorage.rememberInitializedAccount(_currentUser!.uid);
    data['approval_request'] = request.toJson();
    data['approval_protocol'] = DeviceVerificationRequest.version;
    data['status'] = DeviceStatus.pending.name;
    requireCloudOperation();
    await _devicesCollection
        .doc(deviceId)
        .set(data)
        .timeout(const Duration(seconds: 10));
    await _secureStorage.cacheDeviceStatus('pending');
    requireCloudOperation();
    _listenForApproval(deviceId);
  }

  String get _verificationEnvironment => jsonEncode([
    FirebaseBackend.projectId,
    FirebaseBackend.databaseId,
    FirebaseBackend.environment.name,
  ]);

  Future<DeviceVerificationRequest?> localVerificationRequest() async {
    final current = _captureSession();
    final value = await _secureStorage.getApprovalRequest();
    requireCurrentSession(current);
    if (value == null) return null;
    final request = DeviceVerificationRequest.fromLocalData(value);
    final publicKey = await _secureStorage.getDevicePublicKey();
    final deviceId = await _secureStorage.getDeviceId();
    requireCurrentSession(current);
    if (request.account != _currentUser!.uid ||
        request.environment != _verificationEnvironment ||
        request.deviceId != deviceId ||
        publicKey == null ||
        request.publicKey != base64Encode(publicKey)) {
      throw StateError('Local device verification does not match this session');
    }
    return request;
  }

  Future<DeviceVerificationRequest> ensureVerificationRequest({
    bool regenerate = false,
  }) => runCloudOperation(
    _captureSession(captureCloudOperation()),
    () => _ensureVerificationRequest(regenerate: regenerate),
  );

  Future<DeviceVerificationRequest> _ensureVerificationRequest({
    bool regenerate = false,
  }) {
    if (regenerate) _verificationGeneration++;
    final current = _captureVerificationSession(captureCloudOperation());
    return runCloudOperation(current, () async {
      final deviceId = await _secureStorage.getDeviceId();
      final publicKey = await _secureStorage.getDevicePublicKey();
      requireCurrentSession(current);
      if (deviceId == null || publicKey == null) {
        throw StateError('Device keys unavailable');
      }
      final ref = _devicesCollection.doc(deviceId);
      final snapshot = await readCloudDocument(ref, isCurrent: current);
      final data = snapshot.data();
      if (!['pending', 'approved'].contains(data?['status']) ||
          data?['public_key'] != base64Encode(publicKey)) {
        throw StateError('Device is not awaiting verification');
      }
      final previous = await localVerificationRequest();
      requireCurrentSession(current);
      if (data?['status'] == 'approved' && _cachedUMK != null) {
        throw StateError('Device verification is already complete');
      }
      if (!regenerate && previous != null) {
        // An expired request must be explicitly regenerated by the user. Do not
        // change a code while someone is comparing it on another device.
        if (jsonEncode(data?['approval_request']) !=
            jsonEncode(previous.toJson())) {
          final remote = data?['approval_request'];
          if (remote is! Map ||
              DeviceVerificationRequest.fromJson(
                    Map<String, dynamic>.from(remote),
                  ).canonical !=
                  previous.canonical) {
            throw StateError('Device verification request changed');
          }
        }
        return previous;
      }
      final request = DeviceVerificationRequest.create(
        account: _currentUser!.uid,
        environment: _verificationEnvironment,
        deviceId: deviceId,
        publicKey: publicKey,
      );
      // Persist locally before publishing: a server approval must never be
      // accepted without the locally created request binding.
      if (regenerate) await clearUMK();
      await _secureStorage.storeApprovalRequest(request.qrData);
      requireCurrentSession(current);
      await _firestore.runTransaction((transaction) async {
        final fresh = (await transaction.get(ref)).data();
        requireCurrentSession(current);
        if (!['pending', 'approved'].contains(fresh?['status']) ||
            fresh?['public_key'] != request.publicKey ||
            fresh?['status'] != data?['status'] ||
            jsonEncode(fresh?['approval_request']) !=
                jsonEncode(data?['approval_request'])) {
          throw StateError('Device verification request changed');
        }
        transaction.update(ref, {
          'status': 'pending',
          'approval_protocol': DeviceVerificationRequest.version,
          'approval_request': request.toJson(),
          'wrapped_umk': FieldValue.delete(),
          'wrapped_umk_nonce': FieldValue.delete(),
          'approved_by_public_key': FieldValue.delete(),
          'pairing_proof': FieldValue.delete(),
        });
      });
      requireCurrentSession(current);
      return request;
    });
  }

  Future<DeviceVerificationRequest> pendingVerificationRequest(
    String deviceId,
  ) => runCloudOperation(_captureSession(captureCloudOperation()), () async {
    final current = _captureSession(captureCloudOperation());
    final snapshot = await readCloudDocument(
      _devicesCollection.doc(deviceId),
      isCurrent: current,
    );
    final data = snapshot.data();
    if (data?['status'] != 'pending' ||
        data?['approval_request'] is! Map ||
        data?['approval_protocol'] != DeviceVerificationRequest.version) {
      throw StateError(
        'Update the new device and generate a verification code',
      );
    }
    final request = DeviceVerificationRequest.fromJson(
      Map<String, dynamic>.from(data!['approval_request'] as Map),
    );
    if (request.deviceId != deviceId ||
        request.publicKey != data['public_key'] ||
        request.account != _currentUser!.uid ||
        request.environment != _verificationEnvironment) {
      throw StateError('Device verification request does not match');
    }
    request.requireValid(DateTime.now());
    return request;
  });

  /// No unverified overload: all UI entry points must obtain local proof first.
  Future<DeviceApprovalReceipt> approveDevice(
    VerifiedDeviceApproval verified,
  ) => runCloudOperation(_captureSession(captureCloudOperation()), () async {
    final current = _captureSession(captureCloudOperation());
    final request = verified.request;
    request.requireValid(DateTime.now());
    if (_cachedUMK == null ||
        request.account != _currentUser?.uid ||
        request.environment != _verificationEnvironment) {
      throw StateError('Cannot approve device in this session');
    }
    final fresh = await pendingVerificationRequest(request.deviceId);
    if (fresh.canonical != request.canonical) {
      throw StateError('Device key changed');
    }
    final ourDeviceId = await _secureStorage.getDeviceId();
    final ourPrivateKey = await _secureStorage.getDevicePrivateKey();
    final ourPublicKey = await _secureStorage.getDevicePublicKey();
    requireCurrentSession(current);
    if (ourDeviceId == null || ourPrivateKey == null || ourPublicKey == null) {
      throw StateError('Local keys unavailable');
    }
    final sharedSecret = await KeyExchange.deriveSharedSecret(
      ourPrivateKey,
      base64Decode(request.publicKey),
    );
    requireCurrentSession(current);
    late CipherResultString wrapped;
    try {
      wrapped = await AuthenticatedCipher.encryptString(
        request.encodeMasterKey(_cachedUMK!),
        sharedSecret,
      );
    } finally {
      sharedSecret.fillRange(0, sharedSecret.length, 0);
    }
    requireCurrentSession(current);
    final receipt = verified.authenticateReceipt(
      DeviceApprovalReceipt(
        request: request,
        approverPublicKey: base64Encode(ourPublicKey),
        ciphertext: wrapped.ciphertext,
        nonce: wrapped.nonce,
      ),
    );
    final ref = _devicesCollection.doc(request.deviceId);
    await _firestore.runTransaction((transaction) async {
      final approver = (await transaction.get(
        _devicesCollection.doc(ourDeviceId),
      )).data();
      final data = (await transaction.get(ref)).data();
      requireCurrentSession(current);
      request.requireValid(DateTime.now());
      if (approver?['status'] != 'approved' ||
          approver?['public_key'] != base64Encode(ourPublicKey)) {
        throw StateError('Approving device authorization changed');
      }
      if (data?['status'] != 'pending' ||
          data?['public_key'] != request.publicKey ||
          data?['approval_protocol'] != DeviceVerificationRequest.version ||
          data?['approval_request'] is! Map ||
          DeviceVerificationRequest.fromJson(
                Map<String, dynamic>.from(data!['approval_request'] as Map),
              ).canonical !=
              request.canonical) {
        throw StateError('Device verification request changed');
      }
      transaction.update(ref, {
        'wrapped_umk': wrapped.ciphertext,
        'wrapped_umk_nonce': wrapped.nonce,
        'wrapped_umk_version': DeviceVerificationRequest.version,
        'status': DeviceStatus.approved.name,
        'approved_at': DateTime.now().toIso8601String(),
        'approved_by_public_key': base64Encode(ourPublicKey),
        'pairing_proof': receipt.pairingProof ?? FieldValue.delete(),
      });
    });
    requireCurrentSession(current);
    // The existing snapshot listener refreshes the pending list. Return
    // the locally created receipt even if a later metadata read is offline.
    return receipt;
  });

  /// UI completion only; this hint never authorizes or unwraps a key.
  Stream<bool> approvalReceiptFinished(DeviceApprovalReceipt receipt) {
    final current = _captureSession();
    return _devicesCollection
        .doc(receipt.request.deviceId)
        .snapshots(includeMetadataChanges: true)
        .where((snapshot) => !snapshot.metadata.isFromCache)
        .map((snapshot) {
          final data = snapshot.data();
          return !current() ||
              data == null ||
              data['status'] != 'approved' ||
              data['accepted_receipt'] == receipt.fingerprint ||
              data['wrapped_umk'] != receipt.ciphertext;
        });
  }

  Future<void> _publishReceiptAccepted(
    DeviceApprovalReceipt receipt,
    bool Function() current,
  ) async {
    try {
      final ref = _devicesCollection.doc(receipt.request.deviceId);
      await _firestore
          .runTransaction((transaction) async {
            final data = (await transaction.get(ref)).data();
            requireCurrentSession(current);
            if (data == null ||
                data['status'] != 'approved' ||
                DeviceApprovalReceipt.fromDocument(
                      receipt.request,
                      data,
                    ).fingerprint !=
                    receipt.fingerprint) {
              return;
            }
            transaction.update(ref, {'accepted_receipt': receipt.fingerprint});
          })
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // A best-effort UI acknowledgement cannot prevent local key recovery.
    }
  }

  Future<void> _requireAcceptedReceipt(
    DeviceVerificationRequest localRequest,
    Map<String, dynamic> data, {
    required bool Function() isCurrent,
  }) => runCloudOperation(isCurrent, () async {
    final receipt = DeviceApprovalReceipt.fromDocument(localRequest, data);
    final accepted = await _secureStorage.getAcceptedApproval();
    requireCurrentSession(isCurrent);
    if (accepted == null) {
      final verified = localRequest.verifyPairingReceipt(receipt);
      if (verified == null) receipt.requireAccepted(null);
      await _secureStorage.storeAcceptedApproval(receipt.fingerprint);
      requireCurrentSession(isCurrent);
    } else {
      receipt.requireAccepted(accepted);
    }
    // Persist acceptance before removing the secret: a crash between writes
    // can safely resume only this exact handoff, never a replacement.
    if (localRequest.hasPairingSecret) {
      await _secureStorage.completeApprovalRequest(
        jsonEncode(localRequest.toJson()),
      );
      requireCurrentSession(isCurrent);
    }
  });

  /// Reads a candidate only. Server approval never proves who sent the key.
  Future<DeviceApprovalReceipt?> pendingApprovalReceipt() =>
      runCloudOperation(_captureSession(captureCloudOperation()), () async {
        final current = _captureSession(captureCloudOperation());
        final request = await localVerificationRequest();
        if (request == null) return null;
        final snapshot = await readCloudDocument(
          _devicesCollection.doc(request.deviceId),
          isCurrent: current,
        );
        if (snapshot.data()?['status'] != 'approved') return null;
        return DeviceApprovalReceipt.fromDocument(request, snapshot.data()!);
      });

  /// Only a local scan/full-code confirmation can persist this exact receipt.
  Future<void> acceptVerifiedApproval(VerifiedDeviceReceipt verified) =>
      runCloudOperation(
        _captureVerificationSession(captureCloudOperation()),
        () async {
          final current = _captureVerificationSession(captureCloudOperation());
          final receipt = verified.receipt;
          receipt.request.requireValid(DateTime.now());
          final candidate = await pendingApprovalReceipt();
          requireCurrentSession(current);
          if (candidate?.fingerprint != receipt.fingerprint) {
            throw StateError(
              'Device handoff changed. Verify both devices again.',
            );
          }
          receipt.request.requireValid(DateTime.now());
          await _secureStorage.storeAcceptedApproval(receipt.fingerprint);
          requireCurrentSession(current);
          // init rereads and validates the fingerprint before decrypting. A
          // replacement arriving between these operations cannot be accepted.
          await init(isCurrent: current);
        },
      );

  Future<void> cancelApprovalRequest() {
    _verificationGeneration++;
    return runCloudOperation(
      _captureVerificationSession(captureCloudOperation()),
      () async {
        final current = _captureVerificationSession(captureCloudOperation());
        final request = await localVerificationRequest();
        requireCurrentSession(current);
        if (request == null || _cachedUMK != null) return;
        final ref = _devicesCollection.doc(request.deviceId);
        await _firestore.runTransaction((transaction) async {
          final data = (await transaction.get(ref)).data();
          requireCurrentSession(current);
          if (data == null) return;
          if (data['public_key'] != request.publicKey ||
              data['approval_request'] is! Map ||
              DeviceVerificationRequest.fromJson(
                    Map<String, dynamic>.from(data['approval_request'] as Map),
                  ).canonical !=
                  request.canonical) {
            throw StateError('Device request changed');
          }
          transaction.delete(ref);
        });
        requireCurrentSession(current);
        // Cancellation abandons the pending identity. Keeping its private key
        // after removing the binding could permit a legacy downgrade replay.
        await clearUMK();
        await _secureStorage.clearAll();
      },
    );
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
      'pairing_proof': FieldValue.delete(),
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
  Future<void> requestReapproval() {
    _verificationGeneration++;
    return runCloudOperation(_captureSession(captureCloudOperation()), () async {
      final deviceId = await _secureStorage.getDeviceId();

      // Clear local UMK cache since we need a new one
      await _secureStorage.clearCachedUMK();
      requireCloudOperation();
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
      final deviceDoc = await _devicesCollection
          .doc(deviceId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
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
        'pairing_proof': FieldValue.delete(),
        'revoked_at': FieldValue.delete(),
      });

      await _ensureVerificationRequest(regenerate: true);

      AppLogger.log('E2EE: Re-approval request sent');

      // Start listening for approval again
      _listenForApproval(deviceId);
    });
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

  Future<void> _publishCurrentCapabilities(String deviceId) async {
    final current = _captureSession();
    try {
      final version = await _appVersion();
      requireCurrentSession(current);
      final key =
          '${_currentUser!.uid}/$deviceId/$version/'
          '${DeviceDocument.reminderV2Capability}';
      if (_publishedCapabilities == key) return;
      final pending = _capabilityPublications[key];
      if (pending != null) return await pending;
      // Own the publication lifetime; verification's deadline does not own
      // the listeners or their background metadata update.
      final publication = runCloudOperation(current, () async {
        // Updating cannot recreate a device deleted during verification.
        await _devicesCollection
            .doc(deviceId)
            .update({
              'capabilities': const [DeviceDocument.reminderV2Capability],
              'app_version': version,
            })
            .timeout(const Duration(seconds: 10));
        requireCurrentSession(current);
        _publishedCapabilities = key;
      });
      _capabilityPublications[key] = publication;
      try {
        await publication;
      } finally {
        if (identical(_capabilityPublications[key], publication)) {
          _capabilityPublications.remove(key);
        }
      }
    } catch (error) {
      if (!current()) return;
      if (isCloudConnectionFailure(error)) {
        AuthService.cloudRecovery.connectionLost();
      }
      AppLogger.log('E2EE: Could not publish device capabilities: $error');
    }
  }

  Future<String> _appVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }

  /// Gets the unwrapped UMK for encrypting/decrypting notes.
  Uint8List? getUMK() => _cachedUMK;

  /// Sets the cached UMK (used during recovery).
  /// This should only be called when a UMK has been recovered and stored.
  void setCachedUMK(Uint8List umk) {
    requireCloudOperation();
    _cachedUMK = umk;
    hasUMK.value = true;
  }

  @visibleForTesting
  void setCachedUMKForTesting(Uint8List? umk) {
    _cachedUMK = umk;
    hasUMK.value = umk != null;
  }

  /// Clears the cached UMK (e.g., on logout).
  Future<void> clearUMK() async {
    requireCloudOperation();
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
    _sessionGeneration++;
    _pendingApprovalsExpiry?.cancel();
    _publishedCapabilities = null;
    _lastAuthorizationDiagnostic = null;
    _capabilityPublications.clear();
    final subscriptions = [
      _currentDeviceStatusSubscription,
      _approvalSubscription,
      _pendingApprovalsSubscription,
    ];
    _currentDeviceStatusSubscription = null;
    _approvalSubscription = null;
    _pendingApprovalsSubscription = null;
    await Future.wait(
      subscriptions.whereType<StreamSubscription>().map((s) => s.cancel()),
    );
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

    try {
      return await AuthenticatedCipher.encryptString(
        base64Encode(umk),
        sharedSecret,
      );
    } finally {
      sharedSecret.fillRange(0, sharedSecret.length, 0);
    }
  }

  /// Unwraps and caches the UMK from a device document.
  Future<void> _unwrapAndCacheUMK(
    DeviceDocument device, {
    bool Function()? isCurrent,
  }) {
    final current = _captureVerificationSession(
      isCurrent ?? captureCloudOperation(),
    );
    return runCloudOperation(current, () async {
      final uid = _currentUser?.uid;
      final generation = _sessionGeneration;
      if (!device.hasWrappedUMK) {
        throw StateError('Device does not have wrapped UMK');
      }

      final privateKey = await _secureStorage.getDevicePrivateKey();
      if (privateKey == null) {
        throw StateError('Local private key not found');
      }

      Uint8List sharedSecret;

      // Check if this was approved by another device or is self-encrypted
      requireCurrentSession(current);
      final deviceDoc = await readCloudDocument(
        _devicesCollection.doc(device.id),
        isCurrent: current,
      );
      device = DeviceDocument.fromFirestore(deviceDoc);
      if (!device.isApproved || !device.hasWrappedUMK) {
        throw StateError('Device approval changed');
      }
      final localRequest = await localVerificationRequest();
      if (localRequest != null) {
        await _requireAcceptedReceipt(
          localRequest,
          deviceDoc.data()!,
          isCurrent: current,
        );
      }
      requireCurrentSession(current);
      final approvedByPublicKey =
          deviceDoc.data()?['approved_by_public_key'] as String?;

      if (localRequest == null &&
          approvedByPublicKey != null &&
          approvedByPublicKey.isNotEmpty) {
        // A legacy sender key fetched from the server is not independent proof.
        // Existing native devices keep their cached UMK. If that cache is lost,
        // use verified pairing or recovery instead of trusting a new sender key.
        throw StateError('Verified device approval or recovery required');
      }
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

      late String plaintext;
      try {
        plaintext = await AuthenticatedCipher.decryptString(
          device.wrappedUMK!,
          device.wrappedUMKNonce!,
          sharedSecret,
        );
      } finally {
        sharedSecret.fillRange(0, sharedSecret.length, 0);
      }
      requireCurrentSession(current);
      late Uint8List umk;
      if (localRequest != null ||
          deviceDoc.data()?['wrapped_umk_version'] ==
              DeviceVerificationRequest.version) {
        if (localRequest == null ||
            deviceDoc.data()?['wrapped_umk_version'] !=
                DeviceVerificationRequest.version) {
          throw StateError(
            'Verified device approval required. Update the approving device.',
          );
        }
        final accepted = await _secureStorage.getAcceptedApproval();
        requireCurrentSession(current);
        DeviceApprovalReceipt.fromDocument(
          localRequest,
          deviceDoc.data()!,
        ).requireAccepted(accepted);
        umk = localRequest.decodeMasterKey(
          plaintext,
          envelopeVersion: deviceDoc.data()?['wrapped_umk_version'] as int?,
          previouslyAcceptedRequestId: localRequest.requestId,
        );
      } else {
        // Existing approved devices and first-device/recovery self-wrapping.
        umk = base64Decode(plaintext);
      }

      if (_currentUser?.uid != uid || generation != _sessionGeneration) return;
      requireCurrentSession(current);
      if (umk.length != 32) throw const FormatException('Invalid master key');
      // Cache the unwrapped UMK
      await _secureStorage.cacheUnwrappedUMK(umk);
      requireCurrentSession(current);
      requireCloudOperation();
      _cachedUMK = umk;
      hasUMK.value = true;

      if (localRequest != null) {
        unawaited(
          _publishReceiptAccepted(
            DeviceApprovalReceipt.fromDocument(localRequest, deviceDoc.data()!),
            current,
          ),
        );
      }
      AppLogger.log('E2EE: UMK unwrapped and cached');
    });
  }

  /// Listens for approval of the current device.
  void _listenForApproval(String deviceId) {
    if (_approvalSubscription != null) return;
    requireCloudOperation();
    final current = _captureSession();
    _approvalSubscription = runCloudCallback(
      current,
      () => _devicesCollection
          .doc(deviceId)
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snapshot) {
              if (!current() ||
                  !isAuthoritativeDeviceSnapshot(
                    isFromCache: snapshot.metadata.isFromCache,
                    hasPendingWrites: snapshot.metadata.hasPendingWrites,
                  )) {
                return;
              }
              unawaited(_verifyCurrentDevice(current));
            },
            onError: (Object error, StackTrace stack) {
              if (!current()) return;
              unawaited(_approvalSubscription?.cancel());
              _approvalSubscription = null;
              _handleListenerError(error, stack, current);
            },
          ),
    );
  }

  /// Notifier for when the device is revoked or deleted.
  final ValueNotifier<bool> wasRevoked = ValueNotifier(false);

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
    requireCloudOperation();
    final current = _captureSession();
    _pendingApprovalsSubscription?.cancel();
    _pendingApprovalsSubscription = runCloudCallback(
      current,
      () => _devicesCollection
          .where('status', isEqualTo: DeviceStatus.pending.name)
          .snapshots()
          .listen(
            (snapshot) {
              if (!current()) return;
              _publishPendingApprovals(
                snapshot.docs
                    .map((doc) => DeviceDocument.fromFirestore(doc))
                    .toList(),
              );
            },
            onError: (Object error, StackTrace stack) {
              if (!current()) return;
              unawaited(_pendingApprovalsSubscription?.cancel());
              _pendingApprovalsSubscription = null;
              _handleListenerError(error, stack, current);
            },
          ),
    );
  }

  /// Refreshes the pending approvals list.
  Future<void> _refreshPendingApprovals() async {
    final current = _captureSession();
    final snapshot = await _devicesCollection
        .where('status', isEqualTo: DeviceStatus.pending.name)
        .get();

    if (!current()) return;
    _publishPendingApprovals(
      snapshot.docs.map((doc) => DeviceDocument.fromFirestore(doc)).toList(),
    );
  }

  void _publishPendingApprovals(List<DeviceDocument> devices) {
    _pendingApprovalsExpiry?.cancel();
    final current = _captureSession();
    final now = DateTime.now();
    final eligible = devices
        .where((device) => device.canApproveAt(now))
        .toList();
    pendingApprovals.value = eligible
        .map(DeviceApprovalRequest.fromDocument)
        .toList();
    if (eligible.isEmpty) return;
    final expiry = eligible
        .map(
          (device) =>
              device.approvalRequest!.createdAt +
              DeviceVerificationRequest.lifetime.inMilliseconds,
        )
        .reduce((a, b) => a < b ? a : b);
    _pendingApprovalsExpiry = Timer(
      Duration(milliseconds: expiry - now.millisecondsSinceEpoch),
      () {
        if (current()) _publishPendingApprovals(eligible);
      },
    );
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
