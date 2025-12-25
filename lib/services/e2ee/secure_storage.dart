/// Secure storage for E2EE keys and secrets.
///
/// Uses platform-specific secure storage (Keychain on iOS/macOS,
/// EncryptedSharedPreferences on Android, etc.) to store sensitive data.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure storage wrapper for E2EE keys.
///
/// On mobile platforms, uses flutter_secure_storage which leverages
/// platform secure storage (Keychain, Keystore).
///
/// On web, data is encrypted with an in-app key before storing in
/// localStorage. This provides a layer of protection against casual
/// cross-site access, though it is not equivalent to native platform
/// secure storage.
class E2EESecureStorage {
  // In-app encryption key for web storage (256-bit AES key as hex string)
  // Set via --dart-define=WEB_STORAGE_KEY=<64-char-hex-string>
  // This adds a layer of obfuscation - cross-site scripts cannot read
  // the raw keys directly from localStorage without knowing this key.
  static const String _webStorageKeyHex = String.fromEnvironment(
    'WEB_STORAGE_KEY',
    defaultValue: '',
  );

  static Uint8List? _webStorageKeyCache;
  static Uint8List get _webStorageKey {
    if (_webStorageKeyCache != null) return _webStorageKeyCache!;
    if (_webStorageKeyHex.isEmpty || _webStorageKeyHex.length != 64) {
      throw StateError(
        'WEB_STORAGE_KEY must be a 64-character hex string (256 bits). '
        'Set it via --dart-define=WEB_STORAGE_KEY=<your-key>',
      );
    }
    // Parse hex string to bytes
    final bytes = <int>[];
    for (var i = 0; i < 64; i += 2) {
      bytes.add(int.parse(_webStorageKeyHex.substring(i, i + 2), radix: 16));
    }
    _webStorageKeyCache = Uint8List.fromList(bytes);
    return _webStorageKeyCache!;
  }

  static final _webCipher = AesGcm.with256bits();
  static E2EESecureStorage? _instance;
  static E2EESecureStorage get instance {
    _instance ??= E2EESecureStorage._();
    return _instance!;
  }

  E2EESecureStorage._();

  // Storage keys
  static const String _devicePrivateKeyKey = 'e2ee_device_private_key';
  static const String _devicePublicKeyKey = 'e2ee_device_public_key';
  static const String _deviceIdKey = 'e2ee_device_id';
  static const String _umkCacheKey = 'e2ee_umk_cache';
  static const String _rememberDeviceKey = 'e2ee_remember_device';
  static const String _deviceStatusKey = 'e2ee_device_status';
  static const String _signInProgressKey = 'e2ee_sign_in_progress';

  // Secure storage instance (for native platforms)
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Web fallback
  SharedPreferences? _webPrefs;

  /// Initialize storage (required for web platform).
  Future<void> init() async {
    if (kIsWeb) {
      _webPrefs = await SharedPreferences.getInstance();
    }
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
    final value = await _read(_rememberDeviceKey);
    if (value == null) return true; // Default to remembering
    return value.toLowerCase() == 'true';
  }

  /// Caches the device approval status locally for fast startup.
  ///
  /// Valid values: 'approved', 'pending', 'revoked'
  Future<void> cacheDeviceStatus(String status) async {
    await _write(_deviceStatusKey, status);
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

  /// Clears all E2EE data (for logout or key rotation).
  Future<void> clearAll() async {
    await _delete(_devicePrivateKeyKey);
    await _delete(_devicePublicKeyKey);
    await _delete(_deviceIdKey);
    await _delete(_umkCacheKey);
    await _delete(_rememberDeviceKey);
    await _delete(_deviceStatusKey);
    await _delete(_signInProgressKey);
  }

  /// Checks if device keys exist.
  Future<bool> hasDeviceKeys() async {
    final privateKey = await _read(_devicePrivateKeyKey);
    final publicKey = await _read(_devicePublicKeyKey);
    final deviceId = await _read(_deviceIdKey);
    return privateKey != null && publicKey != null && deviceId != null;
  }

  // Platform-aware read (with decryption on web)
  Future<String?> _read(String key) async {
    if (kIsWeb) {
      final encrypted = _webPrefs?.getString(key);
      if (encrypted == null) return null;
      return await _webDecrypt(encrypted);
    }
    return await _secureStorage.read(key: key);
  }

  // Platform-aware write (with encryption on web)
  Future<void> _write(String key, String value) async {
    if (kIsWeb) {
      final encrypted = await _webEncrypt(value);
      await _webPrefs?.setString(key, encrypted);
    } else {
      await _secureStorage.write(key: key, value: value);
    }
  }

  // Encrypt value using in-app key for web storage
  Future<String> _webEncrypt(String value) async {
    final secretKey = SecretKey(_webStorageKey);
    final nonce = _webCipher.newNonce();
    final secretBox = await _webCipher.encrypt(
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
    return base64Encode(combined);
  }

  // Decrypt value using in-app key for web storage
  Future<String?> _webDecrypt(String encrypted) async {
    try {
      final combined = base64Decode(encrypted);
      const nonceLength = 12;
      const macLength = 16;
      if (combined.length < nonceLength + macLength) {
        // Invalid data or old unencrypted format - return null
        return null;
      }
      final nonce = combined.sublist(0, nonceLength);
      final cipherText = combined.sublist(
        nonceLength,
        combined.length - macLength,
      );
      final macBytes = combined.sublist(combined.length - macLength);

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
      final secretKey = SecretKey(_webStorageKey);
      final plaintext = await _webCipher.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return utf8.decode(plaintext);
    } catch (_) {
      // Decryption failed - might be old unencrypted data, return null
      return null;
    }
  }

  // Platform-aware delete
  Future<void> _delete(String key) async {
    if (kIsWeb) {
      await _webPrefs?.remove(key);
    } else {
      await _secureStorage.delete(key: key);
    }
  }
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
