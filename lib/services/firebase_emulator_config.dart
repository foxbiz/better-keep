import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_backend.dart';
import 'firebase_emulator_host.dart';

export 'firebase_emulator_host.dart';

/// Selects and configures the Firebase backend used by debug builds.
///
/// Firebase SDK emulator routing is process-wide and must be finalized before
/// Auth, Firestore, Functions, or Storage is otherwise used.
class FirebaseEmulatorConfig {
  static const String _legacyEnvironmentPrefsKey =
      'debug_firebase_use_emulators';
  static const String _environmentPrefsKey = 'debug_firebase_environment';
  static const String _hostPrefsKey = 'debug_firebase_emulator_host';
  static const String _googleAuthModePrefsKey =
      'debug_firebase_google_auth_mode';
  static const String _runtimeEmulatorHostPrefsKey =
      'debug_firebase_runtime_emulator_host';
  static const String _runtimeEmulatorAppNamePrefsKey =
      'debug_firebase_runtime_emulator_app_name';
  static const String _definedPhysicalDeviceHost = String.fromEnvironment(
    'EMULATOR_HOST',
  );

  static SharedPreferences? _prefs;
  static bool _isAndroidEmulator = false;
  static bool _isIOSSimulator = false;

  static FirebaseEmulatorSettings get settings {
    final active = FirebaseBackend.active;
    return FirebaseEmulatorSettings(
      environment: active.environment,
      endpoints: active.endpoints,
      googleAuthMode: active.googleAuthMode,
    );
  }

  static FirebaseEnvironment get environment => FirebaseBackend.environment;
  static bool get isUsingEmulators =>
      FirebaseBackend.environment == FirebaseEnvironment.emulator;
  static GoogleEmulatorAuthMode get googleAuthMode =>
      FirebaseBackend.active.googleAuthMode;

  static FirebaseEmulatorEndpoints get endpoints {
    final configuredEndpoints = FirebaseBackend.active.endpoints;
    if (configuredEndpoints == null) {
      throw StateError('Firebase emulator endpoints are not configured.');
    }
    return configuredEndpoints;
  }

  static bool get isPhysicalDevice {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return !_isAndroidEmulator;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return !_isIOSSimulator;
    }
    return false;
  }

  static bool get supportsRealGoogleAuthToggle {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  static String get suggestedPhysicalDeviceHost {
    final savedHost = _prefs?.getString(_hostPrefsKey)?.trim();
    if (savedHost != null && savedHost.isNotEmpty) return savedHost;
    return _definedPhysicalDeviceHost.trim();
  }

  static void init(SharedPreferences prefs) {
    _prefs = prefs;
  }

  /// Detects whether platform-specific loopback aliases can be used.
  static Future<void> initDeviceInfo() async {
    if (kIsWeb) return;
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      _isAndroidEmulator = !androidInfo.isPhysicalDevice;
    } else if (Platform.isIOS) {
      final iosInfo = await DeviceInfoPlugin().iosInfo;
      _isIOSSimulator = !iosInfo.isPhysicalDevice;
    } else if (Platform.isMacOS) {
      _isIOSSimulator = true;
    }
  }

  static GoogleEmulatorAuthMode get savedGoogleAuthMode {
    final value = _prefs?.getString(_googleAuthModePrefsKey);
    return value == GoogleEmulatorAuthMode.real.name
        ? GoogleEmulatorAuthMode.real
        : GoogleEmulatorAuthMode.mock;
  }

  static String _resolveHost(String? physicalDeviceHost) {
    var lanHost = physicalDeviceHost?.trim() ?? suggestedPhysicalDeviceHost;
    if (isPhysicalDevice) {
      lanHost = normalizePhysicalFirebaseEmulatorHost(lanHost);
    }
    return selectFirebaseEmulatorHost(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      isAndroidEmulator: _isAndroidEmulator,
      isAppleSimulator: _isIOSSimulator,
      physicalDeviceHost: lanHost,
    );
  }

  static Future<void> _saveSettings(FirebaseEmulatorSettings settings) async {
    final prefs = _prefs;
    if (prefs == null) return;

    // Debug builds ask for the environment on every cold launch. Remove
    // obsolete saved choices while retaining reusable emulator details.
    await prefs.remove(_environmentPrefsKey);
    await prefs.remove(_legacyEnvironmentPrefsKey);
    if (settings.usesEmulators) {
      await prefs.setString(
        _googleAuthModePrefsKey,
        settings.googleAuthMode.name,
      );
      await prefs.remove('debug_firebase_test_identity');
      if (isPhysicalDevice) {
        await prefs.setString(_hostPrefsKey, settings.endpoints!.host);
      }
      await prefs.setString(
        _runtimeEmulatorHostPrefsKey,
        settings.endpoints!.host,
      );
      await prefs.setString(
        _runtimeEmulatorAppNamePrefsKey,
        FirebaseBackend.app.name,
      );
    }
  }

  static Future<void> connectToEmulators({
    String? physicalDeviceHost,
    GoogleEmulatorAuthMode googleAuthMode = GoogleEmulatorAuthMode.mock,
  }) async {
    if (!kDebugMode) {
      throw StateError('Firebase emulators are only available in debug mode.');
    }

    final host = _resolveHost(physicalDeviceHost);
    final emulatorEndpoints = FirebaseEmulatorEndpoints(host);
    debugPrint('Firebase Emulators: Connecting');
    for (final service in emulatorEndpoints.requiredServices.entries) {
      debugPrint('  ${service.key}: $host:${service.value}');
    }

    // Browsers cannot open raw TCP sockets. Their SDK requests surface an
    // equivalent error while configuring or making the first request.
    if (!kIsWeb) {
      await _verifyRequiredServices(emulatorEndpoints);
    }

    try {
      final savedRuntimeHost = _prefs?.getString(_runtimeEmulatorHostPrefsKey);
      final preferredAppName = savedRuntimeHost == host
          ? _prefs?.getString(_runtimeEmulatorAppNamePrefsKey)
          : null;
      await FirebaseBackend.configureEmulator(
        endpoints: emulatorEndpoints,
        googleAuthMode: googleAuthMode,
        preferredAppName: preferredAppName,
      );
    } catch (error) {
      final discardedAppName =
          FirebaseBackend.takeLastDiscardedEmulatorAppName();
      if (discardedAppName != null &&
          _prefs?.getString(_runtimeEmulatorAppNamePrefsKey) ==
              discardedAppName) {
        await _prefs?.remove(_runtimeEmulatorAppNamePrefsKey);
        await _prefs?.remove(_runtimeEmulatorHostPrefsKey);
      }
      throw FirebaseEmulatorRoutingException(error);
    }

    try {
      await _saveSettings(settings);
    } catch (error) {
      debugPrint(
        'Firebase Emulators: Could not save reusable chooser details: $error',
      );
    }
    debugPrint('Firebase Emulators: Setup complete');
  }

  static Future<void> _verifyRequiredServices(
    FirebaseEmulatorEndpoints emulatorEndpoints,
  ) async {
    final failures = <String, Object>{};
    await Future.wait(
      emulatorEndpoints.requiredServices.entries.map((service) async {
        try {
          final socket = await Socket.connect(
            emulatorEndpoints.host,
            service.value,
            timeout: const Duration(seconds: 2),
          );
          socket.destroy();
        } catch (error) {
          failures['${service.key} (${service.value})'] = error;
        }
      }),
    );

    if (failures.isNotEmpty) {
      throw FirebaseEmulatorUnavailableException(
        host: emulatorEndpoints.host,
        failures: failures,
      );
    }
  }

  /// Verifies the authenticated Firestore SDK route before cloud services
  /// start. A raw port check cannot detect an SDK connected to the wrong
  /// database, host, or project.
  static Future<void> verifyAuthenticatedFirestore(User user) async {
    if (!isUsingEmulators) return;

    final projectId = FirebaseBackend.projectId;
    final host = FirebaseBackend.emulatorHost ?? endpoints.host;
    final databaseId = FirebaseBackend.databaseId;

    try {
      await FirebaseBackend.firestore
          .collection('users')
          .doc(user.uid)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      debugPrint(
        'Firebase Emulator Firestore probe succeeded: '
        'project=$projectId database=$databaseId host=$host '
        'uid=${user.uid} code=ok',
      );
    } catch (error) {
      final code = error is FirebaseException ? error.code : 'unknown';
      debugPrint(
        'Firebase Emulator Firestore probe failed: '
        'project=$projectId database=$databaseId host=$host '
        'uid=${user.uid} code=$code error=$error',
      );
      throw FirebaseEmulatorFirestoreProbeException(
        projectId: projectId,
        databaseId: databaseId,
        host: host,
        uid: user.uid,
        code: code,
        cause: error,
      );
    }
  }

  static Future<void> useLiveFirebase() async {
    FirebaseBackend.configureLive();
    try {
      await _saveSettings(settings);
    } catch (error) {
      debugPrint('Firebase: Could not update chooser preferences: $error');
    }
    debugPrint('Firebase: Using live Firebase services');
  }
}
