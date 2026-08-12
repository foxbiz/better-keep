import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/apple_auth.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/connected_provider_lifecycle.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/cloud_functions_helper.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_apple_configuration.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/firebase_emulator_google_auth.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_share_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/oauth_transaction.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/services/recovered_oauth_sign_in_coordinator.dart';
import 'package:better_keep/services/reminder_session_service.dart';
import 'package:better_keep/services/reminder_sign_out_cleanup_service.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/desktop_auth_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:better_keep/services/web_oauth_stub.dart'
    if (dart.library.html) 'package:better_keep/services/web_oauth.dart'
    as web_oauth;

typedef _NativeAppleAuthorization = ({
  AuthorizationCredentialAppleID appleCredential,
  OAuthCredential firebaseCredential,
});

typedef _AppleSignInResult = ({
  UserCredential userCredential,
  AuthorizationCredentialAppleID? appleCredential,
});

typedef _OAuthCallbackResult = ({
  String transactionId,
  String? completionCode,
  bool linked,
});

typedef _PostSignInRequest = ({
  String uid,
  String provider,
  ValueChanged<AuthProgress>? onStatusChange,
});

class AuthService {
  static FirebaseAuth get _auth => FirebaseBackend.auth;
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  /// Expose FirebaseAuth instance for email verification operations
  static FirebaseAuth get firebaseAuth => _auth;

  static final ValueNotifier<bool> isVerifying = ValueNotifier(false);
  static final ValueNotifier<PostSignInState> postSignInState = ValueNotifier(
    PostSignInState.idle,
  );

  static const String? _serverClientId = null;

  // Completer for OAuth callback
  static Completer<_OAuthCallbackResult>? _oauthCompleter;
  static String? _pendingOAuthTransactionId;

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
  static _PostSignInRequest? _postSignInRequest;
  static Future<void>? _postSignInFuture;
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
    final transactionId = _pendingOAuthTransactionId;
    if (transactionId != null) {
      unawaited(removeOAuthTransaction(transactionId));
    }
    _oauthCompleter = null;
    _pendingOAuthTransactionId = null;
  }

  /// Handle OAuth callback from deep link
  /// Called when the app receives a browser OAuth completion deep link.
  /// or betterkeep://auth?linked=true&provider=xxx
  static Future<void> handleOAuthCallback(
    Uri uri, {
    required Future<void> appServicesReady,
  }) async {
    if (uri.scheme != 'betterkeep' || uri.host != 'auth') return;
    final transactionId = uri.queryParameters['transactionId'];
    if (transactionId == null) return;
    final transaction = await readOAuthTransaction(transactionId);
    if (transaction == null) return;
    if (_pendingOAuthTransactionId != null &&
        _pendingOAuthTransactionId != transactionId) {
      return;
    }

    // Check if cancelled
    if (uri.queryParameters['cancelled'] == 'true') {
      await removeOAuthTransaction(transactionId);
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
      await removeOAuthTransaction(transactionId);
      if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
        _oauthCompleter!.completeError(
          FirebaseAuthException(code: 'oauth-error', message: error),
        );
      }
      return;
    }

    // Check for successful link
    if (uri.queryParameters['linked'] == 'true') {
      await removeOAuthTransaction(transactionId);
      if (_oauthCompleter != null && !_oauthCompleter!.isCompleted) {
        _oauthCompleter!.complete((
          transactionId: transactionId,
          completionCode: null,
          linked: true,
        ));
      }
      return;
    }

    final completionCode = uri.queryParameters['code'];
    if (completionCode == null) return;
    final completer = _oauthCompleter;
    final coordinator = RecoveredOAuthSignInCoordinator<User>(
      redeemCompletion: (code, storedTransaction) => _redeemOAuthCompletion(
        completionCode: code,
        transaction: storedTransaction,
      ),
      authenticateWithCustomToken: (customToken) async {
        final credential = await _auth.signInWithCustomToken(customToken);
        return credential.user;
      },
      finalizeSignIn: (user, provider) => _completeSignIn(user, null, provider),
      removeTransaction: removeOAuthTransaction,
      setVerificationState: (value) => isVerifying.value = value,
      reportSecondaryFailure: (error, stackTrace) {
        unawaited(
          AppLogger.error(
            'OAuth recovery cleanup failed after a primary error',
            error,
            stackTrace,
          ),
        );
      },
    );

    await coordinator.completeCallback(
      transaction: transaction,
      completionCode: completionCode,
      appServicesReady: appServicesReady,
      completeInFlight: completer != null && !completer.isCompleted
          ? () {
              completer.complete((
                transactionId: transactionId,
                completionCode: completionCode,
                linked: false,
              ));
            }
          : null,
    );
  }

  static Future<String> _redeemOAuthCompletion({
    required String completionCode,
    required OAuthTransaction transaction,
  }) async {
    final result = await callCloudFunction('redeemOAuthCompletion', {
      'code': completionCode,
      'verifier': transaction.verifier,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    final customToken = data['customToken'];
    if (customToken is! String || customToken.isEmpty) {
      throw FirebaseAuthException(
        code: 'oauth-completion-invalid',
        message: 'The sign-in completion was invalid or expired.',
      );
    }
    return customToken;
  }

  /// Sign in using web OAuth flow
  /// On web: Opens popup window
  /// On mobile: Opens in-app browser and waits for deep link callback
  static Future<UserCredential> _signInWithWebOAuth({
    required String provider,
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    onStatusChange?.call(AuthProgress.startingSignIn);
    final transaction = await createOAuthTransaction(
      provider: provider,
      mode: 'signin',
    );
    _pendingOAuthTransactionId = transaction.id;
    final authUrl = _buildCustomOAuthUrl(
      provider: provider,
      transaction: transaction,
    );

    try {
      late String completionCode;
      if (kIsWeb) {
        onStatusChange?.call(AuthProgress.waitingForSignIn);
        final result = await web_oauth.openOAuthPopup(
          authUrl.toString(),
          expectedTransactionId: transaction.id,
        );
        if (result.error != null && result.error!.isNotEmpty) {
          throw FirebaseAuthException(
            code: 'oauth-error',
            message: result.error!,
          );
        }
        if (result.cancelled || result.completionCode == null) {
          throw FirebaseAuthException(
            code: 'cancelled',
            message: 'Sign-in was cancelled or popup was blocked',
          );
        }
        completionCode = result.completionCode!;
      } else {
        _oauthCompleter = Completer<_OAuthCallbackResult>();
        if (!await launchUrl(authUrl, mode: LaunchMode.inAppBrowserView)) {
          throw FirebaseAuthException(
            code: 'launch-failed',
            message: 'Could not open authentication page',
          );
        }
        onStatusChange?.call(AuthProgress.waitingForSignIn);
        final callback = await _oauthCompleter!.future.timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'timeout',
              message: 'Sign-in timed out. Please try again.',
            );
          },
        );
        if (callback.transactionId != transaction.id ||
            callback.completionCode == null) {
          throw FirebaseAuthException(
            code: 'oauth-completion-invalid',
            message: 'The sign-in completion did not match this request.',
          );
        }
        completionCode = callback.completionCode!;
      }

      onStatusChange?.call(AuthProgress.signingIn);
      final customToken = await _redeemOAuthCompletion(
        completionCode: completionCode,
        transaction: transaction,
      );
      return await _auth.signInWithCustomToken(customToken);
    } finally {
      await removeOAuthTransaction(transaction.id);
      _oauthCompleter = null;
      if (_pendingOAuthTransactionId == transaction.id) {
        _pendingOAuthTransactionId = null;
      }
    }
  }

  static Uri _buildCustomOAuthUrl({
    required String provider,
    required OAuthTransaction transaction,
    String mode = 'signin',
    String? linkToken,
  }) {
    return Uri.https('betterkeep.app', '/oauth/start', {
      'provider': provider,
      'redirect': kIsWeb ? 'popup' : 'betterkeep',
      'mode': mode,
      'linkToken': ?linkToken,
      'flowVersion': '2',
      'completionChallenge': transaction.challenge,
      'clientTransactionId': transaction.id,
      if (kIsWeb) 'clientOrigin': web_oauth.currentOAuthClientOrigin(),
    });
  }

  /// Initialize AuthService with optional pre-loaded SharedPreferences for faster startup.
  /// Token validation is deferred to background to not block app startup.
  static Future<void> init({SharedPreferences? prefs}) async {
    try {
      await purgeExpiredOAuthTransactions();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to clear expired OAuth transactions',
        error,
        stackTrace,
      );
    }

    // Start GoogleSignIn initialization (doesn't need to complete before continuing)
    Future<void>? googleSignInFuture;
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      googleSignInFuture = _googleSignIn.initialize(
        serverClientId: _serverClientId,
      );
    }

    // Use provided prefs or load fresh
    final prefsInstance = prefs ?? await SharedPreferences.getInstance();

    // iOS Keychain persists across app uninstalls/reinstalls, so Firebase Auth
    // may still have a valid session even after a fresh install.
    // SharedPreferences is cleared on uninstall, so we use it to detect a
    // fresh install and sign out to clear the stale Keychain token.
    if (!kIsWeb && Platform.isIOS) {
      final hasLaunchedBefore =
          prefsInstance.getBool('has_launched_before') ?? false;
      if (!hasLaunchedBefore) {
        await prefsInstance.setBool('has_launched_before', true);
        if (_auth.currentUser != null) {
          AppLogger.log(
            '[AuthService] Fresh install detected on iOS — clearing stale Keychain session.',
          );
          await _auth.signOut();
        }
      }
    }
    final email = prefsInstance.getString(
      FirebaseScopedPreferences.key('user_email'),
    );
    final uid = prefsInstance.getString(
      FirebaseScopedPreferences.key('user_uid'),
    );

    if (email != null) {
      _cachedProfile = {
        'email': email,
        'displayName':
            prefsInstance.getString(
              FirebaseScopedPreferences.key('user_displayName'),
            ) ??
            '',
        'photoURL':
            prefsInstance.getString(
              FirebaseScopedPreferences.key('user_photoURL'),
            ) ??
            '',
      };
      _localPhotoPath = prefsInstance.getString(
        FirebaseScopedPreferences.key('user_local_photo'),
      );

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
      // We have cached user data but currentUser is null.
      // On all native platforms Firebase Auth may restore the session
      // asynchronously (e.g. from iOS Keychain / Android encrypted storage)
      // even after Firebase.initializeApp() resolves. Wait for a non-null
      // authStateChanges() emission before deciding the session is invalid.
      if (!kIsWeb) {
        final completer = Completer<User?>();
        late StreamSubscription<User?> tempSub;
        tempSub = _auth.authStateChanges().listen((user) {
          // Only complete on a non-null user. The stream typically emits
          // null immediately (meaning "no user yet"), which would resolve
          // the completer before Keychain restore has a chance to finish.
          // By ignoring null, we let the timeout handle the "no restore"
          // case while giving Firebase Auth the full window to restore.
          if (user != null && !completer.isCompleted) {
            completer.complete(user);
            tempSub.cancel();
          }
        });

        // Give Firebase Auth up to 5 seconds to restore the session.
        // On cold starts (especially iOS), Keychain restore can take longer
        // than expected. 2s was too aggressive and caused false session
        // invalidation.
        var restoredUser = await completer.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            tempSub.cancel();
            return null;
          },
        );

        // Retry: Firebase may have finished restoring just after timeout.
        // Check currentUser one more time before giving up.
        restoredUser ??= _auth.currentUser;

        if (restoredUser != null) {
          // Firebase Auth session was restored successfully.
          AppLogger.log(
            "Firebase Auth session restored for user: ${restoredUser.uid}",
          );
          _startTokenRevocationListener(restoredUser.uid);
          try {
            final idTokenResult = await restoredUser.getIdTokenResult(false);
            _cachedTokenAuthTime = idTokenResult.authTime;
          } catch (e) {
            AppLogger.error("Error getting token after session restore: $e");
          }
          _validateSessionInBackground(restoredUser);
        } else {
          // No user after waiting — session is truly invalid.
          AppLogger.log(
            "No currentUser after waiting, marking session as invalid",
          );
          AppLogger.log(
            "Session invalid: cached user data exists but Firebase currentUser is null",
          );
          sessionInvalid.value = true;
        }
      } else {
        // On web, mark session as invalid immediately (no async restore).
        AppLogger.log(
          "No currentUser but have cached profile (uid: $uid), marking session as invalid",
        );
        AppLogger.log(
          "Session invalid: cached user data exists but Firebase currentUser is null",
        );
        sessionInvalid.value = true;
      }
    }

    await ReminderSessionService.setSignedIn(
      _auth.currentUser != null,
      preferences: prefsInstance,
    );

    // Listen for auth state changes to start/stop the revocation listener
    _authStateSubscription?.cancel();
    _authStateSubscription = _auth.authStateChanges().listen((user) async {
      await ReminderSessionService.setSignedIn(user != null);
      if (user != null && _tokenRevocationSubscription == null) {
        // If we're in the middle of sign-in, defer starting the listener
        // _completeSignIn will handle this after auth is fully complete
        if (isVerifying.value) {
          AppLogger.log(
            "Sign-in in progress, deferring token revocation listener",
          );
          return;
        }

        // Recovery path: if sessionInvalid was set due to a timeout during
        // init but Firebase Auth restored the session later, clear the flag
        // so sync resumes normally.
        if (sessionInvalid.value) {
          AppLogger.log(
            "Auth state restored valid user after session was marked invalid — recovering session",
          );
          sessionInvalid.value = false;
        }

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
        _postSignInRequest = null;
        postSignInState.value = PostSignInState.idle;
        ReviewAccess.clear();
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
        await prefs.setString(
          FirebaseScopedPreferences.key('user_local_photo'),
          filePath,
        );
        _localPhotoPath = filePath;
      }
    } catch (e, stackTrace) {
      AppLogger.error('Error downloading profile image', e, stackTrace);
    }
  }

  static Future<UserCredential?> signInWithGoogle({
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;

      // Ensure Firestore network is enabled (may have been left disabled after signout)
      await _ensureNetworkEnabled();

      // On web, check if E2EE storage is properly configured before using it
      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;

      // Mark sign-in as in progress (for crash recovery)
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

      UserCredential userCredential;

      if (FirebaseEmulatorConfig.isUsingEmulators &&
          FirebaseEmulatorConfig.googleAuthMode ==
              GoogleEmulatorAuthMode.mock) {
        onStatusChange?.call(AuthProgress.signingIn);
        AppLogger.log(
          '[Auth] Emulator mode: using deterministic google.com credential',
        );
        userCredential = await _auth.signInWithCredential(
          FirebaseEmulatorGoogleAuth.credential(),
        );
      } else if (kIsWeb) {
        // Web: Use signInWithPopup
        GoogleAuthProvider googleProvider = GoogleAuthProvider();
        googleProvider.addScope('email');
        userCredential = await _auth.signInWithPopup(googleProvider);
      } else if (Platform.isWindows || Platform.isLinux) {
        // Windows/Linux: Use custom loopback flow
        onStatusChange?.call(AuthProgress.startingSignIn);
        final tokens = await DesktopAuthService.signIn();

        onStatusChange?.call(AuthProgress.signingIn);
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

        onStatusChange?.call(AuthProgress.signingIn);

        final GoogleSignInAuthentication googleAuth = googleUser.authentication;

        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
          accessToken: null,
        );

        userCredential = await _auth.signInWithCredential(credential);
      }

      if (userCredential.user != null) {
        await _completeSignIn(userCredential.user!, onStatusChange, 'google');
      }

      return userCredential;
    } catch (e, stackTrace) {
      AppLogger.error('Error signing in with Google', e, stackTrace);
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  /// Sign in with Apple
  static Future<UserCredential?> signInWithApple({
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    var failureStage = 'preparation';
    try {
      isVerifying.value = true;
      await _ensureNetworkEnabled();

      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

      onStatusChange?.call(AuthProgress.signingIn);

      final result = await runAppleAuthFlow<_AppleSignInResult>(
        flow: appleAuthFlowFor(isWeb: kIsWeb, platform: defaultTargetPlatform),
        webPopup: () async {
          failureStage = 'firebase-provider';
          onStatusChange?.call(AuthProgress.signingIn);
          return (
            userCredential: await _auth.signInWithPopup(
              buildAppleAuthProvider(),
            ),
            appleCredential: null,
          );
        },
        firebaseProvider: () async {
          failureStage = 'firebase-provider';
          onStatusChange?.call(AuthProgress.signingIn);
          return (
            userCredential: await _auth.signInWithProvider(
              buildAppleAuthProvider(),
            ),
            appleCredential: null,
          );
        },
        nativeCredential: () async {
          failureStage = 'apple-authorization';
          final authorization = await _requestNativeAppleAuthorization();
          failureStage = 'firebase-credential-exchange';
          onStatusChange?.call(AuthProgress.signingIn);
          return (
            userCredential: await _auth.signInWithCredential(
              authorization.firebaseCredential,
            ),
            appleCredential: authorization.appleCredential,
          );
        },
      );

      final userCredential = result.userCredential;
      final appleCredential = result.appleCredential;

      // Apple only returns the name on first sign-in, so update the profile
      if (userCredential.user != null &&
          (appleCredential?.givenName != null ||
              appleCredential?.familyName != null)) {
        final displayName =
            '${appleCredential?.givenName ?? ''} ${appleCredential?.familyName ?? ''}'
                .trim();
        if (displayName.isNotEmpty) {
          await userCredential.user!.updateDisplayName(displayName);
        }
      }

      if (userCredential.user != null) {
        failureStage = 'post-login-initialization';
        await _completeSignIn(userCredential.user!, onStatusChange, 'apple');
      }

      return userCredential;
    } catch (e, stackTrace) {
      final diagnosticContext = await activeAppleFirebaseDiagnosticContext();
      await AppLogger.error(
        'Error signing in with Apple at $failureStage ($diagnosticContext)',
        e,
        stackTrace,
      );
      rethrow;
    } finally {
      isVerifying.value = false;
    }
  }

  static Future<_NativeAppleAuthorization>
  _requestNativeAppleAuthorization() async {
    final nonce = AppleNonce.generate();
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: nonce.hashed,
    );

    return (
      appleCredential: appleCredential,
      firebaseCredential: buildNativeAppleFirebaseCredential(
        appleCredential: appleCredential,
        rawNonce: nonce.raw,
      ),
    );
  }

  /// Sign in with Facebook
  static Future<UserCredential?> signInWithFacebook({
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await _ensureNetworkEnabled();

      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

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
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await _ensureNetworkEnabled();

      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

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
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await _ensureNetworkEnabled();

      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

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
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      await _ensureNetworkEnabled();

      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        await E2EESecureStorage.instance.setSignInProgress(true);
      }

      onStatusChange?.call(AuthProgress.creatingAccount);
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (userCredential.user != null) {
        // Keep user signed in - app.dart will show EmailVerificationPage
        // which will send OTP for verification
        if (canUseE2EEStorage) {
          await E2EESecureStorage.instance.setSignInProgress(false);
        }
        onStatusChange?.call(AuthProgress.verifying);
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
    ValueChanged<AuthProgress>? onStatusChange,
  }) async {
    try {
      isVerifying.value = true;
      onStatusChange?.call(AuthProgress.verifying);

      // Ensure Firestore network is enabled (may have been left disabled after signout)
      await _ensureNetworkEnabled();

      // On web, check if E2EE storage is properly configured before using it
      final canUseE2EEStorage =
          !kIsWeb || E2EESecureStorage.isWebStorageConfigured;

      if (canUseE2EEStorage) {
        await E2EESecureStorage.instance.init();
        onStatusChange?.call(AuthProgress.startingSignIn);
        await E2EESecureStorage.instance.setSignInProgress(true);
      } else {
        onStatusChange?.call(AuthProgress.startingSignIn);
      }

      onStatusChange?.call(AuthProgress.signingIn);
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
          onStatusChange?.call(AuthProgress.verifying);
          if (canUseE2EEStorage) {
            await E2EESecureStorage.instance.setSignInProgress(false);
          }
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

  /// Send password reset email (legacy - keeping for backwards compatibility)
  static Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ============================================================
  // PASSWORD RESET OTP
  // ============================================================

  /// Send OTP for password reset
  /// Returns a map with 'success', 'message', and 'maskedEmail'
  static Future<Map<String, dynamic>> sendPasswordResetOtp(String email) async {
    final result = await callCloudFunction('sendPasswordResetOtp', {
      'email': email,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Reset password with OTP verification
  /// Returns a map with 'success' and 'message'
  static Future<Map<String, dynamic>> resetPasswordWithOtp({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    final result = await callCloudFunction('resetPasswordWithOtp', {
      'email': email,
      'otp': otp,
      'newPassword': newPassword,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Verify password reset OTP (without resetting password)
  /// Returns a map with 'success' and 'message'
  static Future<Map<String, dynamic>> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) async {
    final result = await callCloudFunction('verifyPasswordResetOtp', {
      'email': email,
      'otp': otp,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  // ============================================================
  // EMAIL VERIFICATION OTP
  // ============================================================

  /// Send OTP for email verification
  /// Returns a map with 'success', 'email' (masked), and 'expiresIn'
  static Future<Map<String, dynamic>> sendEmailVerificationOtp() async {
    final result = await callCloudFunction('sendEmailVerificationOtp');
    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Verify email with OTP
  /// Returns a map with 'success' and 'message'
  static Future<Map<String, dynamic>> verifyEmailVerificationOtp(
    String otp,
  ) async {
    final result = await callCloudFunction('verifyEmailVerificationOtp', {
      'otp': otp,
    });
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
      final firestore = FirebaseBackend.firestore;
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
  static Future<void> linkWithGoogle({required String linkToken}) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');
    ReviewAccess.ensureCloudMutationAllowed(
      user,
      operation: 'Connected accounts',
    );

    try {
      if (FirebaseEmulatorConfig.isUsingEmulators &&
          FirebaseEmulatorConfig.googleAuthMode ==
              GoogleEmulatorAuthMode.mock) {
        await user.linkWithCredential(FirebaseEmulatorGoogleAuth.credential());
      } else if (kIsWeb) {
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
      await _confirmNativeAccountLink(
        provider: 'google.com',
        linkToken: linkToken,
      );
      AppLogger.log('Successfully linked Google account');
    } catch (e, stackTrace) {
      AppLogger.error('Error linking Google account', e, stackTrace);
      rethrow;
    }
  }

  /// Link Facebook account to current user using OAuth flow
  /// Security: User must authenticate with Facebook, proving ownership
  static Future<void> linkWithFacebook({required String linkToken}) async {
    await _linkWithWebOAuth(provider: 'facebook', linkToken: linkToken);
  }

  /// Link GitHub account to current user using OAuth flow
  /// Security: User must authenticate with GitHub, proving ownership
  static Future<void> linkWithGitHub({required String linkToken}) async {
    await _linkWithWebOAuth(provider: 'github', linkToken: linkToken);
  }

  /// Link Twitter/X account to current user using OAuth flow
  /// Security: User must authenticate with Twitter, proving ownership
  static Future<void> linkWithTwitter({required String linkToken}) async {
    await _linkWithWebOAuth(provider: 'twitter', linkToken: linkToken);
  }

  /// Link Apple account to current user
  /// Security: User must authenticate with Apple, proving ownership
  static Future<void> linkWithApple({required String linkToken}) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');
    ReviewAccess.ensureCloudMutationAllowed(
      user,
      operation: 'Connected accounts',
    );

    try {
      await runAppleAuthFlow<void>(
        flow: appleAuthFlowFor(isWeb: kIsWeb, platform: defaultTargetPlatform),
        webPopup: () async {
          await user.linkWithPopup(buildAppleAuthProvider());
        },
        firebaseProvider: () async {
          await user.linkWithProvider(buildAppleAuthProvider());
        },
        nativeCredential: () async {
          final authorization = await _requestNativeAppleAuthorization();
          await user.linkWithCredential(authorization.firebaseCredential);
        },
      );

      await _confirmNativeAccountLink(
        provider: 'apple.com',
        linkToken: linkToken,
      );
      AppLogger.log('Successfully linked Apple account');
    } catch (e, stackTrace) {
      AppLogger.error('Error linking Apple account', e, stackTrace);
      rethrow;
    }
  }

  /// Internal method to link account using custom OAuth flow
  static Future<void> _linkWithWebOAuth({
    required String provider,
    required String linkToken,
  }) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');
    ReviewAccess.ensureCloudMutationAllowed(
      user,
      operation: 'Connected accounts',
    );

    AppLogger.log('Starting $provider OAuth link flow for user ${user.uid}');
    final transaction = await createOAuthTransaction(
      provider: provider,
      mode: 'link',
    );
    _pendingOAuthTransactionId = transaction.id;
    final authUrl = _buildCustomOAuthUrl(
      provider: provider,
      transaction: transaction,
      mode: 'link',
      linkToken: linkToken,
    );

    try {
      if (kIsWeb) {
        final result = await web_oauth.openOAuthPopup(
          authUrl.toString(),
          expectedTransactionId: transaction.id,
        );
        if (result.error != null && result.error!.isNotEmpty) {
          throw FirebaseAuthException(
            code: 'oauth-error',
            message: result.error!,
          );
        }
        if (result.cancelled || !result.linked) {
          throw FirebaseAuthException(
            code: 'cancelled',
            message: 'Account linking was cancelled',
          );
        }
      } else {
        _oauthCompleter = Completer<_OAuthCallbackResult>();
        if (!await launchUrl(authUrl, mode: LaunchMode.inAppBrowserView)) {
          throw FirebaseAuthException(
            code: 'launch-failed',
            message: 'Could not open authentication page',
          );
        }
        final callback = await _oauthCompleter!.future.timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            throw FirebaseAuthException(
              code: 'timeout',
              message: 'Linking timed out. Please try again.',
            );
          },
        );
        if (callback.transactionId != transaction.id || !callback.linked) {
          throw FirebaseAuthException(
            code: 'oauth-completion-invalid',
            message: 'The account-link completion did not match this request.',
          );
        }
      }

      addLinkedProvider('$provider.com');
      AppLogger.log('Successfully linked $provider account via OAuth');
    } finally {
      await removeOAuthTransaction(transaction.id);
      _oauthCompleter = null;
      if (_pendingOAuthTransactionId == transaction.id) {
        _pendingOAuthTransactionId = null;
      }
    }
  }

  static Future<void> _confirmNativeAccountLink({
    required String provider,
    required String linkToken,
  }) async {
    await callCloudFunction('confirmAccountLink', {
      'provider': provider,
      'linkToken': linkToken,
    });
    addLinkedProvider(provider);
  }

  /// Unlink a provider from current user
  /// Removes the provider from Firebase Auth and Firestore metadata.
  static Future<void> unlinkProvider(String providerId) async {
    final user = currentUser;
    if (user == null) throw Exception('No user signed in');
    ReviewAccess.ensureCloudMutationAllowed(
      user,
      operation: 'Connected accounts',
    );

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
      final firestore = FirebaseBackend.firestore;
      await unlinkConnectedProvider(
        providerId: providerId,
        firebaseProviderIds: user.providerData.map((info) => info.providerId),
        removeMetadata: () async {
          await firestore.collection('users').doc(user.uid).update({
            'linkedProviders.$firestoreKey': FieldValue.delete(),
          });
        },
        clearCachedProvider: () {
          _firestoreLinkedProviders.remove(providerId);
        },
        unlinkFirebaseProvider: (linkedProviderId) async {
          await user.unlink(linkedProviderId);
        },
      );

      AppLogger.log('Successfully unlinked provider: $providerId');
    } catch (e, stackTrace) {
      AppLogger.error('Error unlinking provider: $providerId', e, stackTrace);
      rethrow;
    }
  }

  /// Sets Pro claims in emulator mode for testing.
  /// In emulator mode, the beforeUserSignedIn blocking function doesn't trigger,
  /// so we need to manually set Pro claims via a Cloud Function.
  static Future<void> _setEmulatorProClaims(
    User user,
    ValueChanged<AuthProgress>? onStatusChange,
  ) async {
    if (!FirebaseEmulatorConfig.isUsingEmulators) return;

    AppLogger.log("[SIGN_IN] Emulator mode detected, setting Pro claims...");
    onStatusChange?.call(AuthProgress.checkingAccount);

    try {
      AppLogger.log("[SIGN_IN] Calling setEmulatorTestClaims function...");
      final result = await callCloudFunction('setEmulatorTestClaims');
      AppLogger.log("[SIGN_IN] setEmulatorTestClaims result: ${result.data}");

      // Wait for claims to propagate in the emulator
      await Future.delayed(const Duration(milliseconds: 500));

      // Force token refresh to get the new claims
      await user.getIdToken(true);

      // Verify claims were set
      final tokenResult = await user.getIdTokenResult(true);
      final plan = tokenResult.claims?['plan'];
      AppLogger.log("[SIGN_IN] Token claims after refresh: plan=$plan");

      if (plan != 'pro') {
        // Try one more time after a longer delay
        AppLogger.log("[SIGN_IN] Claims not propagated, waiting longer...");
        await Future.delayed(const Duration(seconds: 1));
        await user.getIdToken(true);
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        "[SIGN_IN] Failed to set emulator test claims",
        e,
        stackTrace,
      );
    }
  }

  /// Common sign-in completion logic
  static Future<void> _completeSignIn(
    User user,
    ValueChanged<AuthProgress>? onStatusChange,
    String provider,
  ) => _startPostSignInInitialization(
    user: user,
    provider: provider,
    onStatusChange: onStatusChange,
  );

  /// Initializes cloud and encryption services for a restored Firebase Auth
  /// session. This uses the same recoverable pipeline as a fresh sign-in.
  static Future<void> initializeCurrentUserServices() async {
    final user = currentUser;
    if (user == null) {
      postSignInState.value = PostSignInState.idle;
      return;
    }

    await _startPostSignInInitialization(
      user: user,
      provider: _providerNameFor(user),
    );
  }

  /// Retries the complete authenticated startup sequence after a transient
  /// identity, account, or encryption failure.
  static Future<void> retryPostSignInInitialization() async {
    final inFlight = _postSignInFuture;
    if (inFlight != null) {
      await inFlight;
      if (!postSignInState.value.hasRecoverableFailure &&
          E2EEService.instance.status.value != E2EEStatus.error) {
        return;
      }
    }

    final user = currentUser;
    if (user == null) {
      postSignInState.value = PostSignInState.idle;
      return;
    }

    if (E2EEService.instance.status.value == E2EEStatus.error) {
      E2EEService.instance.status.value = E2EEStatus.notInitialized;
      E2EEService.instance.resetInitialization();
    }

    final previousRequest = _postSignInRequest;
    await _startPostSignInInitialization(
      user: user,
      provider: previousRequest != null && previousRequest.uid == user.uid
          ? previousRequest.provider
          : _providerNameFor(user),
      onStatusChange: previousRequest != null && previousRequest.uid == user.uid
          ? previousRequest.onStatusChange
          : null,
    );
  }

  static Future<void> continueOfflineAfterInitializationFailure() async {
    final canUseE2EEStorage =
        !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
    if (canUseE2EEStorage) {
      try {
        await E2EESecureStorage.instance.setSignInProgress(false);
      } catch (error, stackTrace) {
        await AppLogger.error(
          '[POST_SIGN_IN] Failed to clear sign-in progress for offline mode',
          error,
          stackTrace,
        );
      }
    }
    postSignInState.value = PostSignInState.idle;
    sessionInvalid.value = true;
  }

  static Future<void> _startPostSignInInitialization({
    required User user,
    required String provider,
    ValueChanged<AuthProgress>? onStatusChange,
  }) {
    final running = _postSignInFuture;
    if (running != null) return running;

    final request = (
      uid: user.uid,
      provider: provider,
      onStatusChange: onStatusChange,
    );
    _postSignInRequest = request;

    late final Future<void> initialization;
    initialization = _runPostSignInInitialization(request).whenComplete(() {
      if (identical(_postSignInFuture, initialization)) {
        _postSignInFuture = null;
      }
    });
    _postSignInFuture = initialization;
    return initialization;
  }

  static Future<void> _runPostSignInInitialization(
    _PostSignInRequest request,
  ) async {
    final user = currentUser;
    if (user == null || user.uid != request.uid) {
      postSignInState.value = PostSignInState.idle;
      return;
    }

    var isReviewSession = false;
    final canUseE2EEStorage =
        !kIsWeb || E2EESecureStorage.isWebStorageConfigured;
    final coordinator = PostSignInCoordinator(
      validateIdentity: PostSignInOperation('validate-identity', () async {
        request.onStatusChange?.call(AuthProgress.verifying);
        await user.getIdToken(true);
        if (kIsWeb) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        await _setEmulatorProClaims(user, request.onStatusChange);
        isReviewSession = await ReviewAccess.authorize(user);
        ReviewAccess.requireAuthorizedReviewIdentity(user, isReviewSession);
      }),
      initializeAccount: PostSignInOperation('initialize-account', () async {
        request.onStatusChange?.call(AuthProgress.checkingAccount);
        await FirebaseEmulatorConfig.verifyAuthenticatedFirestore(user);
        if (isReviewSession) {
          final reviewAuthorization = ReviewAccess.authorizationFor(user);
          if (reviewAuthorization == null) {
            throw StateError('Review authorization was not retained');
          }
          PlanService.instance.activateReviewSession(reviewAuthorization);
          return;
        }
        await _ensureUserExists(user, request.onStatusChange, request.provider);
      }),
      initializeEncryption: PostSignInOperation(
        'initialize-encryption',
        () async {
          request.onStatusChange?.call(AuthProgress.protectingNotes);
          if (isReviewSession) {
            await E2EEService.instance.initializeReviewSession();
          } else {
            await E2EEService.instance.initialize();
          }
        },
      ),
      auxiliaryServices: [
        PostSignInOperation('refresh-linked-providers', () async {
          if (!isReviewSession) await refreshLinkedProviders();
        }),
        PostSignInOperation('start-subscription-listener', () async {
          if (!isReviewSession) {
            await PlanService.instance.startSubscriptionListener();
          }
        }),
        PostSignInOperation('device-approval-notifications', () async {
          if (!isReviewSession) {
            await DeviceApprovalNotificationService().init();
          }
        }),
        PostSignInOperation('note-sync', () async {
          if (!isReviewSession) await NoteSyncService().init();
        }),
        PostSignInOperation('label-sync', () async {
          if (!isReviewSession) await LabelSyncService().init();
        }),
        PostSignInOperation('note-sort-sync', () async {
          if (!isReviewSession) await NoteSortService().startCloudSync();
        }),
      ],
      isFatalIdentityFailure: _isDefinitiveIdentityFailure,
      isSessionCurrent: () => currentUser?.uid == request.uid,
      signOut: signOut,
      clearSignInProgress: () async {
        if (canUseE2EEStorage) {
          await E2EESecureStorage.instance.setSignInProgress(false);
        }
      },
      onStateChanged: (state) {
        postSignInState.value = state;
      },
      reportFailure: (stage, operation, error, stackTrace) => AppLogger.error(
        '[POST_SIGN_IN] ${stage.name}/$operation failed',
        error,
        stackTrace,
      ),
    );

    await coordinator.run();
    if (currentUser?.uid != request.uid) return;

    // Token revocation remains active even while the user is on a recoverable
    // startup screen.
    _startTokenRevocationListener(request.uid);
    try {
      final idTokenResult = await user.getIdTokenResult();
      _cachedTokenAuthTime = idTokenResult.authTime;
    } catch (error, stackTrace) {
      await AppLogger.error(
        '[POST_SIGN_IN] Failed to cache token auth time',
        error,
        stackTrace,
      );
    }
  }

  static bool _isDefinitiveIdentityFailure(Object error) {
    if (error is ReviewAuthorizationException) return true;
    if (error is! FirebaseAuthException) return false;
    return const {
      'user-disabled',
      'user-not-found',
      'invalid-user-token',
      'user-token-expired',
    }.contains(error.code);
  }

  static String _providerNameFor(User user) {
    final providerId = user.providerData
        .map((provider) => provider.providerId)
        .firstWhere(
          (providerId) => providerId.isNotEmpty,
          orElse: () => 'unknown',
        );
    return switch (providerId) {
      'password' => 'email',
      'google.com' => 'google',
      'apple.com' => 'apple',
      'facebook.com' => 'facebook',
      'github.com' => 'github',
      'twitter.com' => 'twitter',
      _ => providerId,
    };
  }

  static Future<void> _ensureUserExists(
    User user,
    ValueChanged<AuthProgress>? onStatusChange,
    String provider,
  ) async {
    final firestore = FirebaseBackend.firestore;
    AppLogger.log(
      "AuthService using databaseId: ${FirebaseBackend.databaseId}",
    );
    final userRef = firestore.collection('users').doc(user.uid);

    int attempts = 0;
    while (attempts < 3) {
      try {
        attempts++;

        onStatusChange?.call(AuthProgress.checkingAccount);

        // We remove Source.server to allow the SDK to optimize,
        // but we still expect a connection for the first login.
        AppLogger.log(
          "[AUTH] Fetching user document for UID: ${user.uid} (Attempt $attempts)",
        );
        final doc = await userRef.get().timeout(const Duration(seconds: 30));
        AppLogger.log(
          "[AUTH] Fetched user document for UID: ${user.uid}, exists: ${doc.exists}",
        );
        if (!doc.exists) {
          onStatusChange?.call(AuthProgress.checkingAccount);
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
            onStatusChange?.call(AuthProgress.checkingAccount);
            AppLogger.log(
              "[AUTH] Found scheduled deletion, calling cancelScheduledDeletion Cloud Function",
            );
            try {
              // Call Cloud Function to cancel deletion (sends email notification)
              final result = await callCloudFunction('cancelScheduledDeletion');
              AppLogger.log(
                "[AUTH] Cancelled scheduled deletion via Cloud Function for user: ${user.uid}, result: ${result.data}",
              );
              AppLogger.log(
                "[AUTH] Account deletion cancelled successfully for user: ${user.uid}",
              );
            } catch (e, stack) {
              // Fallback to direct Firestore update if Cloud Function fails
              AppLogger.log(
                "[AUTH] Cloud Function failed, falling back to direct update: $e",
              );
              AppLogger.log(
                "[AUTH] cancelScheduledDeletion Cloud Function failed: $e\n$stack",
              );
              await userRef
                  .update({
                    'scheduledDeletion': FieldValue.delete(),
                    'tokensRevokedAt': FieldValue.delete(),
                    'lastSeen': FieldValue.serverTimestamp(),
                  })
                  .timeout(const Duration(seconds: 30));
              AppLogger.log(
                "[AUTH] Cancelled scheduled deletion directly for user: ${user.uid}",
              );
            }
          } else {
            AppLogger.log(
              "[AUTH] No scheduled deletion found for user: ${user.uid}",
            );
            await userRef
                .update({'lastSeen': FieldValue.serverTimestamp()})
                .timeout(const Duration(seconds: 30));
          }
        }

        // Cache user profile locally
        final prefs = await SharedPreferences.getInstance();
        final fs = await fileSystem();

        await prefs.setString(
          FirebaseScopedPreferences.key('user_email'),
          user.email ?? '',
        );
        await prefs.setString(
          FirebaseScopedPreferences.key('user_displayName'),
          user.displayName ?? '',
        );
        await prefs.setString(
          FirebaseScopedPreferences.key('user_photoURL'),
          user.photoURL ?? '',
        );
        await prefs.setString(
          FirebaseScopedPreferences.key('user_uid'),
          user.uid,
        );

        _cachedProfile = {
          'email': user.email ?? '',
          'displayName': user.displayName ?? '',
          'photoURL': user.photoURL ?? '',
        };

        if (user.photoURL != null) {
          final savedUrl = prefs.getString(
            FirebaseScopedPreferences.key('user_photoURL_downloaded'),
          );
          if (savedUrl != user.photoURL ||
              _localPhotoPath == null ||
              !await fs.exists(_localPhotoPath!)) {
            await _downloadProfileImage(user.photoURL!, uid: user.uid);
            await prefs.setString(
              FirebaseScopedPreferences.key('user_photoURL_downloaded'),
              user.photoURL!,
            );
          }
        }

        return; // Success
      } catch (e) {
        AppLogger.log("[AUTH] Attempt $attempts failed: $e");

        // If it's the last attempt, or if it's a permission error (not transient), fail.
        if (attempts >= 3 || e.toString().contains("permission-denied")) {
          AppLogger.error('Error creating/updating user profile', e);

          throw StateError('Account initialization failed');
        }

        onStatusChange?.call(AuthProgress.checkingAccount);
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

    final firestore = FirebaseBackend.firestore;

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
    // Recovery: if session was marked invalid (e.g. due to init timeout)
    // but Firebase Auth now has a valid user, attempt to recover the session.
    if (sessionInvalid.value) {
      final user = _auth.currentUser;
      if (user != null) {
        try {
          final idTokenResult = await user.getIdTokenResult(true);
          _cachedTokenAuthTime = idTokenResult.authTime;
          _startTokenRevocationListener(user.uid);
          AppLogger.log(
            "Session recovered on resume — Firebase Auth user is valid",
          );
          sessionInvalid.value = false;
          return;
        } catch (e) {
          AppLogger.error("Session recovery on resume failed: $e");
          // Fall through — session remains invalid
        }
      }
    }

    if (_currentUserId == null || _cachedTokenAuthTime == null) return;

    try {
      final firestore = FirebaseBackend.firestore;

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

  /// Ensures Firestore network is enabled (may have been left disabled after signout)
  static Future<void> _ensureNetworkEnabled() async {
    try {
      final firestore = FirebaseBackend.firestore;
      await firestore.enableNetwork();
    } catch (e) {
      AppLogger.error('Error enabling Firestore network: $e');
    }
  }

  static Future<void> signOut() async {
    _postSignInRequest = null;
    _postSignInFuture = null;
    postSignInState.value = PostSignInState.idle;
    try {
      await ReminderSessionService.setSignedIn(false);

      // Stop token revocation listener
      _stopTokenRevocationListener();

      // Cancel only note reminder deliveries before the note database is
      // deleted. Device-approval notifications use a separate payload and ID
      // namespace and remain independently managed below.
      try {
        await ReminderSignOutCleanupService.cancelDeliveries();
      } catch (e) {
        AppLogger.error('Error cancelling reminders during signout: $e');
      }

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
        await NoteSyncService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing NoteSyncService: $e');
      }

      try {
        await LabelSyncService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing LabelSyncService: $e');
      }

      try {
        await NoteSortService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing NoteSortService: $e');
      }

      try {
        NoteShareService().dispose();
      } catch (e) {
        AppLogger.error('Error disposing NoteShareService: $e');
      }

      try {
        PlanService.instance.dispose();
      } catch (e) {
        AppLogger.error('Error disposing PlanService: $e');
      }

      // Clean up E2EE state (clears secure storage including device keys)
      try {
        await E2EEService.instance.dispose().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            AppLogger.log('Timeout disposing E2EE service during signout');
          },
        );
      } catch (e) {
        AppLogger.error('Error disposing E2EE service: $e');
      }

      try {
        await clearActiveOAuthTransactions();
      } catch (e) {
        AppLogger.error(
          'Error clearing active Firebase OAuth transactions during signout',
          e,
        );
      }

      // Wait for pending Firestore writes and disable network before signing out
      // This prevents permission-denied errors from in-flight operations after auth is cleared
      try {
        final firestore = FirebaseBackend.firestore;
        // Wait for any pending writes to complete (with timeout)
        await firestore.waitForPendingWrites().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            AppLogger.log('Timeout waiting for pending Firestore writes');
          },
        );
        // Disable network to prevent any new operations
        await firestore.disableNetwork().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            AppLogger.log('Timeout disabling Firestore network during signout');
          },
        );
      } catch (e) {
        AppLogger.error('Error waiting for Firestore writes: $e');
      }

      // Close database connection before deleting
      try {
        await AppState.db.close();
        // Clear Database
        await deleteDatabase(await activeDatabasePath());
      } catch (e) {
        AppLogger.error('Error closing/deleting database: $e');
      }

      // Clear only the selected environment's account preferences. Global UI
      // choices, Firebase chooser details, and the inactive backend stay intact.
      try {
        final prefs = await SharedPreferences.getInstance();
        await FirebaseScopedPreferences.clearActiveAccountPreferences(prefs);
        LocalDataEncryption.resetScopedPreferenceCache();
        await AlarmIdService.resetForScopeChange(prefs: prefs);
        await prefs.setBool('has_launched_before', true);
      } catch (e) {
        AppLogger.error('Error clearing SharedPreferences: $e');
      }

      // Clear File System
      final fs = await fileSystem();
      await _clearFileSystemRecursively(await fs.documentDir);
      await _clearFileSystemRecursively(await fs.cacheDir);

      // Invalidate avatar cache so new user gets fresh avatar
      UserAvatar.invalidateCache();

      // Clear cache
      _cachedProfile = null;
      _localPhotoPath = null;
      _firestoreLinkedProviders = {};
      _primaryProvider = null;

      // Reset session invalid flag
      sessionInvalid.value = false;
      ReviewAccess.clear();

      // Reset App State
      try {
        await Future.microtask(() {});
        AppState.reset();
      } catch (e) {
        AppLogger.error('Error resetting AppState: $e');
      }

      // Re-enable Firestore network after signing out
      // Note: We intentionally do NOT call terminate() or clearPersistence() because:
      // 1. terminate() makes the Firestore instance permanently unusable until app restart
      // 2. clearPersistence() requires terminate() first, which breaks re-login
      // Security rules will prevent access to old cached data from other users
      try {
        final firestore = FirebaseBackend.firestore;
        await firestore.enableNetwork().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            AppLogger.log(
              'Timeout re-enabling Firestore network after signout',
            );
          },
        );
      } catch (e) {
        AppLogger.error('Error re-enabling Firestore network: $e');
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
      await NoteSortService().init();
    } catch (e) {
      AppLogger.error('Error signing out', e);
      // Ensure we at least sign out from Firebase even if cleanup fails.
      // Once Firebase auth is cleared, the app can recover through the
      // normal signed-out flow even if some cleanup steps were best-effort.
      try {
        await _auth.signOut();
        ReviewAccess.clear();
      } catch (authError) {
        ReviewAccess.clear();
        AppLogger.error(
          'Error signing out from Firebase after cleanup failure',
          authError,
        );
        rethrow;
      }

      try {
        await initDatabase();
        await NoteSortService().init();
      } catch (dbError) {
        AppLogger.error(
          'Error reinitializing database after fallback signout: $dbError',
        );
      }

      return;
    }
  }

  static Future<void> _clearFileSystemRecursively(String directory) async {
    final fs = await fileSystem();

    try {
      AppLogger.log('Clearing file system directory: $directory');
      final files = await fs.list(directory);
      for (final file in files) {
        final filePath = isAbsolute(file) ? file : join(directory, file);
        try {
          final isDir = await fs.isDirectory(filePath);
          AppLogger.log('Deleting ${isDir ? "directory" : "file"}: $filePath');
          if (isDir) {
            await _clearFileSystemRecursively(filePath);
            await fs.delete(filePath);
          } else {
            await fs.delete(filePath);
          }
          AppLogger.log('Deleted: $filePath');
        } catch (e) {
          AppLogger.error('Error deleting file/directory $filePath: $e');
        }
      }
    } catch (e) {
      AppLogger.error('Error clearing file system: $e');
    }
  }
}
