import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/windows_auth_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  static final ValueNotifier<bool> isVerifying = ValueNotifier(false);

  static const String? _serverClientId = null;

  static Stream<User?> get userStream => _auth.authStateChanges();
  static User? get currentUser => _auth.currentUser;

  static Map<String, String>? _cachedProfile;
  static String? _localPhotoPath;

  // Subscription for token revocation listener
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _tokenRevocationSubscription;
  // Subscription for auth state changes
  static StreamSubscription<User?>? _authStateSubscription;
  // Cached token auth time to detect revocation
  static DateTime? _cachedTokenAuthTime;
  // Current user ID for revocation checks
  static String? _currentUserId;
  // Flag to indicate session is invalid (user deleted/disabled)
  // When true, sync should be disabled and user should be warned to re-login
  static final ValueNotifier<bool> sessionInvalid = ValueNotifier(false);

  static Map<String, String>? get cachedProfile => _cachedProfile;
  static String? get localPhotoPath => _localPhotoPath;

  static Future<void> init() async {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      await _googleSignIn.initialize(serverClientId: _serverClientId);
    }

    // Initialize file system with error handling
    FileSystem? fs;
    try {
      fs = await fileSystem();
    } catch (e) {
      AppLogger.error('Error initializing file system', e);
      // Continue without file system - profile image won't load
    }

    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('user_email');
    final uid = prefs.getString('user_uid');

    if (email != null) {
      _cachedProfile = {
        'email': email,
        'displayName': prefs.getString('user_displayName') ?? '',
        'photoURL': prefs.getString('user_photoURL') ?? '',
      };
      _localPhotoPath = prefs.getString('user_local_photo');

      if (fs != null &&
          (_localPhotoPath == null || !await fs.exists(_localPhotoPath!)) &&
          _cachedProfile!['photoURL']!.isNotEmpty) {
        _downloadProfileImage(_cachedProfile!['photoURL']!, uid: uid);
      }
    }

    // Start token revocation listener if user is already logged in
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      // Validate user session by trying to get a fresh token
      // This will fail if the user was deleted from Firebase Auth
      try {
        final idTokenResult = await currentUser.getIdTokenResult(true);
        _cachedTokenAuthTime = idTokenResult.authTime;
        _startTokenRevocationListener(currentUser.uid);
        AppLogger.log(
          "Initialized token revocation listener for existing user: ${currentUser.uid}",
        );
      } catch (e) {
        AppLogger.error("Error validating user session: $e");
        // If token validation fails, the user likely no longer exists in Firebase Auth
        // This can happen when:
        // 1. User was deleted from another device
        // 2. Auth emulator was restarted (dev environment)
        // 3. User account was disabled/deleted server-side
        // Mark session as invalid - user can still access local data but sync is disabled
        if (e.toString().contains('user-not-found') ||
            e.toString().contains('user-disabled') ||
            e.toString().contains('invalid-user-token') ||
            e.toString().contains('user-token-expired') ||
            e.toString().contains('400')) {
          AppLogger.log("User session invalid during init, disabling sync: $e");
          sessionInvalid.value = true;
          // Don't start token revocation listener since session is invalid
        } else {
          // For other errors (network issues, etc.), just log and continue
          // The user might still be valid, just temporarily unreachable
          AppLogger.log("Non-fatal error getting token auth time: $e");
        }
      }
    } else if (uid != null && email != null) {
      // We have cached user data but currentUser is null
      // This means Firebase Auth SDK already invalidated the session (e.g., on page refresh)
      // The user was previously logged in but their account no longer exists in Firebase Auth
      AppLogger.log(
        "No currentUser but have cached profile (uid: $uid), marking session as invalid",
      );
      AppLogger.log(
        "Session invalid: cached user data exists but Firebase currentUser is null",
      );
      sessionInvalid.value = true;
    }

    // Listen for auth state changes to start/stop the revocation listener
    _authStateSubscription?.cancel();
    _authStateSubscription = _auth.authStateChanges().listen((user) async {
      if (user != null && _tokenRevocationSubscription == null) {
        // User logged in and listener not running - start it
        _startTokenRevocationListener(user.uid);
        try {
          final idTokenResult = await user.getIdTokenResult();
          _cachedTokenAuthTime = idTokenResult.authTime;
        } catch (e) {
          AppLogger.error("Error getting token auth time on auth change: $e");
        }
      } else if (user == null) {
        // User logged out - stop the listener
        _stopTokenRevocationListener();
      }
    });
  }

  static Future<void> _downloadProfileImage(String url, {String? uid}) async {
    if (kIsWeb) return; // Skip downloading profile image on web for now
    try {
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final fs = await fileSystem();
        final bytes = await consolidateHttpClientResponseBytes(response);
        final dir = await fs.documentDir;
        final fileName = uid != null ? 'profile_$uid.jpg' : 'profile_image.jpg';
        final filePath = '$dir/$fileName';
        await fs.writeBytes(filePath, bytes);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_local_photo', filePath);
        _localPhotoPath = filePath;
      }
    } catch (e, stackTrace) {
      AppLogger.error('Error downloading profile image', e, stackTrace);
    }
  }

  static Future<UserCredential?> signInWithGoogle({
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;

      // Mark sign-in as in progress (for crash recovery)
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      UserCredential userCredential;

      if (kIsWeb) {
        // Web: Use signInWithPopup
        GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        userCredential = await _auth.signInWithPopup(googleProvider);
      } else if (Platform.isWindows || Platform.isLinux) {
        // Windows/Linux: Use custom loopback flow
        onStatusChange?.call("Opening browser for sign in...");
        final tokens = await WindowsAuthService.signIn();

        onStatusChange?.call("Logging in...");
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: tokens['idToken'],
          accessToken: tokens['accessToken'],
        );

        userCredential = await _auth.signInWithCredential(credential);
      } else {
        // Android/iOS/macOS: Use native google_sign_in
        if (!_googleSignIn.supportsAuthenticate()) {
          throw Exception("Google Sign-In not supported on this platform.");
        }

        final GoogleSignInAccount googleUser = await _googleSignIn
            .authenticate();

        onStatusChange?.call("Logging in...");

        final GoogleSignInAuthentication googleAuth = googleUser.authentication;

        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
          accessToken: null,
        );

        userCredential = await _auth.signInWithCredential(credential);
      }

      if (userCredential.user != null) {
        try {
          await _ensureUserExists(userCredential.user!, onStatusChange);
          // Initialize E2EE after successful login
          onStatusChange?.call("Initializing encryption...");
          await E2EEService.instance.initialize();
          // Initialize device approval notifications
          DeviceApprovalNotificationService().init();
          // Start listening for token revocation
          _startTokenRevocationListener(userCredential.user!.uid);
          // Cache the token auth time for revocation detection
          final idTokenResult = await userCredential.user!.getIdTokenResult();
          _cachedTokenAuthTime = idTokenResult.authTime;
          // Clear sign-in progress flag on success
          await E2EESecureStorage.instance.setSignInProgress(false);
        } catch (e) {
          await signOut();
          rethrow;
        }
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with Google', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  static Future<void> _ensureUserExists(
    User user,
    Function(String)? onStatusChange,
  ) async {
    // Use the named database
    final firestore = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: DefaultFirebaseOptions.databaseId,
    );
    AppLogger.log(
      "AuthService using databaseId: ${DefaultFirebaseOptions.databaseId}",
    );
    final userRef = firestore.collection('users').doc(user.uid);

    int attempts = 0;
    while (attempts < 3) {
      try {
        attempts++;
        onStatusChange?.call("Verifying user profile (Attempt $attempts)...");

        // We remove Source.server to allow the SDK to optimize,
        // but we still expect a connection for the first login.
        final doc = await userRef.get().timeout(const Duration(seconds: 30));

        if (!doc.exists) {
          onStatusChange?.call("Registering new user...");
          await userRef
              .set({
                'email': user.email,
                'displayName': user.displayName,
                'photoURL': user.photoURL,
                'createdAt': FieldValue.serverTimestamp(),
                'lastSeen': FieldValue.serverTimestamp(),
              })
              .timeout(const Duration(seconds: 30));
          // Trial subscription is automatically set up by Cloud Functions (beforeUserCreated)
        } else {
          // Check if user had scheduled deletion and cancel it via Cloud Function
          final data = doc.data();
          if (data != null && data['scheduledDeletion'] != null) {
            onStatusChange?.call("Cancelling scheduled deletion...");
            AppLogger.log(
              "Found scheduled deletion, calling cancelScheduledDeletion Cloud Function",
            );
            try {
              // Call Cloud Function to cancel deletion (sends email notification)
              final functions = FirebaseFunctions.instance;
              final callable = functions.httpsCallable(
                'cancelScheduledDeletion',
              );
              final result = await callable.call();
              AppLogger.log(
                "Cancelled scheduled deletion via Cloud Function for user: ${user.uid}, result: ${result.data}",
              );
              AppLogger.log(
                "Account deletion cancelled successfully for user: ${user.uid}",
              );
            } catch (e, stack) {
              // Fallback to direct Firestore update if Cloud Function fails
              AppLogger.log(
                "Cloud Function failed, falling back to direct update: $e",
              );
              AppLogger.log(
                "cancelScheduledDeletion Cloud Function failed: $e\n$stack",
              );
              await userRef
                  .update({
                    'scheduledDeletion': FieldValue.delete(),
                    'tokensRevokedAt': FieldValue.delete(),
                    'lastSeen': FieldValue.serverTimestamp(),
                  })
                  .timeout(const Duration(seconds: 30));
              AppLogger.log(
                "Cancelled scheduled deletion directly for user: ${user.uid}",
              );
            }
          } else {
            AppLogger.log("No scheduled deletion found for user: ${user.uid}");
            await userRef
                .update({'lastSeen': FieldValue.serverTimestamp()})
                .timeout(const Duration(seconds: 30));
          }
        }

        // Cache user profile locally
        final prefs = await SharedPreferences.getInstance();
        final fs = await fileSystem();

        await prefs.setString('user_email', user.email ?? '');
        await prefs.setString('user_displayName', user.displayName ?? '');
        await prefs.setString('user_photoURL', user.photoURL ?? '');
        await prefs.setString('user_uid', user.uid);

        _cachedProfile = {
          'email': user.email ?? '',
          'displayName': user.displayName ?? '',
          'photoURL': user.photoURL ?? '',
        };

        if (user.photoURL != null) {
          final savedUrl = prefs.getString('user_photoURL_downloaded');
          if (savedUrl != user.photoURL ||
              _localPhotoPath == null ||
              !await fs.exists(_localPhotoPath!)) {
            await _downloadProfileImage(user.photoURL!, uid: user.uid);
            await prefs.setString('user_photoURL_downloaded', user.photoURL!);
          }
        }

        return; // Success
      } catch (e) {
        AppLogger.log("Attempt $attempts failed: $e");

        // If it's the last attempt, or if it's a permission error (not transient), fail.
        if (attempts >= 3 || e.toString().contains("permission-denied")) {
          AppLogger.error('Error creating/updating user profile', e);

          String message = "Failed to connect to database.";
          if (e.toString().contains("unavailable")) {
            message =
                "Database Unavailable. Please check:\n1. Your internet connection.\n2. If the Firestore Database is created in the Firebase Console.\n3. If a firewall is blocking the connection.";
          } else if (e.toString().contains("permission-denied")) {
            message = "Permission Denied. Check Firestore Security Rules.";
          } else {
            message = "Error: $e";
          }

          throw Exception(message);
        }

        onStatusChange?.call("Connection failed. Retrying...");
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Starts a Firestore listener to detect when tokens are revoked.
  /// When tokensRevokedAt is set in Firestore and is after our cached auth time,
  /// it means our session has been invalidated and we should sign out.
  static void _startTokenRevocationListener(String userId) {
    // Cancel any existing listener
    _stopTokenRevocationListener();
    _currentUserId = userId;

    final firestore = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: DefaultFirebaseOptions.databaseId,
    );

    _tokenRevocationSubscription = firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .listen((snapshot) async {
          await _checkAndHandleRevocation(snapshot.data());
        });

    AppLogger.log("Started token revocation listener for user: $userId");
  }

  /// Checks if tokens have been revoked and signs out if needed
  static Future<void> _checkAndHandleRevocation(
    Map<String, dynamic>? data,
  ) async {
    if (data == null) return;

    final tokensRevokedAt = data['tokensRevokedAt'] as Timestamp?;
    if (tokensRevokedAt == null) return;

    // If we have a cached auth time and tokens were revoked after it,
    // this session should be invalidated
    if (_cachedTokenAuthTime != null) {
      final revokedTime = tokensRevokedAt.toDate();
      if (revokedTime.isAfter(_cachedTokenAuthTime!)) {
        AppLogger.log("Token revocation detected - forcing sign out");
        await signOut();
      }
    }
  }

  /// Call this when app resumes from background to check for revocation
  static Future<void> checkTokenRevocationOnResume() async {
    if (_currentUserId == null || _cachedTokenAuthTime == null) return;

    try {
      final firestore = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );

      final doc = await firestore.collection('users').doc(_currentUserId).get();
      if (doc.exists) {
        await _checkAndHandleRevocation(doc.data());
      }
    } catch (e) {
      AppLogger.error("Error checking token revocation on resume: $e");
    }
  }

  /// Stops the token revocation listener
  static void _stopTokenRevocationListener() {
    _tokenRevocationSubscription?.cancel();
    _tokenRevocationSubscription = null;
    _cachedTokenAuthTime = null;
    _currentUserId = null;
  }

  static Future<void> signOut() async {
    try {
      // Stop token revocation listener
      _stopTokenRevocationListener();

      // Cancel all alarms
      try {
        if (isAlarmSupported) {
          await Alarm.stopAll();
        }
      } catch (e) {
        AppLogger.error('Error stopping alarms during signout: $e');
      }

      // Dispose device approval notifications
      try {
        DeviceApprovalNotificationService().dispose();
        await DeviceApprovalNotificationService().cancelAllNotifications();
      } catch (e) {
        AppLogger.error('Error disposing device approval notifications: $e');
      }

      // Stop sync service listeners BEFORE signing out to prevent permission errors
      try {
        NoteSyncService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing NoteSyncService: $e');
      }

      try {
        LabelSyncService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing LabelSyncService: $e');
      }

      try {
        PlanService.instance.dispose();
      } catch (e) {
        AppLogger.error('Error disposing PlanService: $e');
      }

      // Clean up E2EE state (clears secure storage including device keys)
      try {
        await E2EEService.instance.dispose();
      } catch (e) {
        AppLogger.error('Error disposing E2EE service: $e');
      }

      // Clear Firestore persistence cache to prevent stale data on re-login
      try {
        final firestore = FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: DefaultFirebaseOptions.databaseId,
        );
        await firestore.clearPersistence();
      } catch (e) {
        // clearPersistence may fail if there are active listeners, ignore
        AppLogger.error('Error clearing Firestore persistence: $e');
      }

      // Close database connection before deleting
      try {
        await AppState.db.close();
        // Clear Database
        await deleteDatabase(databaseName);
      } catch (e) {
        AppLogger.error('Error closing/deleting database: $e');
      }

      // Clear SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
      } catch (e) {
        AppLogger.error('Error clearing SharedPreferences: $e');
      }

      // Delete local profile image
      try {
        final fs = await fileSystem();
        if (_localPhotoPath != null) {
          if (await fs.exists(_localPhotoPath!)) {
            await fs.delete(_localPhotoPath!);
          }
        }
      } catch (e) {
        AppLogger.error('Error deleting profile image: $e');
      }

      // Clear cache
      _cachedProfile = null;
      _localPhotoPath = null;

      // Reset session invalid flag
      sessionInvalid.value = false;

      // Reset App State
      try {
        await Future.microtask(() {});
        AppState.reset();
      } catch (e) {
        AppLogger.error('Error resetting AppState: $e');
      }

      // Sign Out
      if (!kIsWeb &&
          (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
        await _googleSignIn.signOut();
      }
      await _auth.signOut();

      // Reinitialize database after sign out
      await Future.microtask(() {});
      await initDatabase();
    } catch (e) {
      AppLogger.error('Error signing out', e);
      // Ensure we at least sign out from Firebase even if cleanup fails
      try {
        await _auth.signOut();
      } catch (_) {}
      // Re-throw so caller can handle it
      rethrow;
    }
  }
}
