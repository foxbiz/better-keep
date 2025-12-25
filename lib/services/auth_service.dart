import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:better_keep/components/user_avatar.dart';
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
import 'package:better_keep/services/desktop_auth_service.dart';
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
import 'package:url_launcher/url_launcher.dart';
import 'package:better_keep/services/web_oauth_stub.dart'
    if (dart.library.html) 'package:better_keep/services/web_oauth.dart'
    as web_oauth;

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  /// Expose FirebaseAuth instance for email verification operations
  static FirebaseAuth get firebaseAuth => _auth;

  static final ValueNotifier<bool> isVerifying = ValueNotifier(false);

  static const String? _serverClientId = null;

  // Completer for OAuth callback
  static Completer<String>? _oauthCompleter;

  static Stream<User?> get userStream => _auth.userChanges();
  static User? get currentUser => _auth.currentUser;

  static Map<String, String>? _cachedProfile;
  static String? _localPhotoPath;

  // Cached Firestore linked providers (from custom OAuth flow)
  static Set<String> _firestoreLinkedProviders = {};

  // Cached primary provider (original sign-up method)
  static String? _primaryProvider;

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

  /// Check if there's a pending OAuth request
  static bool get hasPendingOAuth =>
      _oauthCompleter != null && !_oauthCompleter!.isCompleted;

  /// Cancel any pending OAuth request
  static void cancelPendingOAuth() {
    if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
      _oauthCompleter!.completeError(
        FirebaseAuthException(
          code: 'cancelled',
          message: 'Sign-in was cancelled',
        ),
      );
    }
    _oauthCompleter = null;
  }

  /// Handle OAuth callback from deep link
  /// Called when app receives betterkeep://auth?token=xxx or betterkeep://auth?cancelled=true
  /// or betterkeep://auth?linked=true&provider=xxx
  static Future<void> handleOAuthCallback(Uri uri) async {
    if (uri.scheme != 'betterkeep' || uri.host != 'auth') return;

    // Check if cancelled
    if (uri.queryParameters['cancelled'] == 'true') {
      if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
        _oauthCompleter!.completeError(
          FirebaseAuthException(
            code: 'cancelled',
            message: 'Sign-in was cancelled',
          ),
        );
      }
      return;
    }

    // Check for error
    final error = uri.queryParameters['error'];
    if (error != null) {
      if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
        _oauthCompleter!.completeError(
          FirebaseAuthException(code: 'oauth-error', message: error),
        );
      }
      return;
    }

    // Check for successful link
    if (uri.queryParameters['linked'] == 'true') {
      if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
        // Complete with a marker value to indicate link success
        _oauthCompleter!.complete('link_success');
      }
      return;
    }

    // Standard sign-in with token
    final token = uri.queryParameters['token'];
    if (token != null &&
        _oauthCompleter != null &&
        !_oauthCompleter!.isCompleted) {
      _oauthCompleter!.complete(token);
    }
  }

  /// Sign in using web OAuth flow
  /// On web: Opens popup window
  /// On mobile: Opens in-app browser and waits for deep link callback
  static Future<UserCredential> _signInWithWebOAuth({
    required String provider,
    Function(String)? onStatusChange,
  }) async {
    onStatusChange?.call("Opening $provider login...");

    // Generate a random state for security
    final state = DateTime.now().millisecondsSinceEpoch.toString();

    if (kIsWeb) {
      // Web: Use popup window with postMessage callback
      final authUrl =
          'https://betterkeep.app/oauth/start?provider=$provider&redirect=popup&state=$state';

      onStatusChange?.call("Waiting for sign-in...");

      final result = await web_oauth.openOAuthPopup(authUrl);

      // Debug logging
      AppLogger.log(
        'OAuth result: token=${result.token != null}, error=${result.error}, cancelled=${result.cancelled}, isError=${result.isError}',
      );

      // Check for errors first (error message takes priority)
      if (result.error != null && result.error!.isNotEmpty) {
        throw FirebaseAuthException(
          code: 'oauth-error',
          message: result.error!,
        );
      }

      // Check for cancellation or no token
      if (result.cancelled || result.token == null) {
        throw FirebaseAuthException(
          code: 'cancelled',
          message: 'Sign-in was cancelled or popup was blocked',
        );
      }

      onStatusChange?.call("Completing sign-in...");

      // Sign in with custom token
      final userCredential = await _auth.signInWithCustomToken(result.token!);
      return userCredential;
    } else {
      // Mobile: Use in-app browser with deep link callback
      _oauthCompleter = Completer<String>();

      final authUrl = Uri.parse(
        'https://betterkeep.app/oauth/start?provider=$provider&redirect=betterkeep&state=$state',
      );

      // Use in-app browser (Chrome Custom Tabs on Android, SFSafariViewController on iOS)
      if (!await launchUrl(authUrl, mode: LaunchMode.inAppBrowserView)) {
        _oauthCompleter = null;
        throw FirebaseAuthException(
          code: 'launch-failed',
          message: 'Could not open authentication page',
        );
      }

      onStatusChange?.call("Waiting for sign-in...");

      // Wait for callback with timeout
      try {
        final customToken = await _oauthCompleter!.future.timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'timeout',
              message: 'Sign-in timed out. Please try again.',
            );
          },
        );

        onStatusChange?.call("Completing sign-in...");

        // Sign in with custom token
        final userCredential = await _auth.signInWithCustomToken(customToken);
        return userCredential;
      } finally {
        _oauthCompleter = null;
      }
    }
  }

  /// Initialize AuthService with optional pre-loaded SharedPreferences for faster startup.
  /// Token validation is deferred to background to not block app startup.
  static Future<void> init({SharedPreferences? prefs}) async {
    // Start GoogleSignIn initialization (doesn't need to complete before continuing)
    Future<void>? googleSignInFuture;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      googleSignInFuture = _googleSignIn.initialize(
        serverClientId: _serverClientId,
      );
    }

    // Use provided prefs or load fresh
    final prefsInstance = prefs ?? await SharedPreferences.getInstance();
    final email = prefsInstance.getString('user_email');
    final uid = prefsInstance.getString('user_uid');

    if (email != null) {
      _cachedProfile = {
        'email': email,
        'displayName': prefsInstance.getString('user_displayName') ?? '',
        'photoURL': prefsInstance.getString('user_photoURL') ?? '',
      };
      _localPhotoPath = prefsInstance.getString('user_local_photo');

      // Download profile image in background (don't block startup)
      if (_cachedProfile!['photoURL']!.isNotEmpty) {
        _downloadProfileImageIfNeeded(uid: uid);
      }
    }

    // Start token revocation listener if user is already logged in
    final currentUser = _auth.currentUser;
    if (currentUser != null) {
      // Use cached token first for fast startup, then validate in background
      // This avoids blocking on network for token refresh
      try {
        // Get cached token (no network call) to start the revocation listener immediately
        final idTokenResult = await currentUser.getIdTokenResult(false);
        _cachedTokenAuthTime = idTokenResult.authTime;
        _startTokenRevocationListener(currentUser.uid);
        AppLogger.log(
          "Initialized token revocation listener for existing user: ${currentUser.uid}",
        );

        // Validate session in background (force refresh) - this catches deleted users
        // but doesn't block startup
        _validateSessionInBackground(currentUser);
      } catch (e) {
        AppLogger.error("Error getting cached token: $e");
        // If even cached token fails, try to validate session synchronously
        await _validateAndHandleSession(currentUser);
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

    // Wait for GoogleSignIn to finish initialization if it was started
    if (googleSignInFuture != null) {
      await googleSignInFuture;
    }
  }

  /// Validates the user session in the background without blocking startup.
  /// This catches cases where the user was deleted/disabled on another device.
  static void _validateSessionInBackground(User user) {
    user
        .getIdTokenResult(true)
        .then((idTokenResult) {
          _cachedTokenAuthTime = idTokenResult.authTime;
          AppLogger.log("Background session validation successful");
        })
        .catchError((e) {
          AppLogger.error("Background session validation failed: $e");
          if (e.toString().contains('user-not-found') ||
              e.toString().contains('user-disabled') ||
              e.toString().contains('invalid-user-token') ||
              e.toString().contains('user-token-expired') ||
              e.toString().contains('400')) {
            AppLogger.log(
              "User session invalid (detected in background), disabling sync",
            );
            sessionInvalid.value = true;
            _stopTokenRevocationListener();
          }
        });
  }

  /// Validates and handles session synchronously (fallback when cached token fails).
  static Future<void> _validateAndHandleSession(User user) async {
    try {
      final idTokenResult = await user.getIdTokenResult(true);
      _cachedTokenAuthTime = idTokenResult.authTime;
      _startTokenRevocationListener(user.uid);
      AppLogger.log(
        "Initialized token revocation listener for existing user: ${user.uid}",
      );
    } catch (e) {
      AppLogger.error("Error validating user session: $e");
      if (e.toString().contains('user-not-found') ||
          e.toString().contains('user-disabled') ||
          e.toString().contains('invalid-user-token') ||
          e.toString().contains('user-token-expired') ||
          e.toString().contains('400')) {
        AppLogger.log("User session invalid during init, disabling sync: $e");
        sessionInvalid.value = true;
      } else {
        AppLogger.log("Non-fatal error getting token auth time: $e");
      }
    }
  }

  /// Downloads profile image in background if needed.
  static void _downloadProfileImageIfNeeded({String? uid}) {
    fileSystem()
        .then((fs) async {
          if (_localPhotoPath == null || !await fs.exists(_localPhotoPath!)) {
            _downloadProfileImage(_cachedProfile!['photoURL']!, uid: uid);
          }
        })
        .catchError((e) {
          AppLogger.error('Error checking for profile image', e);
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
        final tokens = await DesktopAuthService.signIn();

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
          await _ensureUserExists(
            userCredential.user!,
            onStatusChange,
            'google',
          );
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

  /// Sign in with Facebook
  static Future<UserCredential?> signInWithFacebook({
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      UserCredential userCredential;

      // Use custom OAuth flow for all platforms (consistent experience)
      userCredential = await _signInWithWebOAuth(
        provider: 'facebook',
        onStatusChange: onStatusChange,
      );

      if (userCredential.user != null) {
        await _completeSignIn(userCredential.user!, onStatusChange, 'facebook');
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with Facebook', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Sign in with GitHub
  static Future<UserCredential?> signInWithGitHub({
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      UserCredential userCredential;

      // Use custom OAuth flow for all platforms (consistent experience)
      userCredential = await _signInWithWebOAuth(
        provider: 'github',
        onStatusChange: onStatusChange,
      );

      if (userCredential.user != null) {
        await _completeSignIn(userCredential.user!, onStatusChange, 'github');
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with GitHub', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Sign in with Twitter/X
  static Future<UserCredential?> signInWithTwitter({
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      UserCredential userCredential;

      // Use custom OAuth flow for all platforms (consistent experience)
      userCredential = await _signInWithWebOAuth(
        provider: 'twitter',
        onStatusChange: onStatusChange,
      );

      if (userCredential.user != null) {
        await _completeSignIn(userCredential.user!, onStatusChange, 'twitter');
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with Twitter', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Sign up with email and password
  /// User will be kept signed in but shown email verification page until verified
  static Future<UserCredential?> signUpWithEmail({
    required String email,
    required String password,
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      onStatusChange?.call("Creating account...");
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (userCredential.user != null) {
        // Keep user signed in - app.dart will show EmailVerificationPage
        // which will send OTP for verification
        await E2EESecureStorage.instance.setSignInProgress(false);
        onStatusChange?.call("Account created!");
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing up with email', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Sign in with email and password
  /// If email is not verified, user stays signed in but app.dart shows verification page
  static Future<UserCredential?> signInWithEmail({
    required String email,
    required String password,
    Function(String)? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await E2EESecureStorage.instance.init();
      await E2EESecureStorage.instance.setSignInProgress(true);

      onStatusChange?.call("Signing in...");
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (userCredential.user != null) {
        // Reload user to get the latest emailVerified status
        await userCredential.user!.reload();
        final user = _auth.currentUser;

        if (user != null && !user.emailVerified) {
          // Email not verified - keep user signed in
          // app.dart will show EmailVerificationPage
          onStatusChange?.call("Email verification required...");
          await E2EESecureStorage.instance.setSignInProgress(false);
          // Return the credential - app.dart will handle showing verification page
          return userCredential;
        }

        await _completeSignIn(userCredential.user!, onStatusChange, 'email');
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with email', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Send password reset email
  static Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ============================================================
  // EMAIL VERIFICATION OTP
  // ============================================================

  /// Send OTP for email verification
  /// Returns a map with 'success', 'email' (masked), and 'expiresIn'
  static Future<Map<String, dynamic>> sendEmailVerificationOtp() async {
    final functions = FirebaseFunctions.instanceFor(
      app: Firebase.app(),
      region: 'us-central1',
    );
    final callable = functions.httpsCallable('sendEmailVerificationOtp');
    final result = await callable.call();
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Verify email with OTP
  /// Returns a map with 'success' and 'message'
  static Future<Map<String, dynamic>> verifyEmailVerificationOtp(
    String otp,
  ) async {
    final functions = FirebaseFunctions.instanceFor(
      app: Firebase.app(),
      region: 'us-central1',
    );
    final callable = functions.httpsCallable('verifyEmailVerificationOtp');
    final result = await callable.call({'otp': otp});
    return Map<String, dynamic>.from(result.data as Map);
  }

  // ============================================================
  // ACCOUNT LINKING - Connect multiple sign-in providers
  // ============================================================

  /// Get list of linked provider IDs for current user
  /// Returns providers that are connected (primary + linked)
  static List<String> getLinkedProviderIds() {
    final user = currentUser;
    if (user == null) return [];

    final providers = <String>{};

    // 1. Firebase Auth providers (for native SDK sign-ins)
    providers.addAll(user.providerData.map((info) => info.providerId));

    // 2. Firestore linked providers (from custom OAuth flow)
    providers.addAll(_firestoreLinkedProviders);

    // 3. Primary provider (original sign-up method)
    final primaryId = getPrimaryProviderId();
    if (primaryId != null) {
      providers.add(primaryId);
    }

    return providers.toList();
  }

  /// Refresh the Firestore linked providers cache from the user document
  static Future<void> refreshLinkedProviders() async {
    final user = currentUser;
    if (user == null) {
      _firestoreLinkedProviders = {};
      _primaryProvider = null;
      return;
    }

    try {
      // Use the named database
      final firestore = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      final userDoc = await firestore.collection('users').doc(user.uid).get();

      if (userDoc.exists) {
        final data = userDoc.data();
        final linkedProviders =
            data?['linkedProviders'] as Map<String, dynamic>?;
        if (linkedProviders != null) {
          // Convert Firestore keys (e.g., 'facebook') to Firebase provider ID format (e.g., 'facebook.com')
          _firestoreLinkedProviders = linkedProviders.keys.map((key) {
            switch (key) {
              case 'google':
                return 'google.com';
              case 'facebook':
                return 'facebook.com';
              case 'github':
                return 'github.com';
              case 'twitter':
                return 'twitter.com';
              default:
                return key.contains('.') ? key : '$key.com';
            }
          }).toSet();
        } else {
          _firestoreLinkedProviders = {};
        }
        // Cache the primary provider (original sign-up method)
        // The primary provider is stored in the 'provider' field
        _primaryProvider = data?['provider'] as String?;
      }
    } catch (e) {
      AppLogger.error('Failed to refresh linked providers: $e');
    }
  }

  /// Get the primary provider ID (original sign-up method)
  /// Returns provider in format like 'google.com', 'facebook.com', etc.
  static String? getPrimaryProviderId() {
    // If we have a cached primary provider, convert and return it
    if (_primaryProvider != null) {
      // Convert stored provider name to Firebase provider ID format
      switch (_primaryProvider) {
        case 'google':
          return 'google.com';
        case 'facebook':
          return 'facebook.com';
        case 'github':
          return 'github.com';
        case 'twitter':
          return 'twitter.com';
        case 'email':
          return 'password';
        default:
          return _primaryProvider!.contains('.')
              ? _primaryProvider
              : '$_primaryProvider.com';
      }
    }

    // Fallback: Check Firebase Auth's providerData
    final user = currentUser;
    if (user != null && user.providerData.isNotEmpty) {
      return user.providerData.first.providerId;
    }

    // Last resort: If we have any Firestore linked providers, don't return null
    // The primary should be determined by Firestore 'provider' field
    // If that's missing, we need to fetch it
    return null;
  }

  /// Add a provider to the local cache (called after successful OAuth linking)
  static void addLinkedProvider(String providerId) {
    _firestoreLinkedProviders.add(providerId);
  }

  /// Check if a specific provider is linked
  static bool isProviderLinked(String providerId) {
    return getLinkedProviderIds().contains(providerId);
  }

  /// Link Google account to current user
  /// Security: Requires user to authenticate with Google, proving ownership
  static Future<void> linkWithGoogle() async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');

    try {
      if (kIsWeb) {
        GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        await user.linkWithPopup(googleProvider);
      } else if (Platform.isWindows || Platform.isLinux) {
        final tokens = await DesktopAuthService.signIn();
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: tokens['idToken'],
          accessToken: tokens['accessToken'],
        );
        await user.linkWithCredential(credential);
      } else {
        if (!_googleSignIn.supportsAuthenticate()) {
          throw Exception("Google Sign-In not supported on this platform.");
        }
        final GoogleSignInAccount googleUser = await _googleSignIn
            .authenticate();
        final GoogleSignInAuthentication googleAuth = googleUser.authentication;
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
          accessToken: null,
        );
        await user.linkWithCredential(credential);
      }
      AppLogger.log('Successfully linked Google account');
    } catch (e, stackTrace) {
      AppLogger.error('Error linking Google account', e, stackTrace);
      rethrow;
    }
  }

  /// Link Facebook account to current user using OAuth flow
  /// Security: User must authenticate with Facebook, proving ownership
  static Future<void> linkWithFacebook() async {
    await _linkWithWebOAuth(provider: 'facebook');
  }

  /// Link GitHub account to current user using OAuth flow
  /// Security: User must authenticate with GitHub, proving ownership
  static Future<void> linkWithGitHub() async {
    await _linkWithWebOAuth(provider: 'github');
  }

  /// Link Twitter/X account to current user using OAuth flow
  /// Security: User must authenticate with Twitter, proving ownership
  static Future<void> linkWithTwitter() async {
    await _linkWithWebOAuth(provider: 'twitter');
  }

  /// Internal method to link account using custom OAuth flow
  static Future<void> _linkWithWebOAuth({required String provider}) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');

    AppLogger.log('Starting $provider OAuth link flow for user ${user.uid}');

    if (kIsWeb) {
      // Web: Use popup window with postMessage callback
      final authUrl =
          'https://betterkeep.app/oauth/start?provider=$provider&redirect=popup&mode=link&uid=${user.uid}';

      final result = await web_oauth.openOAuthPopup(authUrl);

      // Debug logging
      AppLogger.log(
        'OAuth link result: token=${result.token != null}, error=${result.error}, cancelled=${result.cancelled}',
      );

      // For link mode, we don't get a token, we check for link_success message type
      // The popup handler in web_oauth.dart needs to handle 'oauth_link_success' type

      // Check for errors first
      if (result.error != null && result.error!.isNotEmpty) {
        throw FirebaseAuthException(
          code: 'oauth-error',
          message: result.error!,
        );
      }

      // Check for cancellation
      if (result.cancelled) {
        throw FirebaseAuthException(
          code: 'cancelled',
          message: 'Account linking was cancelled',
        );
      }

      // Add provider to local cache so UI updates immediately
      addLinkedProvider('$provider.com');
      AppLogger.log('Successfully linked $provider account via OAuth');
    } else {
      // Mobile: Use in-app browser with deep link callback
      _oauthCompleter = Completer<String>();

      final authUrl = Uri.parse(
        'https://betterkeep.app/oauth/start?provider=$provider&redirect=betterkeep&mode=link&uid=${user.uid}',
      );

      // Use in-app browser
      if (!await launchUrl(authUrl, mode: LaunchMode.inAppBrowserView)) {
        _oauthCompleter = null;
        throw FirebaseAuthException(
          code: 'launch-failed',
          message: 'Could not open authentication page',
        );
      }

      // Wait for callback with timeout
      try {
        await _oauthCompleter!.future.timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'timeout',
              message: 'Linking timed out. Please try again.',
            );
          },
        );

        // Add provider to local cache so UI updates immediately
        addLinkedProvider('$provider.com');
        AppLogger.log('Successfully linked $provider account via OAuth');
      } finally {
        _oauthCompleter = null;
      }
    }
  }

  /// Unlink a provider from current user
  /// Removes the provider from Firestore linkedProviders
  static Future<void> unlinkProvider(String providerId) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');

    // Convert provider ID to Firestore key format
    String firestoreKey;
    switch (providerId) {
      case 'google.com':
        firestoreKey = 'google';
        break;
      case 'facebook.com':
        firestoreKey = 'facebook';
        break;
      case 'github.com':
        firestoreKey = 'github';
        break;
      case 'twitter.com':
        firestoreKey = 'twitter';
        break;
      default:
        firestoreKey = providerId.replaceAll('.com', '');
    }

    try {
      // Remove from Firestore
      final firestore = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      await firestore.collection('users').doc(user.uid).update({
        'linkedProviders.$firestoreKey': FieldValue.delete(),
      });

      // Remove from local cache
      _firestoreLinkedProviders.remove(providerId);

      AppLogger.log('Successfully unlinked provider: $providerId');
    } catch (e, stackTrace) {
      AppLogger.error('Error unlinking provider: $providerId', e, stackTrace);
      rethrow;
    }
  }

  /// Common sign-in completion logic
  static Future<void> _completeSignIn(
    User user,
    Function(String)? onStatusChange,
    String provider,
  ) async {
    try {
      // Force token refresh to ensure Firestore has the latest auth state
      // This fixes permission-denied errors on web after OAuth sign-in
      onStatusChange?.call("Verifying authentication...");
      await user.getIdToken(true);

      // Small delay to allow token propagation (especially on web)
      if (kIsWeb) {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Ensure Firestore network is enabled (may have been left disabled after signout)
      try {
        final firestore = FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: DefaultFirebaseOptions.databaseId,
        );
        await firestore.enableNetwork();
      } catch (e) {
        AppLogger.error('Error enabling Firestore network during sign-in: $e');
      }

      await _ensureUserExists(user, onStatusChange, provider);
      // Load Firestore linked providers into cache
      await refreshLinkedProviders();
      // Initialize E2EE after successful login
      onStatusChange?.call("Initializing encryption...");
      await E2EEService.instance.initialize();
      // Initialize device approval notifications
      DeviceApprovalNotificationService().init();
      // Start listening for token revocation
      _startTokenRevocationListener(user.uid);
      // Cache the token auth time for revocation detection
      final idTokenResult = await user.getIdTokenResult();
      _cachedTokenAuthTime = idTokenResult.authTime;
      // Clear sign-in progress flag on success
      await E2EESecureStorage.instance.setSignInProgress(false);
    } catch (e) {
      await signOut();
      rethrow;
    }
  }

  static Future<void> _ensureUserExists(
    User user,
    Function(String)? onStatusChange,
    String provider,
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
                'provider': provider,
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

      // Wait for pending Firestore writes and disable network before signing out
      // This prevents permission-denied errors from in-flight operations after auth is cleared
      try {
        final firestore = FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: DefaultFirebaseOptions.databaseId,
        );
        // Wait for any pending writes to complete (with timeout)
        await firestore.waitForPendingWrites().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            AppLogger.log('Timeout waiting for pending Firestore writes');
          },
        );
        // Disable network to prevent any new operations
        await firestore.disableNetwork();
      } catch (e) {
        AppLogger.error('Error waiting for Firestore writes: $e');
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

      // Invalidate avatar cache so new user gets fresh avatar
      UserAvatar.invalidateCache();

      // Clear cache
      _cachedProfile = null;
      _localPhotoPath = null;
      _firestoreLinkedProviders = {};
      _primaryProvider = null;

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

      // Re-enable network and clear Firestore persistence cache for next login
      try {
        final firestore = FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: DefaultFirebaseOptions.databaseId,
        );
        // IMPORTANT: Re-enable network first to ensure next login works
        // This must happen even if clearPersistence fails
        await firestore.enableNetwork();
        // Try to clear persistence (may fail if there are active listeners)
        try {
          await firestore.clearPersistence();
        } catch (e) {
          // clearPersistence may fail if there are active listeners, ignore
          AppLogger.error('Error clearing Firestore persistence: $e');
        }
      } catch (e) {
        AppLogger.error('Error re-enabling Firestore network: $e');
      }

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
