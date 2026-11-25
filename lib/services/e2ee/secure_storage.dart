/// Secure storage for E2EE keys and secrets.
///
/// Uses platform-specific secure storage (Keychain on iOS/macOS,
/// EncryptedSharedPreferences on Android, etc.) to store sensitive data.
library;

import 'package:better_keep/services/e2ee/device_authorization.dart';

import 'device_verification.dart';
import 'browser_device_store.dart'
    if (dart.library.js_interop) 'browser_device_store_web.dart'
    as browser;
import '../review_access.dart';
import '../file_system.dart'
    show currentAccountFileGeneration, retireAccountFiles;
import '../local_storage_recovery.dart';
import '../firebase_scoped_preferences.dart';

import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/cloud_operation.dart';

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device has not completed the key and proof checks needed for approval.
class BrowserApprovalNotReady extends StateError {
  BrowserApprovalNotReady(super.message);
}

/// Secure storage wrapper for E2EE keys.
///
/// On mobile platforms, uses flutter_secure_storage which leverages
/// platform secure storage (Keychain, Keystore).
///
/// Approved browser device identities are encrypted locally. Unwrapped master
/// keys and pending pairing secrets live only in the current Dart session.
class E2EESecureStorage {
  // No build-time encryption secret is required.
  static bool get isWebStorageConfigured => true;

  static E2EESecureStorage? _instance;
  static E2EESecureStorage get instance {
    _instance ??= E2EESecureStorage._();
    return _instance!;
  }

  E2EESecureStorage._()
    : legacyKeyHex = const String.fromEnvironment('WEB_STORAGE_KEY');

  @visibleForTesting
  E2EESecureStorage.forTesting({this.legacyKeyHex = ''});

  // Read-only compatibility with the previously released browser format.
  // Never use this public build constant to persist new secrets.
  final String legacyKeyHex;
  String? _legacyUid;
  bool get needsLegacyRecoverySetup => _legacyUid != null;

  // Storage keys
  static const String _devicePrivateKeyKey = 'e2ee_device_private_key';
  static const String _devicePublicKeyKey = 'e2ee_device_public_key';
  static const String _deviceIdKey = 'e2ee_device_id';
  static const String _umkCacheKey = 'e2ee_umk_cache';
  static const String _rememberDeviceKey = 'e2ee_remember_device';
  static const String _deviceStatusKey = 'e2ee_device_status';
  static const String _signInProgressKey = 'e2ee_sign_in_progress';
  static const String _approvalRequestKey = 'e2ee_approval_request';
  static const String _approvalPublicationKey = 'e2ee_approval_publication';
  static const String _acceptedApprovalKey = 'e2ee_accepted_approval';
  static const _keys = [
    _devicePrivateKeyKey,
    _devicePublicKeyKey,
    _deviceIdKey,
    _umkCacheKey,
    _rememberDeviceKey,
    _deviceStatusKey,
    _signInProgressKey,
    _approvalRequestKey,
    _acceptedApprovalKey,
    _approvalPublicationKey,
  ];

  Future<void> clearApprovalRequest() => _mutations.run('keys', () async {
    requireCloudOperation();
    await _deleteDirect(_approvalRequestKey);
    await _deleteDirect(_acceptedApprovalKey);
    await _deleteDirect(_approvalPublicationKey);
  });

  Future<String?> getApprovalRequest() => _read(_approvalRequestKey);
  Future<void> storeApprovalRequest(String value) =>
      _mutations.run('keys', () async {
        requireCloudOperation();
        if (kIsWeb) await _updateBrowserIdentity(null);
        await _deleteDirect(_approvalPublicationKey);
        await _deleteDirect(_acceptedApprovalKey);
        await _writeDirect(_approvalRequestKey, value);
      });

  /// Journal both locally generated requests before publishing. A lost network
  /// acknowledgement must not discard the only secret for a committed request.
  Future<void> beginApprovalPublication(String candidate) =>
      _mutations.run('keys', () async {
        requireCloudOperation();
        if (await _read(_approvalPublicationKey) != null) {
          throw StateError('Resolve the previous approval publication first');
        }
        final journal = jsonEncode({
          'candidate': candidate,
          'previous': await _read(_approvalRequestKey),
          'accepted': await _read(_acceptedApprovalKey),
        });
        requireCloudOperation();
        await _writeDirect(_approvalPublicationKey, journal);
        requireCloudOperation();
        await _deleteDirect(_acceptedApprovalKey);
        requireCloudOperation();
        await _writeDirect(_approvalRequestKey, candidate);
      });

  /// Explicit regeneration abandons uncertain publication; it never accepts it.
  Future<void> abandonApprovalPublication() => _mutations.run('keys', () async {
    requireCloudOperation();
    await _deleteDirect(_approvalPublicationKey);
  });

  /// Only recover a request/secret already journaled on this device. Never
  /// adopt a server-supplied request or overwrite a newer local operation.
  Future<void> reconcileApprovalPublication(
    DeviceVerificationRequest? remote,
  ) => _mutations.run('keys', () async {
    requireCloudOperation();
    final raw = await _read(_approvalPublicationKey);
    if (raw == null) return;
    final journal = jsonDecode(raw) as Map<String, dynamic>;
    final candidate = journal['candidate'] as String;
    final previous = journal['previous'] as String?;
    final local = await _read(_approvalRequestKey);
    if (local != candidate && local != previous) {
      throw StateError('Local approval request changed');
    }
    final candidateMatches =
        DeviceVerificationRequest.fromLocalData(candidate).canonical ==
        remote?.canonical;
    final previousMatches = previous == null
        ? remote == null
        : DeviceVerificationRequest.fromLocalData(previous).canonical ==
              remote?.canonical;
    if (!candidateMatches && !previousMatches) {
      throw StateError('Device verification request changed');
    }
    requireCloudOperation();
    await _deleteDirect(_acceptedApprovalKey);
    requireCloudOperation();
    if (!candidateMatches && previous == null) {
      await _deleteDirect(_approvalRequestKey);
    } else {
      await _writeDirect(
        _approvalRequestKey,
        candidateMatches ? candidate : previous!,
      );
    }
    if (!candidateMatches && journal['accepted'] is String) {
      requireCloudOperation();
      await _writeDirect(_acceptedApprovalKey, journal['accepted'] as String);
    }
    requireCloudOperation();
    await _deleteDirect(_approvalPublicationKey);
  });

  /// Remove the one-time QR secret without invalidating the accepted fingerprint.
  Future<void> completeApprovalRequest(String publicRequest) =>
      _mutations.run('keys', () async {
        requireCloudOperation();
        await _writeDirect(_approvalRequestKey, publicRequest);
        requireCloudOperation();
        await _deleteDirect(_approvalPublicationKey);
      });

  Future<String?> getAcceptedApproval() => _read(_acceptedApprovalKey);
  Future<void> storeAcceptedApproval(String fingerprint) =>
      _write(_acceptedApprovalKey, fingerprint);

  // Secure storage instance (for native platforms)
  // flutter_secure_storage v10+ uses custom ciphers on Android by default,
  // automatically migrating from the old EncryptedSharedPreferences backend.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Plaintext working state for the current page.
  final Map<String, String> _webMemory = {};
  final _mutations = AsyncKeyedSerializer<String>();

  String? _browserUid, _browserScope, _savedIdentity;
  // The scoped record may describe a retired library. Keep only its grant ID
  // for cleanup after a successful replacement, without restoring its keys.
  String? _storedGrantId;
  int? _browserRevision;
  String? _libraryGeneration;

  String get _trustScope => jsonEncode([
    FirebaseBackend.localDataScope.secureStoragePrefix,
    FirebaseBackend.projectId,
    FirebaseBackend.databaseId,
  ]);

  static const _identityKeys = [
    _deviceIdKey,
    _devicePrivateKeyKey,
    _devicePublicKeyKey,
    _approvalRequestKey,
    _acceptedApprovalKey,
  ];

  bool get hasRememberedBrowserIdentity {
    if (!kIsWeb ||
        _savedIdentity == null ||
        _browserUid != FirebaseBackend.auth.currentUser?.uid ||
        _browserScope != _trustScope) {
      return false;
    }
    final saved = jsonDecode(_savedIdentity!) as Map<String, dynamic>;
    if (browser.offlineGrantState(_storedGrantId) !=
            browser.OfflineGrantState.active ||
        saved[_deviceIdKey] == null ||
        saved[_devicePrivateKeyKey] == null ||
        saved[_devicePublicKeyKey] == null ||
        (saved[_approvalRequestKey] != null &&
            saved[_acceptedApprovalKey] == null)) {
      return false;
    }
    return _identityKeys.every(
      (key) => saved[key] == _webMemory[_scopedKey(key)],
    );
  }

  Future<void> init({String? uid, bool Function()? isCurrent}) async {
    if (!kIsWeb) return;
    uid ??= FirebaseBackend.auth.currentUser?.uid;
    if (uid == null) return;
    final owner = uid;
    final operationCurrent = captureCloudOperation();
    final scope = _trustScope;
    bool current() =>
        operationCurrent() &&
        (isCurrent?.call() ?? true) &&
        FirebaseBackend.auth.currentUser?.uid == owner &&
        _trustScope == scope;
    await _mutations.run('keys', () async {
      if (!current()) return;
      if (_browserUid != owner ||
          _browserScope != scope ||
          (_browserRevision == null && _webMemory.isEmpty)) {
        _webMemory.clear();
        _legacyUid = null;
        _browserUid = _browserScope = _savedIdentity = _storedGrantId = null;
        _browserRevision = null;
        final prefs = await SharedPreferences.getInstance();
        _libraryGeneration = currentAccountFileGeneration(prefs);
        (int, String?)? stored;
        try {
          stored = await browser.readDeviceIdentity(scope, owner);
        } catch (error) {
          AppLogger.log(
            'Browser approval storage unavailable (${error.runtimeType})',
          );
        }
        if (!current()) return;
        if (stored != null) {
          final (revision, identity) = stored;
          _browserRevision = revision;
          if (identity != null) {
            final values = jsonDecode(identity) as Map<String, dynamic>;
            _storedGrantId = values['offlineGrant'] as String?;
            if (_libraryGeneration != null &&
                (values['library'] ?? 'legacy') == _libraryGeneration) {
              final state = browser.offlineGrantState(_storedGrantId);
              final statusKey = _scopedKey(_deviceStatusKey);
              if (state == browser.OfflineGrantState.revoked) {
                _webMemory[statusKey] = 'revoked';
              } else if (_storedGrantId == null ||
                  state != browser.OfflineGrantState.missing) {
                // Older identities without a grant still verify online.
                for (final key in _identityKeys) {
                  if (values[key] case final String value) {
                    _webMemory[_scopedKey(key)] = value;
                  }
                }
                _webMemory[statusKey] = 'approved';
                _savedIdentity = identity;
              }
            }
          }
        }
        _browserUid = owner;
        _browserScope = scope;
      }
      // A retired identity must not fall back to older saved keys.
      if ((_storedGrantId == null || _savedIdentity != null) &&
          _webMemory[_scopedKey(_deviceStatusKey)] != 'revoked') {
        await _importLegacy(owner, current);
      }
    });
  }

  Future<void> _importLegacy(String uid, bool Function() isCurrent) async {
    final prefs = await SharedPreferences.getInstance();
    // Remember existing accounts without destroying their only recovery source.
    for (final scope in FirebaseLocalDataScope.values) {
      final owner = prefs.getString(scope.preferenceKey('user_uid'));
      if (owner != null &&
          _keys.any((key) => prefs.containsKey(scope.secureStorageKey(key)))) {
        await prefs.setBool(
          scope.preferenceKey('e2ee_initialized.$owner'),
          true,
        );
      }
    }
    final scope = FirebaseBackend.localDataScope;
    if (prefs.getString(scope.preferenceKey('user_uid')) != uid ||
        _legacyUid == uid ||
        _webMemory.containsKey(_scopedKey(_devicePrivateKeyKey))) {
      return;
    }
    final legacy = <String, String>{};
    // Approval proofs belong to the new protocol and are never imported.
    for (final key in _keys.take(7)) {
      final value = prefs.getString(scope.secureStorageKey(key));
      if (value != null) legacy[key] = value;
    }
    if (legacy.isEmpty) return;
    final restored = <String, String>{};
    try {
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(legacyKeyHex)) {
        throw const FormatException('Legacy browser recovery key unavailable');
      }
      final key = SecretKey([
        for (var i = 0; i < 64; i += 2)
          int.parse(legacyKeyHex.substring(i, i + 2), radix: 16),
      ]);
      for (final entry in legacy.entries) {
        final bytes = base64Decode(entry.value);
        if (bytes.length < 28) {
          throw const FormatException('Invalid legacy key');
        }
        final plaintext = await AesGcm.with256bits().decrypt(
          SecretBox(
            bytes.sublist(12, bytes.length - 16),
            nonce: bytes.sublist(0, 12),
            mac: Mac(bytes.sublist(bytes.length - 16)),
          ),
          secretKey: key,
        );
        restored[_scopedKey(entry.key)] = utf8.decode(plaintext);
      }
    } catch (error) {
      if (error is! FormatException && error is! SecretBoxAuthenticationError) {
        rethrow;
      }
      requireCloudOperation();
      // Preserve the source and fail closed; never bootstrap a replacement UMK.
      throw const SecureStorageUnavailable(
        'Legacy browser recovery unavailable',
        state: LocalEncryptionState.legacyRecoveryUnavailable,
      );
    }
    requireCloudOperation();
    if (!isCurrent()) return;
    _webMemory.addAll(restored);
    _legacyUid = uid;
  }

  /// Called only after recovery has been saved or successfully exercised.
  Future<void> completeLegacyRecovery(String uid) =>
      _mutations.run('keys', () async {
        if (!kIsWeb) return;
        requireCloudOperation();
        final prefs = await SharedPreferences.getInstance();
        final scope = FirebaseBackend.localDataScope;
        if (prefs.getString(scope.preferenceKey('user_uid')) != uid) return;
        if (_legacyUid == uid &&
            await getCachedDeviceStatus() == 'approved' &&
            await hasDeviceKeys() &&
            await getCachedUMK() != null) {
          _legacyUid = null;
          try {
            if (!await _rememberApprovedBrowser()) {
              _legacyUid = uid;
              return;
            }
          } catch (error) {
            _legacyUid = uid;
            requireCloudOperation();
            AppLogger.log(
              'Retaining legacy recovery source (${error.runtimeType})',
            );
            return;
          }
        }
        for (final key in _keys) {
          requireCloudOperation();
          await prefs.remove(scope.secureStorageKey(key));
        }
        _legacyUid = null;
      });

  // Non-secret account history prevents browser-key migration/reload from
  // silently bootstrapping a replacement library if device records disappear.
  Future<void> rememberInitializedAccount(String uid) async {
    if (!kIsWeb) return;
    requireCloudOperation();
    final key = FirebaseBackend.localDataScope.preferenceKey(
      'e2ee_initialized.$uid',
    );
    final prefs = await SharedPreferences.getInstance();
    requireCloudOperation();
    await prefs.setBool(key, true);
  }

  Future<bool> wasAccountInitialized(String uid) async {
    if (!kIsWeb) return false;
    // An unreadable trust slot is not evidence of a brand new library.
    if (uid == _browserUid && _browserRevision == null) {
      throw const SecureStorageUnavailable(
        'Could not check browser device history',
      );
    }
    if (uid == _browserUid && _storedGrantId != null) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(
          FirebaseBackend.localDataScope.preferenceKey('e2ee_initialized.$uid'),
        ) ??
        false;
  }

  /// Stores the device's private key.
  Future<void> storeDevicePrivateKey(Uint8List privateKey) async {
    await _write(_devicePrivateKeyKey, base64Encode(privateKey));
  }

  /// Retrieves the device's private key.
  Future<Uint8List?> getDevicePrivateKey() async {
    final value = await _read(_devicePrivateKeyKey);
    if (value == null) return null;
    return base64Decode(value);
  }

  /// Stores the device's public key.
  Future<void> storeDevicePublicKey(Uint8List publicKey) async {
    await _write(_devicePublicKeyKey, base64Encode(publicKey));
  }

  /// Retrieves the device's public key.
  Future<Uint8List?> getDevicePublicKey() async {
    final value = await _read(_devicePublicKeyKey);
    if (value == null) return null;
    return base64Decode(value);
  }

  /// Stores the device ID.
  Future<void> storeDeviceId(String deviceId) async {
    await _write(_deviceIdKey, deviceId);
  }

  /// Retrieves the device ID.
  Future<String?> getDeviceId() async {
    return await _read(_deviceIdKey);
  }

  /// Caches the unwrapped UMK locally (encrypted at rest by platform).
  ///
  /// This allows faster startup without network access.
  Future<void> cacheUnwrappedUMK(Uint8List umk) async {
    await _write(_umkCacheKey, base64Encode(umk));
  }

  /// Retrieves the cached UMK.
  Future<Uint8List?> getCachedUMK() async {
    final value = await _read(_umkCacheKey);
    if (value == null) return null;
    return base64Decode(value);
  }

  /// Clears the cached UMK.
  Future<void> clearCachedUMK() async {
    await _delete(_umkCacheKey);
  }

  /// Stores the "remember this device" preference.
  Future<void> setRememberDevice(bool remember) async {
    await _write(_rememberDeviceKey, remember.toString());
  }

  /// Retrieves the "remember this device" preference.
  /// Defaults to true if not set.
  Future<bool> getRememberDevice() async {
    if (kIsWeb) return true;
    final value = await _read(_rememberDeviceKey);
    if (value == null) return true; // Default to remembering
    return value.toLowerCase() == 'true';
  }

  /// Caches the device approval status locally for fast startup.
  ///
  /// Valid values: 'approved', 'pending', 'revoked'
  Future<void> cacheDeviceStatus(String status, {bool deviceDeleted = false}) =>
      _mutations.run('keys', () async {
        requireCloudOperation();
        if (kIsWeb && status == 'approved') await _rememberApprovedBrowser();
        await _writeDirect(_deviceStatusKey, status);
        if (kIsWeb && status != 'approved') {
          _webMemory.remove(_scopedKey(_umkCacheKey));
          await _updateBrowserIdentity(
            null,
            revoked: status == 'revoked',
            deviceDeleted: deviceDeleted,
          );
        }
      });

  Future<bool> _rememberApprovedBrowser() async {
    // Managed review identities are local-only. Legacy imports retain their
    // original recovery source until the user completes recovery setup.
    if (ReviewAccess.isReviewIdentity(FirebaseBackend.auth.currentUser) ||
        _legacyUid != null) {
      return false;
    }
    if (_browserUid == null ||
        !await hasDeviceKeys() ||
        await getCachedUMK() == null) {
      throw BrowserApprovalNotReady('Approved browser keys unavailable');
    }
    final values = <String, String>{
      if (_libraryGeneration case final String generation)
        'library': generation,
      for (final key in _identityKeys)
        if (_webMemory[_scopedKey(key)] case final String value) key: value,
    };
    final request = values[_approvalRequestKey];
    if (request != null &&
        (values[_acceptedApprovalKey] == null ||
            DeviceVerificationRequest.fromLocalData(request)
                .hasPairingSecret)) {
      throw BrowserApprovalNotReady('Unverified browser identity');
    }
    if (_browserRevision == null || _libraryGeneration == null) return false;
    final previous = _savedIdentity;
    final saved = previous == null ? null : jsonDecode(previous) as Map;
    final sameDevice = saved?[_deviceIdKey] == values[_deviceIdKey];
    final existing = sameDevice ? (saved?['offlineGrant'] as String?) : null;
    String? created;
    try {
      // A stale tab must never recreate a retired grant.
      if (existing != null &&
          browser.offlineGrantState(existing) !=
              browser.OfflineGrantState.active) {
        return false;
      }
      values['offlineGrant'] =
          existing ?? (created = browser.newOfflineGrantId());
      await _updateBrowserIdentity(
        jsonEncode(values),
        nextGrant: values['offlineGrant'],
        activateGrant: created,
      );
      return true;
    } catch (error) {
      _retireOfflineGrant(created);
      requireCloudOperation();
      AppLogger.log('Browser approval is session-only (${error.runtimeType})');
      return false;
    }
  }

  void _retireOfflineGrant(String? id) {
    if (id == null) return;
    try {
      browser.retireOfflineGrant(id);
    } catch (error) {
      // IndexedDB retirement still runs if Web Storage is inaccessible.
      AppLogger.log('Browser grant storage unavailable (${error.runtimeType})');
    }
  }

  bool _invalidateSavedGrant({required bool revoked}) {
    final id = _storedGrantId;
    if (id == null || _savedIdentity == null) return false;
    try {
      browser.invalidateOfflineGrant(id, revoked: revoked);
      return true;
    } catch (error) {
      AppLogger.log('Browser grant storage unavailable (${error.runtimeType})');
      return false;
    }
  }

  Future<void> _updateBrowserIdentity(
    String? identity, {
    String? nextGrant,
    String? activateGrant,
    bool revoked = false,
    bool deviceDeleted = false,
  }) async {
    // Retire the exact grant observed by this tab even if another writer
    // advanced the record or IndexedDB is unavailable.
    final retireNow = revoked || deviceDeleted;
    var grantRetired = retireNow && _invalidateSavedGrant(revoked: revoked);
    if (identity == _savedIdentity) return;
    final uid = _browserUid;
    final scope = _browserScope;
    final revision = _browserRevision;
    if (uid == null || scope == null || revision == null) {
      throw StateError('Browser approval storage is unavailable');
    }
    final operationCurrent = captureCloudOperation();
    bool current() =>
        operationCurrent() &&
        FirebaseBackend.auth.currentUser?.uid == uid &&
        _trustScope == scope;
    Future<int> write(int expected) => browser.writeDeviceIdentity(
      scope,
      uid,
      identity,
      expectedRevision: expected,
      isCurrent: current,
      grantToActivate: activateGrant,
      beforeClear: retireNow
          ? null
          : () {
              grantRetired = _invalidateSavedGrant(revoked: false);
            },
    );

    try {
      _browserRevision = await write(revision);
    } on browser.BrowserIdentityConflict {
      // Reconcile only writes derived from a still-active remembered identity.
      // A missing, replaced or revoked grant must never be revived by a retry.
      if (identity == null || _savedIdentity == null || activateGrant != null) {
        rethrow;
      }
      final (latest, stored) = await browser.readDeviceIdentity(scope, uid);
      if (!current() ||
          browser.offlineGrantState(nextGrant) !=
              browser.OfflineGrantState.active) {
        rethrow;
      }
      if (stored == identity) {
        _browserRevision = latest;
      } else if (stored == _savedIdentity) {
        _browserRevision = await write(latest);
      } else {
        rethrow;
      }
    } catch (error) {
      requireCloudOperation();
      if (!grantRetired) rethrow;
      // The obsolete record cannot reopen the library. Keep its fence in
      // memory so this tab cannot mint a replacement on a stale approval.
      AppLogger.log(
        'Retired offline grant; trust record cleanup deferred (${error.runtimeType})',
      );
      return;
    }
    // A stale clear is a no-op. Its revision stays unchanged, and a newer
    // record may still need the grant's explicit revocation marker.
    if (_browserRevision == revision) return;
    if (_storedGrantId != nextGrant) _retireOfflineGrant(_storedGrantId);
    _storedGrantId = nextGrant;
    _savedIdentity = identity;
  }

  /// Retrieves the cached device status.
  ///
  /// Returns null if no status is cached.
  Future<String?> getCachedDeviceStatus() async {
    return await _read(_deviceStatusKey);
  }

  /// Clears the cached device status.
  Future<void> clearDeviceStatus() async {
    await _delete(_deviceStatusKey);
  }

  /// Sets flag indicating sign-in is in progress.
  /// Used to detect interrupted sign-in on app restart.
  Future<void> setSignInProgress(bool inProgress) async {
    if (inProgress) {
      await _write(_signInProgressKey, 'true');
    } else {
      await _delete(_signInProgressKey);
    }
  }

  /// Checks if a sign-in was interrupted (app crashed/refreshed during sign-in).
  Future<bool> wasSignInInterrupted() async {
    final value = await _read(_signInProgressKey);
    return value == 'true';
  }

  /// Both local namespaces belong to the removed iOS installation. Clear only
  /// its Better Keep identities, before authenticated writers or key restores
  /// start. The caller must corroborate that no previous local library exists.
  Future<void> clearIosInstallIdentities() async {
    for (final scope in FirebaseLocalDataScope.values) {
      for (final key in _keys) {
        await _secureStorage.delete(key: scope.secureStorageKey(key));
      }
    }
  }

  /// Clears all E2EE data (for logout or key rotation).
  Future<void> clearAll({
    bool signingOut = false,
    String? revokedDeviceId,
  }) => _mutations.run('keys', () async {
    requireCloudOperation();
    if (kIsWeb) {
      final scope = _trustScope;
      final operationCurrent = captureCloudOperation();
      final uid = _browserUid ?? FirebaseBackend.auth.currentUser?.uid ?? '';
      if (signingOut) _invalidateSavedGrant(revoked: false);
      if (signingOut || _browserRevision != null) {
        final revision = _browserRevision;
        try {
          _browserRevision = await browser.writeDeviceIdentity(
            scope,
            uid,
            null,
            expectedRevision: signingOut ? null : revision,
            isCurrent: () => operationCurrent() && _trustScope == scope,
            beforeClear: signingOut
                ? null
                : () => _invalidateSavedGrant(revoked: false),
          );
          if (signingOut || _browserRevision != revision) {
            _retireOfflineGrant(_storedGrantId);
          }
        } catch (_) {
          if (!signingOut) rethrow;
          var clearedOrRevoked = false;
          String? remainingLibrary;
          if (uid.isNotEmpty) {
            try {
              final (_, remaining) = await browser.readDeviceIdentity(
                scope,
                uid,
              );
              final identity = remaining == null
                  ? null
                  : jsonDecode(remaining) as Map<String, dynamic>;
              remainingLibrary = identity?['library'] as String?;
              clearedOrRevoked =
                  identity == null ||
                  (revokedDeviceId != null &&
                      identity[_deviceIdKey] == revokedDeviceId);
            } catch (_) {
              // An unreadable slot cannot prove that the identity was cleared.
            }
          }
          if (!clearedOrRevoked) {
            final prefs = await SharedPreferences.getInstance();
            await FirebaseScopedPreferences.reload(prefs);
            final next = LocalStorageRecovery(prefs).signOutSnapshot.journal;
            if (next == null || next == remainingLibrary) rethrow;
            requireCloudOperation();
            await retireAccountFiles(prefs, next);
            await FirebaseScopedPreferences.reload(prefs);
            if (currentAccountFileGeneration(prefs) != next) {
              throw StateError('Could not verify browser library retirement');
            }
          }
          requireCloudOperation();
          // The sign-out journal rotates the library before reopening it.
        }
      }
      _savedIdentity = _storedGrantId = null;
    }
    for (final key in _keys) {
      requireCloudOperation();
      await _deleteDirect(key);
    }
    _legacyUid = null;
    if (signingOut) {
      _browserUid = _browserScope = _savedIdentity = _storedGrantId = null;
      _browserRevision = null;
    }
  });

  /// Checks if device keys exist.
  Future<bool> hasDeviceKeys() async {
    final privateKey = await _read(_devicePrivateKeyKey);
    final publicKey = await _read(_devicePublicKeyKey);
    final deviceId = await _read(_deviceIdKey);
    if (privateKey == null && publicKey == null && deviceId == null) {
      return false;
    }
    if (privateKey == null ||
        publicKey == null ||
        deviceId == null ||
        deviceId.isEmpty ||
        base64Decode(privateKey).length != 32 ||
        base64Decode(publicKey).length != 32) {
      throw const FormatException('Incomplete or invalid device keys');
    }
    return true;
  }

  // Platform-aware read; browser values exist only in this session.
  Future<String?> _read(String key) async {
    final scopedKey = _scopedKey(key);
    if (kIsWeb) {
      if (_browserUid != FirebaseBackend.auth.currentUser?.uid ||
          _browserScope != _trustScope) {
        return null;
      }
      return _webMemory[scopedKey];
    }
    try {
      return await _secureStorage.read(key: scopedKey);
    } catch (e) {
      // Native secure storage can throw on iOS (Keychain errors after backup
      // restore, biometric changes) and Android (KeyStore corruption, OS
      // updates). Preserve the distinction from an absent key so callers
      // cannot replace existing material after a failed read.
      AppLogger.error('E2EE: Secure storage read failed for key $scopedKey', e);
      throw SecureStorageUnavailable(e);
    }
  }

  // Platform-aware write; native values use secure storage.
  Future<void> _write(String key, String value) =>
      _mutations.run('keys', () async {
        requireCloudOperation();
        await _writeDirect(key, value);
      });

  Future<void> _writeDirect(String key, String value) async {
    final scopedKey = _scopedKey(key);
    if (kIsWeb) {
      requireCloudOperation();
      _webMemory[scopedKey] = value;
    } else {
      try {
        await _secureStorage.write(key: scopedKey, value: value);
      } catch (e) {
        AppLogger.error(
          'E2EE: Secure storage write failed for key $scopedKey',
          e,
        );
        rethrow;
      }
    }
  }

  // Platform-aware delete
  Future<void> _delete(String key) => _mutations.run('keys', () async {
    requireCloudOperation();
    await _deleteDirect(key);
  });

  Future<void> _deleteDirect(String key) async {
    final scopedKey = _scopedKey(key);
    if (kIsWeb) {
      _webMemory.remove(scopedKey);
      if (key == _umkCacheKey || key == _deviceStatusKey) {
        await _updateBrowserIdentity(null);
      }
      final prefs = await SharedPreferences.getInstance();
      requireCloudOperation();
      if (!await prefs.remove(scopedKey)) {
        throw StateError('Could not clear browser key storage');
      }
    } else {
      await _secureStorage.delete(key: scopedKey);
    }
  }

  String _scopedKey(String key) =>
      FirebaseBackend.localDataScope.secureStorageKey(key);
}

/// Device information utilities.
class DeviceInfo {
  static final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();

  /// Gets detailed device information.
  static Future<Map<String, String?>> getDeviceDetails() async {
    final details = <String, String?>{};

    if (kIsWeb) {
      try {
        final webInfo = await _deviceInfoPlugin.webBrowserInfo;
        details['browser_name'] = webInfo.browserName.name;
        details['browser_version'] =
            webInfo.appVersion?.split(' ').first ?? 'unknown';
        details['os'] = _parseOsFromUserAgent(webInfo.userAgent ?? '');
        details['user_agent'] = webInfo.userAgent;
        details['platform'] = webInfo.platform;
        details['vendor'] = webInfo.vendor;
        details['language'] = webInfo.language;
      } catch (_) {
        // Device info retrieval is best-effort; return partial data on failure
      }
      return details;
    }

    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfoPlugin.androidInfo;
        details['manufacturer'] = androidInfo.manufacturer;
        details['model'] = androidInfo.model;
        details['brand'] = androidInfo.brand;
        details['device'] = androidInfo.device;
        details['os_version'] = 'Android ${androidInfo.version.release}';
        details['sdk_version'] = androidInfo.version.sdkInt.toString();
        details['hardware'] = androidInfo.hardware;
        details['product'] = androidInfo.product;
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfoPlugin.iosInfo;
        details['manufacturer'] = 'Apple';
        details['model'] = iosInfo.utsname.machine;
        details['model_name'] = iosInfo.model;
        details['device_name'] = iosInfo.name;
        details['os_version'] = 'iOS ${iosInfo.systemVersion}';
        details['system_name'] = iosInfo.systemName;
      } else if (Platform.isMacOS) {
        final macInfo = await _deviceInfoPlugin.macOsInfo;
        details['manufacturer'] = 'Apple';
        details['model'] = macInfo.model;
        details['computer_name'] = macInfo.computerName;
        details['os_version'] =
            'macOS ${macInfo.majorVersion}.${macInfo.minorVersion}.${macInfo.patchVersion}';
        details['arch'] = macInfo.arch;
        details['host_name'] = macInfo.hostName;
      } else if (Platform.isWindows) {
        final windowsInfo = await _deviceInfoPlugin.windowsInfo;
        details['manufacturer'] = 'Microsoft';
        details['computer_name'] = windowsInfo.computerName;
        details['os_version'] =
            'Windows ${windowsInfo.majorVersion}.${windowsInfo.minorVersion}';
        details['build_number'] = windowsInfo.buildNumber.toString();
        details['product_name'] = windowsInfo.productName;
        details['device_id'] = windowsInfo.deviceId;
      } else if (Platform.isLinux) {
        final linuxInfo = await _deviceInfoPlugin.linuxInfo;
        details['manufacturer'] = 'Linux';
        details['distribution'] = linuxInfo.name;
        details['os_version'] = linuxInfo.versionId ?? linuxInfo.version;
        details['pretty_name'] = linuxInfo.prettyName;
        details['machine_id'] = linuxInfo.machineId;
      }
    } catch (_) {
      // Device info retrieval is best-effort; return partial data on failure
    }

    return details;
  }

  /// Parses OS name from user agent string.
  static String _parseOsFromUserAgent(String userAgent) {
    final ua = userAgent.toLowerCase();
    if (ua.contains('windows')) return 'Windows';
    if (ua.contains('mac os') || ua.contains('macintosh')) return 'macOS';
    if (ua.contains('iphone') || ua.contains('ipad')) return 'iOS';
    if (ua.contains('android')) return 'Android';
    if (ua.contains('linux')) return 'Linux';
    if (ua.contains('cros')) return 'Chrome OS';
    return 'Unknown';
  }

  /// Gets a human-readable device name with more detail.
  static Future<String> getDeviceName() async {
    if (kIsWeb) {
      try {
        final webInfo = await _deviceInfoPlugin.webBrowserInfo;
        final browserName = _formatBrowserName(webInfo.browserName.name);
        final os = _parseOsFromUserAgent(webInfo.userAgent ?? '');
        return '$browserName on $os';
      } catch (_) {
        // Fall back to generic name on failure
      }
      return 'Web Browser';
    }

    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfoPlugin.androidInfo;
        final brand = _capitalize(androidInfo.brand);
        return '$brand ${androidInfo.model}';
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfoPlugin.iosInfo;
        return _formatIosModel(iosInfo.utsname.machine, iosInfo.model);
      } else if (Platform.isMacOS) {
        final macInfo = await _deviceInfoPlugin.macOsInfo;
        return macInfo.computerName.isNotEmpty
            ? macInfo.computerName
            : 'Mac (${macInfo.model})';
      } else if (Platform.isWindows) {
        final windowsInfo = await _deviceInfoPlugin.windowsInfo;
        return windowsInfo.computerName.isNotEmpty
            ? windowsInfo.computerName
            : 'Windows PC';
      } else if (Platform.isLinux) {
        final linuxInfo = await _deviceInfoPlugin.linuxInfo;
        return linuxInfo.prettyName.isNotEmpty ? linuxInfo.prettyName : 'Linux';
      }
    } catch (_) {
      // Fall back to generic name on failure
    }

    return 'Unknown Device';
  }

  /// Formats browser name to be more readable.
  static String _formatBrowserName(String browserName) {
    switch (browserName.toLowerCase()) {
      case 'chrome':
        return 'Chrome';
      case 'firefox':
        return 'Firefox';
      case 'safari':
        return 'Safari';
      case 'edge':
        return 'Edge';
      case 'opera':
        return 'Opera';
      case 'ie':
        return 'Internet Explorer';
      case 'samsung':
        return 'Samsung Internet';
      default:
        return _capitalize(browserName);
    }
  }

  /// Formats iOS model identifier to readable name.
  static String _formatIosModel(String machineId, String modelName) {
    // machineId looks like "iPhone14,5" - we'll use modelName if available
    if (modelName.isNotEmpty) {
      return modelName; // e.g., "iPhone", "iPad"
    }
    return machineId;
  }

  /// Capitalizes the first letter of a string.
  static String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1).toLowerCase();
  }

  /// Gets the current platform as a string.
  static String getCurrentPlatform() {
    if (kIsWeb) return 'web';

    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {
      // Platform detection failed; return unknown
    }

    return 'unknown';
  }
}
