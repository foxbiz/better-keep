import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Configuration for Firebase Emulators in debug mode.
///
/// Automatically connects to emulators in debug builds.
class FirebaseEmulatorConfig {
  /// Emulator host - localhost for most platforms, 10.0.2.2 for Android emulator
  static String get _host {
    if (kIsWeb) return 'localhost';
    if (Platform.isAndroid) return '10.0.2.2';
    return 'localhost';
  }

  /// Connect to Firebase Emulators in debug mode.
  /// Call this after Firebase.initializeApp() and before any Firebase usage.
  static Future<void> configureEmulators() async {
    if (!kDebugMode) {
      return;
    }

    debugPrint('Firebase Emulators: Connecting (debug mode)');
    debugPrint('  Auth: $_host:9099');
    debugPrint('  Firestore: $_host:8080');
    debugPrint('  Functions: $_host:5001');
    debugPrint('  Storage: $_host:9199');

    try {
      // Auth Emulator
      await FirebaseAuth.instance.useAuthEmulator(_host, 9099);

      // Firestore Emulator
      FirebaseFirestore.instance.useFirestoreEmulator(_host, 8080);

      // Functions Emulator
      FirebaseFunctions.instance.useFunctionsEmulator(_host, 5001);

      // Storage Emulator
      await FirebaseStorage.instance.useStorageEmulator(_host, 9199);
    } catch (e) {
      debugPrint('Error configuring Firebase Emulators: $e');
    }
  }
}
