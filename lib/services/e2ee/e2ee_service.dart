/// Main E2EE service that coordinates encryption/decryption.
///
/// This is the main entry point for E2EE functionality.
/// It manages initialization, key management, and encryption operations.
library;

import 'dart:async';

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/note_encryption.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/config.dart' show demoAccountEmail;
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

  /// Detailed status message for UI display during initialization.
  final ValueNotifier<String> statusMessage = ValueNotifier('');

  /// Notifier to indicate recovery key setup is needed (after fresh E2EE setup).
  final ValueNotifier<bool> needsRecoveryKeySetup = ValueNotifier(false);

  /// Notifier to indicate background verification is in progress.
  /// Used by sync progress widget to show verification status.
  final ValueNotifier<bool> isVerifyingInBackground = ValueNotifier(false);

  /// Message shown during background verification.
  final ValueNotifier<String> backgroundVerificationMessage = ValueNotifier('');

  /// Tracks whether status change listeners have been registered.
  bool _listenersRegistered = false;

  /// Gets the device manager for device operations.
  DeviceManager get deviceManager => _deviceManager;

  /// Gets the note encryption service.
  NoteEncryptionService get noteEncryption => _noteEncryption;

  /// Gets the recovery key service.
  RecoveryKeyService get recoveryKeyService => _recoveryKeyService;

  /// Checks if E2EE is ready for encryption/decryption.
  /// Also returns true when verifying in background (user can access notes).
  bool get isReady =>
      status.value == E2EEStatus.ready ||
      status.value == E2EEStatus.verifyingInBackground;

  /// Checks if E2EE is available (UMK is unlocked).
  bool get isAvailable => _deviceManager.getUMK() != null;

  /// Pre-loads cached E2EE status for fast app startup.
  /// Call this BEFORE runApp() so returning approved users go directly to Home.
  /// Returns true if user is a returning approved user (can skip loading screen).
  Future<bool> preloadCachedStatus() async {
    try {
      // Initialize secure storage first
      await _secureStorage.init();

      // Check if this device has keys
      final hasKeys = await _secureStorage.hasDeviceKeys();
      if (!hasKeys) {
        AppLogger.log('E2EE: No device keys, user needs setup');
        return false;
      }

      // Check cached status
      final cachedStatus = await _secureStorage.getCachedDeviceStatus();
      if (cachedStatus == 'approved') {
        AppLogger.log('E2EE: Cached approved status, enabling fast startup');
        // Set status to verifyingInBackground immediately
        // This allows app.dart to show Home right away
        status.value = E2EEStatus.verifyingInBackground;
        isVerifyingInBackground.value = true;
        backgroundVerificationMessage.value = 'Verifying encryption...';
        return true;
      }

      AppLogger.log('E2EE: Cached status is $cachedStatus, needs full init');
      return false;
    } catch (e) {
      AppLogger.error('E2EE: Error preloading cached status', e);
      return false;
    }
  }

  /// Checks if the current user is the demo account (for Google Play review testing).
  /// Demo accounts bypass device authorization for easier testing.
  bool get _isDemoAccount {
    final email = AuthService.currentUser?.email;
    return email != null &&
        email.toLowerCase() == demoAccountEmail.toLowerCase();
  }

  /// Initializes E2EE for the current user.
  ///
  /// This should be called after user login.
  /// Uses cached status for fast startup, then verifies with Firebase in background.
  /// For returning users with approved status, verification happens in background
  /// while they can immediately access their notes.
  Future<void> initialize() async {
    try {
      AppLogger.log('E2EE: Initializing...');

      // Check if preloadCachedStatus() already set verifyingInBackground
      // In that case, just do device manager init and background verification
      if (status.value == E2EEStatus.verifyingInBackground) {
        AppLogger.log(
          'E2EE: Status already verifyingInBackground, continuing background init',
        );
        // Secure storage already initialized by preloadCachedStatus
        // Initialize device manager to load cached UMK
        await _deviceManager.init();
        // Continue verification in background
        _verifyApprovedStatusInBackground();
        return;
      }

      statusMessage.value = 'Getting ready...';

      // Initialize secure storage
      await _secureStorage.init();

      // Check for interrupted sign-in (app crashed/refreshed during sign-in)
      final wasInterrupted = await _secureStorage.wasSignInInterrupted();
      if (wasInterrupted) {
        AppLogger.log('E2EE: Detected interrupted sign-in, cleaning up...');
        statusMessage.value = 'Resuming setup...';
        // Clear the flag and any partial state
        await _secureStorage.setSignInProgress(false);
        await _secureStorage.clearDeviceStatus();
        // Continue with fresh initialization
      }

      statusMessage.value = 'Checking your account...';

      // Check if this device has keys first (before using cached status)
      final hasKeys = await _secureStorage.hasDeviceKeys();

      // Load cached status for fast startup (only if device has keys)
      // If no keys, device is new and needs setup
      if (hasKeys) {
        final cachedStatus = await _secureStorage.getCachedDeviceStatus();
        if (cachedStatus != null) {
          AppLogger.log('E2EE: Using cached status: $cachedStatus');
          switch (cachedStatus) {
            case 'approved':
              // For returning approved users: set verifyingInBackground and verify async
              // This allows immediate access to notes while we verify with server
              status.value = E2EEStatus.verifyingInBackground;
              isVerifyingInBackground.value = true;
              backgroundVerificationMessage.value = 'Verifying encryption...';
              // Initialize device manager to load cached UMK
              await _deviceManager.init();
              // Continue verification in background
              _verifyApprovedStatusInBackground();
              return;
            case 'pending':
              status.value = E2EEStatus.pendingApproval;
              break;
            case 'revoked':
              status.value = E2EEStatus.revoked;
              break;
          }
        }
        // If has keys but no cached status, keep notInitialized until verified
      }
      // If no keys, keep notInitialized - will be set after registration

      // Initialize device manager
      statusMessage.value = 'Connecting...';
      await _deviceManager.init();

      if (!hasKeys) {
        // New device - need to register
        AppLogger.log('E2EE: New device, checking if E2EE is set up...');
        statusMessage.value = 'Preparing your account...';

        // Check if E2EE is set up for this user (any devices exist)
        final isFirst = await _deviceManager.isFirstDevice();

        if (isFirst) {
          // First device - automatically set up E2EE
          AppLogger.log('E2EE: First device, automatically setting up E2EE...');
          statusMessage.value = 'Securing your account...';
          await setupE2EE();
          return;
        }

        // Devices exist - check if any are approved
        final hasApproved = await _deviceManager.hasApprovedDevices();

        if (!hasApproved) {
          // No approved devices - user needs to recover or start fresh
          // Exception: Demo account gets auto-setup for testing purposes
          if (_isDemoAccount) {
            AppLogger.log(
              'E2EE: Demo account detected, auto-setting up E2EE...',
            );
            statusMessage.value = 'Setting up demo account...';
            await setupE2EE();
            return;
          }
          AppLogger.log(
            'E2EE: No approved devices exist, user needs recovery or fresh start',
          );
          status.value = E2EEStatus.needsRecovery;
          await _secureStorage.cacheDeviceStatus('needs_recovery');
          return;
        }

        // Approved devices exist - check if this might be the same device as primary
        // (user logged out/uninstalled/cleared data on their main device)
        final matchesPrimary = await _deviceManager
            .currentDeviceMatchesPrimaryName();

        if (matchesPrimary) {
          // Device name matches primary - likely same physical device
          // Show recovery page instead of requiring approval from another device
          // Exception: Demo account gets auto-setup for testing purposes
          if (_isDemoAccount) {
            AppLogger.log(
              'E2EE: Demo account detected, clearing old devices and starting fresh...',
            );
            statusMessage.value = 'Setting up demo account...';
            await _deviceManager.clearAllDevices();
            await setupE2EE();
            return;
          }
          AppLogger.log(
            'E2EE: Device name matches primary device, showing recovery page',
          );
          status.value = E2EEStatus.needsRecovery;
          await _secureStorage.cacheDeviceStatus('needs_recovery');
          return;
        }

        // Different device - register this device and wait for approval
        // Exception: Demo account gets auto-setup (clears existing and starts fresh)
        if (_isDemoAccount) {
          AppLogger.log(
            'E2EE: Demo account detected on new device, clearing old devices and starting fresh...',
          );
          statusMessage.value = 'Setting up demo account...';
          await _deviceManager.clearAllDevices();
          await setupE2EE();
          return;
        }
        AppLogger.log('E2EE: Registering new device...');
        statusMessage.value = 'Adding this device...';
        await _deviceManager.registerNewDevice();
        status.value = E2EEStatus.pendingApproval;
        await _secureStorage.cacheDeviceStatus('pending');
        listenForStatusChanges();
        return;
      }

      // Device has keys - check if device still exists on server
      statusMessage.value = 'Verifying...';
      final existsOnServer = await _deviceManager.deviceExistsOnServer();

      if (!existsOnServer) {
        // Device was deleted from server (user cleared Firestore data)
        // Clear local data and treat as fresh start
        AppLogger.log('E2EE: Device not found on server, clearing local data');
        statusMessage.value = 'Updating account...';
        await _deviceManager.clearLocalData();

        // Check if this would be the first device again
        final isFirst = await _deviceManager.isFirstDevice();
        if (isFirst) {
          // First device - automatically set up E2EE
          AppLogger.log(
            'E2EE: First device after reset, automatically setting up E2EE...',
          );
          statusMessage.value = 'Securing your account...';
          await setupE2EE();
        } else {
          // Devices exist - check if any are approved
          final hasApproved = await _deviceManager.hasApprovedDevices();

          if (!hasApproved) {
            // No approved devices - user needs to recover or start fresh
            // Exception: Demo account gets auto-setup for testing purposes
            if (_isDemoAccount) {
              AppLogger.log(
                'E2EE: Demo account detected after reset, auto-setting up E2EE...',
              );
              statusMessage.value = 'Setting up demo account...';
              await setupE2EE();
              return;
            }
            AppLogger.log(
              'E2EE: No approved devices after reset, user needs recovery',
            );
            status.value = E2EEStatus.needsRecovery;
            await _secureStorage.cacheDeviceStatus('needs_recovery');
          } else {
            // Approved devices exist - check if this might be the same device as primary
            final matchesPrimary = await _deviceManager
                .currentDeviceMatchesPrimaryName();

            if (matchesPrimary) {
              // Device name matches primary - likely same physical device
              // Exception: Demo account gets auto-setup for testing purposes
              if (_isDemoAccount) {
                AppLogger.log(
                  'E2EE: Demo account detected (matches primary) after reset, clearing and starting fresh...',
                );
                statusMessage.value = 'Setting up demo account...';
                await _deviceManager.clearAllDevices();
                await setupE2EE();
                return;
              }
              AppLogger.log(
                'E2EE: Device name matches primary after reset, showing recovery',
              );
              status.value = E2EEStatus.needsRecovery;
              await _secureStorage.cacheDeviceStatus('needs_recovery');
            } else {
              // Different device - needs re-registration
              // Exception: Demo account gets auto-setup (clears existing and starts fresh)
              if (_isDemoAccount) {
                AppLogger.log(
                  'E2EE: Demo account detected on new device after reset, clearing and starting fresh...',
                );
                statusMessage.value = 'Setting up demo account...';
                await _deviceManager.clearAllDevices();
                await setupE2EE();
                return;
              }
              statusMessage.value = 'Adding this device...';
              await _deviceManager.registerNewDevice();
              status.value = E2EEStatus.pendingApproval;
              await _secureStorage.cacheDeviceStatus('pending');
              listenForStatusChanges();
            }
          }
        }
        return;
      }

      // Device exists - check status
      statusMessage.value = 'Almost there...';
      final isRevoked = await _deviceManager.isDeviceRevoked();

      if (isRevoked) {
        // Device has been revoked - show revoked screen
        AppLogger.log('E2EE: Device is revoked');
        status.value = E2EEStatus.revoked;
        await _secureStorage.cacheDeviceStatus('revoked');
        _deviceManager.setRevokedFlag();
        return;
      }

      final isApproved = await _deviceManager.isDeviceApproved();
      final isPending = await _deviceManager.isDevicePending();

      if (isPending) {
        AppLogger.log('E2EE: Device is pending approval');
        status.value = E2EEStatus.pendingApproval;
        await _secureStorage.cacheDeviceStatus('pending');
        listenForStatusChanges();
        return;
      }

      if (!isApproved) {
        // Should not happen if device exists, but handle gracefully
        AppLogger.log('E2EE: Device in unknown state');
        status.value = E2EEStatus.error;
        return;
      }

      // Device is approved - check if UMK is available
      if (_deviceManager.hasUMK.value) {
        AppLogger.log('E2EE: UMK available, ready');
        status.value = E2EEStatus.ready;
        await _secureStorage.cacheDeviceStatus('approved');
        // Listen for status changes (revocation, etc.)
        listenForStatusChanges();
        return;
      }

      // Try cached UMK as fallback
      final cachedUMK = await _secureStorage.getCachedUMK();
      if (cachedUMK != null) {
        AppLogger.log('E2EE: Using cached UMK');
        status.value = E2EEStatus.ready;
        await _secureStorage.cacheDeviceStatus('approved');
        // Listen for status changes (revocation, etc.)
        listenForStatusChanges();
        return;
      }

      AppLogger.log('E2EE: Could not unlock UMK');
      status.value = E2EEStatus.error;
    } catch (e, stack) {
      AppLogger.error('E2EE: Initialization error', e, stack);
      status.value = E2EEStatus.error;
    }
  }

  /// Sets up E2EE for the first time (first device).
  ///
  /// Creates UMK and registers this device as the first approved device.
  Future<bool> setupE2EE() async {
    try {
      AppLogger.log('E2EE: Setting up E2EE for first device...');

      // Generate and store device keys, create UMK
      await _deviceManager.registerFirstDevice();

      status.value = E2EEStatus.ready;
      await _secureStorage.cacheDeviceStatus('approved');

      // Flag that recovery key setup is needed
      needsRecoveryKeySetup.value = true;

      AppLogger.log('E2EE: Setup complete');
      return true;
    } catch (e, stack) {
      AppLogger.error('E2EE: Setup error', e, stack);
      status.value = E2EEStatus.error;
      return false;
    }
  }

  /// Verifies approved status in background for returning users.
  /// User can access notes immediately while this runs.
  /// If verification fails (revoked, deleted), updates status appropriately.
  void _verifyApprovedStatusInBackground() {
    AppLogger.log('E2EE: Starting background verification...');

    _performBackgroundVerification()
        .then((_) {
          isVerifyingInBackground.value = false;
          backgroundVerificationMessage.value = '';
          AppLogger.log('E2EE: Background verification completed');
        })
        .catchError((e, stack) {
          AppLogger.error('E2EE: Background verification error', e, stack);
          isVerifyingInBackground.value = false;
          backgroundVerificationMessage.value = '';
          // Don't change status to error - user can still access cached notes
          // The error will be caught on next sync attempt
        });
  }

  /// Performs the actual background verification.
  Future<void> _performBackgroundVerification() async {
    try {
      backgroundVerificationMessage.value = 'Checking encryption status...';

      // Check if device still exists on server
      final existsOnServer = await _deviceManager.deviceExistsOnServer();

      if (!existsOnServer) {
        // Device was deleted from server - this is a critical issue
        // User needs to re-authenticate or recover
        AppLogger.log(
          'E2EE: Device not found on server during background verification',
        );
        status.value = E2EEStatus.needsRecovery;
        await _secureStorage.cacheDeviceStatus('needs_recovery');
        return;
      }

      backgroundVerificationMessage.value = 'Verifying device...';

      // Check if device is still approved
      final isRevoked = await _deviceManager.isDeviceRevoked();

      if (isRevoked) {
        AppLogger.log('E2EE: Device was revoked (detected in background)');
        status.value = E2EEStatus.revoked;
        await _secureStorage.cacheDeviceStatus('revoked');
        _deviceManager.setRevokedFlag();
        return;
      }

      final isApproved = await _deviceManager.isDeviceApproved();

      if (!isApproved) {
        // Device is no longer approved but not explicitly revoked
        // This shouldn't happen normally, but handle gracefully
        AppLogger.log(
          'E2EE: Device no longer approved (detected in background)',
        );
        status.value = E2EEStatus.needsRecovery;
        await _secureStorage.cacheDeviceStatus('needs_recovery');
        return;
      }

      // All good - device is still approved
      AppLogger.log(
        'E2EE: Background verification successful, device approved',
      );
      status.value = E2EEStatus.ready;
      await _secureStorage.cacheDeviceStatus('approved');

      // Start listening for status changes (revocation, etc.)
      listenForStatusChanges();
    } catch (e) {
      // Network errors etc - don't change status, just log
      AppLogger.error('E2EE: Background verification network error', e);
      // Keep status as verifyingInBackground for now
      // Status will be rechecked on next app resume or sync
      status.value = E2EEStatus.ready;
      listenForStatusChanges();
    }
  }

  /// Re-checks device status (e.g., after coming back from background).
  Future<void> refreshStatus() async {
    if (status.value == E2EEStatus.pendingApproval) {
      final isApproved = await _deviceManager.isDeviceApproved();
      if (isApproved) {
        // Try to retrieve the UMK if not already cached
        final hasUMK = await _deviceManager.tryRetrieveUMK();
        if (hasUMK) {
          status.value = E2EEStatus.ready;
          await _secureStorage.cacheDeviceStatus('approved');
          AppLogger.log('E2EE: Device now approved and ready');
        }
      }
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
    }
  }

  void _onRevokedChanged() {
    if (_deviceManager.wasRevoked.value) {
      status.value = E2EEStatus.revoked;
      _secureStorage.cacheDeviceStatus('revoked');
      _deviceManager.clearRevokedFlag();
    }
  }

  /// Cleans up resources.
  Future<void> dispose() async {
    if (_listenersRegistered) {
      _deviceManager.hasUMK.removeListener(_onUMKChanged);
      _deviceManager.wasRevoked.removeListener(_onRevokedChanged);
      _listenersRegistered = false;
    }
    // Delete the current device from Firestore before signing out
    await _deviceManager.deleteCurrentDevice();
    // Clear cached UMK
    await _deviceManager.clearUMK();
    // Cancel all Firestore subscriptions in DeviceManager to prevent permission errors after sign-out
    await _deviceManager.dispose();
    // Clear RecoveryKeyService Firestore cache
    RecoveryKeyService.instance.clearFirestoreCache();
    await _secureStorage.clearAll();
    status.value = E2EEStatus.notInitialized;
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
    statusMessage.value = '';

    // Re-initialize (will now be first device)
    await initialize();

    AppLogger.log('E2EE: Fresh start complete');
  }
}
