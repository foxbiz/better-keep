import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_emulator_host.dart';

/// Configuration for Firebase Emulators in debug mode.
///
/// Shows a dialog to let the user choose between emulator or live Firebase.
/// The choice is persisted until app data is cleared or reinstalled.
class FirebaseEmulatorConfig {
  /// SharedPreferences key for storing the Firebase environment choice
  static const String _prefsKey = 'debug_firebase_use_emulators';

  /// Whether the app is using emulators (only relevant in debug mode)
  static bool _useEmulators = false;

  /// Whether the app is using emulators
  static bool get isUsingEmulators => _useEmulators;

  /// Cached SharedPreferences instance
  static SharedPreferences? _prefs;

  /// True when running on the Android emulator (not a physical device)
  static bool _isAndroidEmulator = false;

  /// True when running on the iOS/macOS simulator (not a physical device)
  static bool _isIOSSimulator = false;

  /// Host machine address used by physical devices on the local network.
  static const String _physicalDeviceHost = '192.168.0.109';

  /// Detect whether we're running on a simulator/emulator or a physical device.
  /// Must be called before [connectToEmulators].
  static Future<void> initDeviceInfo() async {
    if (kIsWeb) return;
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      _isAndroidEmulator = !androidInfo.isPhysicalDevice;
    } else if (Platform.isIOS) {
      final iosInfo = await DeviceInfoPlugin().iosInfo;
      _isIOSSimulator = !iosInfo.isPhysicalDevice;
    } else if (Platform.isMacOS) {
      // macOS runs natively on the same machine as the emulators
      _isIOSSimulator = true;
    }
  }

  static String get _host {
    return selectFirebaseEmulatorHost(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      isAndroidEmulator: _isAndroidEmulator,
      isAppleSimulator: _isIOSSimulator,
      physicalDeviceHost: _physicalDeviceHost,
    );
  }

  /// Initialize with SharedPreferences instance
  static void init(SharedPreferences prefs) {
    _prefs = prefs;
  }

  /// Check if user has already made a choice (saved in preferences)
  static bool get hasSavedChoice {
    return _prefs?.containsKey(_prefsKey) ?? false;
  }

  /// Get the saved choice (true = emulator, false = live)
  static bool? get savedChoice {
    return _prefs?.getBool(_prefsKey);
  }

  /// Save the user's choice to SharedPreferences
  static Future<void> _saveChoice(bool useEmulators) async {
    await _prefs?.setBool(_prefsKey, useEmulators);
  }

  /// Shows a dialog to let the user choose between emulator or live Firebase.
  /// Returns true if emulator was selected, false for live.
  static Future<bool> showFirebaseSelectionDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('🔧 Debug Mode'),
        content: const Text(
          'Select Firebase environment:\n\n'
          '• Emulator: Local development with Firebase emulators\n'
          '• Live: Production Firebase services\n\n'
          'This choice will be remembered.',
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.cloud, color: Colors.blue),
            label: const Text('Live'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.computer),
            label: const Text('Emulator'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Connect to Firebase Emulators in debug mode.
  /// Call this after Firebase.initializeApp() and before any Firebase usage.
  /// In debug mode, this waits for user selection via the UI.
  static Future<void> configureEmulators() async {
    if (!kDebugMode) {
      _useEmulators = false;
      return;
    }

    debugPrint(
      'Firebase Emulators: Debug mode - waiting for user selection...',
    );
  }

  /// Actually connects to emulators. Called after user makes their choice.
  static Future<void> connectToEmulators() async {
    debugPrint('Firebase Emulators: Connecting (debug mode)');
    debugPrint('  Auth:      $_host:9099');
    debugPrint('  Firestore: $_host:8080');
    debugPrint('  Functions: $_host:5001');
    debugPrint('  Storage:   $_host:9199');

    // Browsers cannot open raw TCP sockets. The Firebase web SDK performs the
    // reachability check through its normal HTTP requests instead.
    if (!kIsWeb) {
      try {
        final socket = await Socket.connect(
          _host,
          9099,
          timeout: const Duration(milliseconds: 500),
        );
        socket.destroy();
        debugPrint('Firebase Emulators: Network reachability OK ($_host:9099)');
      } catch (e) {
        debugPrint(
          'Firebase Emulators: NETWORK UNREACHABLE - cannot reach $_host:9099\n'
          '  Error: $e\n'
          '  Check: emulators running? firewall? correct IP?',
        );
        throw Exception(
          'Cannot reach emulator at $_host:9099.\n'
          'Make sure Firebase emulators are running and the host IP is correct.',
        );
      }
    }

    // Auth Emulator
    await FirebaseAuth.instance.useAuthEmulator(_host, 9099);
    debugPrint('Firebase Emulators: Auth connected');

    // Firestore Emulator
    FirebaseFirestore.instance.useFirestoreEmulator(_host, 8080);
    debugPrint('Firebase Emulators: Firestore connected');

    // Functions Emulator
    FirebaseFunctions.instance.useFunctionsEmulator(_host, 5001);
    debugPrint('Firebase Emulators: Functions connected');

    // Storage Emulator
    await FirebaseStorage.instance.useStorageEmulator(_host, 9199);
    debugPrint('Firebase Emulators: Storage connected');

    _useEmulators = true;
    await _saveChoice(true);
    debugPrint('Firebase Emulators: Setup complete');
  }

  /// Called when user selects to use live Firebase (no emulators)
  static Future<void> useLiveFirebase() async {
    _useEmulators = false;
    await _saveChoice(false);
    debugPrint('Firebase: Using live Firebase services');
  }

  /// Apply the saved choice without showing dialog
  static Future<void> applySavedChoice() async {
    final useEmulators = savedChoice ?? false;
    if (useEmulators) {
      try {
        await connectToEmulators();
      } catch (e) {
        // Saved choice is no longer valid (emulators unreachable).
        // Clear it so the selection screen is shown again next launch.
        await _prefs?.remove(_prefsKey);
        debugPrint('Firebase: Saved emulator choice failed, cleared: $e');
        rethrow;
      }
    } else {
      _useEmulators = false;
      debugPrint('Firebase: Using live Firebase services (from saved choice)');
    }
  }
}
