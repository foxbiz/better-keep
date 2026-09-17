/// Main E2EE service that coordinates encryption/decryption.
///
/// This is the main entry point for E2EE functionality.
/// It manages initialization, key management, and encryption operations.
library;

import 'dart:async';

import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_operation.dart';

import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/note_encryption.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';

/// E2EE status for the current device.
enum E2EEStatus {
  /// E2EE has not been initialized yet.
  notInitialized,

  /// This is the first device - UMK needs to be created.
  notSetUp,

  /// Device is pending approval from another device.
  pendingApproval,

  /// Device has been revoked.
  revoked,

  /// No approved devices exist - user needs to recover or start fresh.
  /// This happens when user logs in but all devices were revoked/removed.
  needsRecovery,

  /// E2EE is ready for use.
  ready,

  /// E2EE is ready but verifying status in background.
  /// User can access notes while verification happens.
  verifyingInBackground,

  /// An error occurred during initialization.
  error,
}

bool e2eeStatusCanAccessLocalNotes(E2EEStatus status) =>
    status == E2EEStatus.ready || status == E2EEStatus.verifyingInBackground;

bool e2eeStatusIsCryptoReady(E2EEStatus status, {required bool hasUMK}) =>
    e2eeStatusCanAccessLocalNotes(status) && hasUMK;

/// Main E2EE service.
class E2EEService {
  static E2EEService? _instance;
  static E2EEService get instance {
    _instance ??= E2EEService._();
    return _instance!;
  }

  E2EEService._();

  final E2EESecureStorage _secureStorage = E2EESecureStorage.instance;
  final DeviceManager _deviceManager = DeviceManager.instance;
  final NoteEncryptionService _noteEncryption = NoteEncryptionService.instance;
  final RecoveryKeyService _recoveryKeyService = RecoveryKeyService.instance;

  final ValueNotifier<E2EEStatus> status = ValueNotifier(
    E2EEStatus.notInitialized,
  );

  /// Semantic progress for UI display during initialization.
  final ValueNotifier<ProtectionProgress?> statusProgress = ValueNotifier(null);

  /// Notifier to indicate recovery key setup is needed (after fresh E2EE setup).
  final ValueNotifier<bool> needsRecoveryKeySetup = ValueNotifier(false);

  /// Notifier to indicate background verification is in progress.
  /// Used by sync progress widget to show verification status.
  final ValueNotifier<bool> isVerifyingInBackground = ValueNotifier(false);

  /// Semantic progress shown during background verification.
  final ValueNotifier<ProtectionProgress?> backgroundVerificationProgress =
      ValueNotifier(null);

  /// Tracks whether status change listeners have been registered.
  bool _listenersRegistered = false;
  int _sessionGeneration = 0;
  LocalEncryptionState localState = LocalEncryptionState.missing;

  final AsyncInitializationGate _initializationGate = AsyncInitializationGate();

  /// Gets the device manager for device operations.
  DeviceManager get deviceManager => _deviceManager;

  /// Gets the note encryption service.
  NoteEncryptionService get noteEncryption => _noteEncryption;

  /// Gets the recovery key service.
  RecoveryKeyService get recoveryKeyService => _recoveryKeyService;

  /// Local encrypted data may be shown while server approval is rechecked.
  bool get canAccessLocalNotes => e2eeStatusCanAccessLocalNotes(status.value);

  /// Cloud synchronization requires both an approved state and an unlocked
  /// user master key. A cached approval status alone is never crypto-ready.
  bool get isCryptoReady =>
      e2eeStatusIsCryptoReady(status.value, hasUMK: isAvailable);

  @Deprecated('Use canAccessLocalNotes or isCryptoReady explicitly.')
  bool get isReady => isCryptoReady;

  /// Checks if E2EE is available (UMK is unlocked).
  bool get isAvailable => _deviceManager.getUMK() != null;

  /// Pre-loads cached E2EE status for fast app startup.
  /// Call this BEFORE runApp() so returning approved users go directly to Home.
  /// Returns true if user is a returning approved user (can skip loading screen).
  Future<bool> preloadCachedStatus() async {
    if (AuthService.hasDifferentLocalAccount) {
      localState = LocalEncryptionState.missing;
      status.value = E2EEStatus.error;
      return false;
    }
    final uid = AuthService.currentUser?.uid;
    final generation = _sessionGeneration;
    bool isCurrent() =>
        uid != null &&
        AuthService.currentUser?.uid == uid &&
        generation == _sessionGeneration;
    try {
      // Initialize secure storage first
      await _secureStorage.init();

      final restored = await readLocalEncryption(
        hasDeviceKeys: _secureStorage.hasDeviceKeys,
        readDeviceStatus: _secureStorage.getCachedDeviceStatus,
        loadKey: () => _deviceManager.loadLocalKey(isCurrent: isCurrent),
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return false;
      localState = restored;
      isVerifyingInBackground.value = false;
      backgroundVerificationProgress.value = null;
      switch (restored) {
        case LocalEncryptionState.ready:
          status.value = E2EEStatus.ready;
          listenForStatusChanges();
          return true;
        case LocalEncryptionState.pending:
          status.value = E2EEStatus.pendingApproval;
        case LocalEncryptionState.revoked:
          status.value = E2EEStatus.revoked;
        case LocalEncryptionState.needsRecovery:
          status.value = E2EEStatus.needsRecovery;
        case LocalEncryptionState.corrupt:
        case LocalEncryptionState.unavailable:
          status.value = E2EEStatus.error;
        case LocalEncryptionState.missing:
        case LocalEncryptionState.stale:
          break;
      }
      return false;
    } catch (e) {
      if (!isCurrent()) return false;
      localState = e is FormatException
          ? LocalEncryptionState.corrupt
          : LocalEncryptionState.unavailable;
      status.value = E2EEStatus.error;
      AppLogger.error('E2EE: Error preloading cached status', e);
      return false;
    }
  }

  /// Initializes E2EE for the current user.
  ///
  /// This should be called after user login.
  /// Uses cached status for fast startup, then verifies with Firebase in background.
  /// For returning users with approved status, verification happens in background
  /// while they can immediately access their notes.
  ///
  /// This method is idempotent - concurrent calls return the same Future.
  Future<void> initialize() {
    if (ReviewAccess.isAuthorizedSessionFor(AuthService.currentUser)) {
      return initializeReviewSession();
    }

    return _initializationGate.run(() async {
      final current = AuthService.captureSession();
      final generation = _sessionGeneration;
      await _initializeStandardSession();
      if (current() && generation == _sessionGeneration) {
        unawaited(AuthService.cloudRecovery.recheckAfterInitialization());
      }
    });
  }

  Future<void> _initializeStandardSession() async {
    final uid = AuthService.currentUser?.uid;
    final generation = _sessionGeneration;
    bool current() =>
        uid != null &&
        AuthService.currentUser?.uid == uid &&
        generation == _sessionGeneration;
    Future<T> checked<T>(Future<T> Function() operation) async {
      requireCurrentSession(current);
      final result = await runCloudOperation(current, operation);
      requireCurrentSession(current);
      return result;
    }

    try {
      if (AuthService.hasDifferentLocalAccount) {
        throw StateError('Local account mismatch');
      }
      if (await checked(preloadCachedStatus)) return;
      if (localState == LocalEncryptionState.unavailable) {
        throw const SecureStorageUnavailable(
          'Local encryption storage unavailable',
        );
      }
      if (localState == LocalEncryptionState.corrupt) {
        throw const FormatException(
          'Local encryption keys are incomplete or corrupt',
        );
      }
      statusProgress.value = ProtectionProgress.checkingAccount;
      // An interrupted sign-in does not invalidate persisted keys or approval.
      final hasKeys = await checked(_secureStorage.hasDeviceKeys);
      if (hasKeys) {
        await checked(_deviceManager.resumeInterruptedRegistration);
        final authorization = await checked(
          () => verifyLocalSessionAuthorization(isCurrent: current),
        );
        if (authorization == DeviceAuthorization.unavailable) {
          throw const CloudVerificationUnavailable();
        }
        return;
      }
      // A cached restriction or key cache is evidence of an existing setup.
      // Recovery is explicit; never overwrite it with first-device registration.
      final cachedKey = await checked(_secureStorage.getCachedUMK);
      final cachedStatus = await checked(_secureStorage.getCachedDeviceStatus);
      if (cachedKey != null || cachedStatus != null) {
        if (status.value != E2EEStatus.revoked &&
            status.value != E2EEStatus.pendingApproval) {
          status.value = E2EEStatus.needsRecovery;
        }
        return;
      }

      final isFirst = await checked(_deviceManager.isFirstDevice);
      if (isFirst) {
        final hasRecovery = await checked(_recoveryKeyService.hasRecoveryKey);
        if (!hasRecovery) {
          await checked(_setupE2EE);
          return;
        }
      } else {
        final hasApproved = await checked(_deviceManager.hasApprovedDevices);
        if (hasApproved &&
            !await checked(_deviceManager.currentDeviceMatchesPrimaryName)) {
          await checked(_deviceManager.registerNewDevice);
          status.value = E2EEStatus.pendingApproval;
          await checked(() => _secureStorage.cacheDeviceStatus('pending'));
          listenForStatusChanges();
          return;
        }
      }
      status.value = E2EEStatus.needsRecovery;
      await checked(() => _secureStorage.cacheDeviceStatus('needs_recovery'));
    } catch (error, stack) {
      if (!current() || error is CloudOperationCancelled) return;
      AppLogger.error('E2EE: Initialization error', error, stack);
      if (!isCryptoReady &&
          status.value != E2EEStatus.pendingApproval &&
          status.value != E2EEStatus.revoked &&
          status.value != E2EEStatus.needsRecovery) {
        status.value = E2EEStatus.error;
      }
      rethrow;
    } finally {
      if (current()) {
        statusProgress.value = null;
        isVerifyingInBackground.value = false;
        backgroundVerificationProgress.value = null;
      }
    }
  }

  /// Initializes an isolated, local-only E2EE session for app review.
  ///
  /// [ReviewAccess.authorize] must have verified the Firebase-signed claim
  /// before this method is called.
  Future<void> initializeReviewSession() {
    if (!ReviewAccess.isAuthorizedSessionFor(AuthService.currentUser)) {
      throw StateError('Review session is not authorized');
    }

    return _initializationGate.run(_initializeReviewSession);
  }

  Future<void> _initializeReviewSession() async {
    try {
      AppLogger.log('E2EE: Initializing isolated review session');
      statusProgress.value = ProtectionProgress.gettingReady;
      await _secureStorage.init();
      await _deviceManager.initializeLocalReviewDevice();
      await _secureStorage.cacheDeviceStatus('approved');
      await _secureStorage.setSignInProgress(false);

      needsRecoveryKeySetup.value = false;
      isVerifyingInBackground.value = false;
      backgroundVerificationProgress.value = null;
      statusProgress.value = null;
      status.value = E2EEStatus.ready;

      AppLogger.log('E2EE: Isolated review session ready');
    } catch (e, stack) {
      AppLogger.error('E2EE: Review session initialization error', e, stack);
      status.value = E2EEStatus.error;
      rethrow;
    }
  }

  /// Sets up E2EE for the first time (first device).
  ///
  /// Creates UMK and registers this device as the first approved device.
  Future<bool> setupE2EE() async {
    try {
      return await _setupE2EE();
    } catch (e, stack) {
      AppLogger.error('E2EE: Setup error', e, stack);
      status.value = E2EEStatus.error;
      rethrow;
    }
  }

  Future<bool> _setupE2EE() async {
    AppLogger.log('E2EE: Setting up E2EE for first device...');

    // Generate and store device keys, create UMK
    await _deviceManager.registerFirstDevice();

    status.value = E2EEStatus.ready;
    await _secureStorage.cacheDeviceStatus('approved');

    // Flag that recovery key setup is needed
    needsRecoveryKeySetup.value = true;

    AppLogger.log('E2EE: Setup complete');
    return true;
  }

  Future<DeviceAuthorization>? _authorizationRun;
  bool Function()? _authorizationCurrent;

  /// Verifies a restored device without conflating offline with revoked.
  Future<DeviceAuthorization> verifyLocalSessionAuthorization({
    bool Function()? isCurrent,
  }) {
    final running = _authorizationRun;
    if (running != null && (_authorizationCurrent?.call() ?? false)) {
      return running;
    }
    final accountCurrent = AuthService.captureSession();
    final uid = AuthService.currentUser?.uid;
    final generation = _sessionGeneration;
    bool current() =>
        accountCurrent() &&
        uid != null &&
        AuthService.currentUser?.uid == uid &&
        generation == _sessionGeneration &&
        (isCurrent?.call() ?? true);
    _authorizationCurrent = current;
    late final Future<DeviceAuthorization> operation;
    operation =
        runCloudOperation(current, () async {
          final authorization = await _deviceManager.readServerAuthorization();
          if (!current()) return DeviceAuthorization.unavailable;
          switch (authorization) {
            case DeviceAuthorization.approved:
              if (!isAvailable) await _deviceManager.init(isCurrent: current);
              if (!current()) return DeviceAuthorization.unavailable;
              if (!isAvailable) {
                localState = LocalEncryptionState.missing;
                status.value = E2EEStatus.error;
                throw const FormatException(
                  'Approved device has no usable master key',
                );
              }
              await _secureStorage.cacheDeviceStatus('approved');
              if (!current()) return DeviceAuthorization.unavailable;
              localState = LocalEncryptionState.ready;
              status.value = E2EEStatus.ready;
              listenForStatusChanges();
              await _deviceManager.startListeningForCurrentDevice(
                isCurrent: current,
              );
            case DeviceAuthorization.revoked:
            case DeviceAuthorization.deleted:
              status.value = authorization == DeviceAuthorization.revoked
                  ? E2EEStatus.revoked
                  : E2EEStatus.needsRecovery;
              await _secureStorage.cacheDeviceStatus(
                authorization == DeviceAuthorization.revoked
                    ? 'revoked'
                    : 'needs_recovery',
              );
              if (current()) await _deviceManager.clearUMK();
            case DeviceAuthorization.pending:
              status.value = E2EEStatus.pendingApproval;
              await _secureStorage.cacheDeviceStatus('pending');
              if (!current()) return DeviceAuthorization.unavailable;
              listenForStatusChanges();
              await _deviceManager.startListeningForApproval(
                isCurrent: current,
              );
            case DeviceAuthorization.initializing:
            case DeviceAuthorization.unconfirmed:
            case DeviceAuthorization.unavailable:
              break;
          }
          return authorization;
        }).whenComplete(() {
          if (identical(_authorizationRun, operation)) {
            _authorizationRun = null;
            _authorizationCurrent = null;
          }
        });
    _authorizationRun = operation;
    return operation;
  }

  /// Recovery and approval must not reuse authorization read before the change.
  Future<CloudSessionState> recheckCloudReadinessAfterDeviceChange() async {
    final current = AuthService.captureSession();
    final generation = _sessionGeneration;
    final authorization = _authorizationRun;
    if (authorization != null) {
      // Its caller owns error reporting; a fresh check is still required.
      await authorization.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    if (!current() || generation != _sessionGeneration) {
      return CloudSessionState.pending;
    }
    return AuthService.cloudRecovery.recheckAfterInitialization();
  }

  /// Re-checks device status (e.g., after coming back from background).
  Future<void> refreshStatus() async {
    try {
      final authorization = await verifyLocalSessionAuthorization();
      if (authorization == DeviceAuthorization.approved) {
        await AuthService.cloudRecovery.check();
      }
    } catch (error) {
      if (!isCloudConnectionFailure(error)) rethrow;
      AuthService.cloudRecovery.connectionLost();
    }
  }

  /// Listens for status changes on the device manager.
  /// Safe to call multiple times - will only register listeners once.
  void listenForStatusChanges() {
    if (_listenersRegistered) return;
    _listenersRegistered = true;

    // Listen for UMK availability
    _deviceManager.hasUMK.addListener(_onUMKChanged);

    // Listen for revocation
    _deviceManager.wasRevoked.addListener(_onRevokedChanged);
  }

  void _onUMKChanged() {
    if (_deviceManager.hasUMK.value &&
        status.value == E2EEStatus.pendingApproval) {
      status.value = E2EEStatus.ready;
      _secureStorage.cacheDeviceStatus('approved');
      unawaited(recheckCloudReadinessAfterDeviceChange());
    }
  }

  void _onRevokedChanged() {
    if (_deviceManager.wasRevoked.value) {
      status.value = E2EEStatus.revoked;
      _secureStorage.cacheDeviceStatus('revoked');
      _deviceManager.clearRevokedFlag();
    }
  }

  /// Resets the initialization guard.
  /// Call this on sign-out to allow re-initialization for a new user.
  void resetInitialization() {
    _sessionGeneration++;
    status.value = E2EEStatus.notInitialized;
    _initializationGate.reset();
    AppLogger.log('E2EE: Initialization guard reset');
  }

  /// Cleans up resources.
  Future<void> dispose() =>
      runCloudOperation(AuthService.captureSession(), _dispose);

  Future<void> _dispose() async {
    _sessionGeneration++;
    if (_listenersRegistered) {
      _deviceManager.hasUMK.removeListener(_onUMKChanged);
      _deviceManager.wasRevoked.removeListener(_onRevokedChanged);
      _listenersRegistered = false;
    }

    if (!ReviewAccess.isAuthorizedSessionFor(AuthService.currentUser)) {
      try {
        await _deviceManager.deleteCurrentDevice().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            AppLogger.log(
              'E2EE: Timeout deleting current device during dispose',
            );
          },
        );
      } catch (e) {
        AppLogger.error(
          'E2EE: Error deleting current device during dispose',
          e,
        );
      }
    }

    requireCloudOperation();
    try {
      await _deviceManager.clearUMK();
    } catch (e) {
      AppLogger.error('E2EE: Error clearing UMK during dispose', e);
    }

    requireCloudOperation();
    try {
      await _deviceManager.dispose();
    } catch (e) {
      AppLogger.error('E2EE: Error disposing device manager', e);
    }

    requireCloudOperation();
    RecoveryKeyService.instance.clearFirestoreCache();

    try {
      await _secureStorage.clearAll();
    } catch (e) {
      AppLogger.error('E2EE: Error clearing secure storage during dispose', e);
    }

    requireCloudOperation();
    statusProgress.value = null;
    needsRecoveryKeySetup.value = false;
    isVerifyingInBackground.value = false;
    backgroundVerificationProgress.value = null;
    status.value = E2EEStatus.notInitialized;
    // Reset initialization guard to allow re-init for new user
    resetInitialization();
  }

  /// Starts fresh by clearing all devices and creating a new UMK.
  ///
  /// This is used when user has no approved devices and no recovery key,
  /// or chooses to start fresh instead of recovering.
  /// Old encrypted notes remain in Firestore but are orphaned (unrecoverable).
  Future<void> startFresh() async {
    AppLogger.log('E2EE: Starting fresh - clearing all devices');

    // Clear all devices from Firestore
    await _deviceManager.clearAllDevices();

    // Clear local storage
    await _secureStorage.clearAll();

    // Reset status
    status.value = E2EEStatus.notInitialized;
    statusProgress.value = null;

    // Reset initialization guard before re-initializing
    resetInitialization();

    // Re-initialize (will now be first device)
    await initialize();

    AppLogger.log('E2EE: Fresh start complete');
  }
}
