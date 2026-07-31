import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:app_links/app_links.dart';
import 'package:better_keep/app.dart';
import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/firebase_startup_error_view.dart';
import 'package:better_keep/components/firebase_environment_banner.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/services/audio_playback_source_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/motion_preferences.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/legacy_sketch_migration_service.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:better_keep/services/share_attachment_staging_service.dart';
import 'package:better_keep/services/reminder_permission_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/intent_handler_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:better_keep/utils/db_init.dart'
    if (dart.library.html) 'package:better_keep/utils/db_init_web.dart'
    if (dart.library.io) 'package:better_keep/utils/db_init_native.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/firebase_auth_redirect_domain.dart';
import 'package:better_keep/services/firebase_apple_configuration.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/firebase_bootstrap_coordinator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

void main() async {
  BetterKeepWidgetsBinding.ensureInitialized();

  // Enable edge-to-edge display for Android 15+ compatibility
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  initializeDb();
  // Native motion detection is best-effort and must never delay app startup.
  unawaited(MotionPreferences.instance.initialize());

  // Load SharedPreferences once and share across services
  final prefsInstance = await SharedPreferences.getInstance();

  // Run independent initializations in parallel for faster startup
  await Future.wait([
    // Alarm init (Android/iOS only)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) Alarm.init(),
    // Load app state (theme, settings, etc.)
    AppState.init(prefs: prefsInstance),
    // Initialize Firebase
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    // Detect physical vs emulator Android so the correct emulator host is used
    FirebaseEmulatorConfig.initDeviceInfo(),
  ]);

  FirebaseEmulatorConfig.init(prefsInstance);

  // Catch Flutter framework errors (e.g. RenderFlex overflows, widget errors)
  // and route them to the logger instead of crashing in release builds.
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.error(
      'Flutter framework error',
      details.exception,
      details.stack,
    );
    // In debug mode still show the red screen / console output as normal
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  // Catch uncaught async errors on the platform dispatcher (Dart errors that
  // escape the Flutter framework, e.g. unhandled Future exceptions).
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.error('Unhandled platform error', error, stack);
    return true; // mark as handled — prevents app crash
  };

  AppLogger.log('[Main] Starting Firebase bootstrap');
  runApp(_FirebaseBootstrap(preferences: prefsInstance));
}

bool shouldPromptForFirebaseEnvironment({required bool isDebugMode}) =>
    isDebugMode;

Future<void> _finishFirebaseStartup(SharedPreferences preferences) async {
  await validateActiveAppleFirebaseConfiguration(
    configuration: FirebaseBackend.active,
    expectedOptions: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseBackend.lock();
  await AppState.initializeFirebaseScope(preferences: preferences);
  await AlarmIdService.init(prefs: preferences);

  // Firebase routing must be final before accessing the native Auth instance.
  // Explicitly propagate the configured domain because Android and Apple
  // platforms can auto-create the default Firebase app before Dart starts.
  configureNativeFirebaseAuthRedirectDomain(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    usesEmulators: FirebaseEmulatorConfig.isUsingEmulators,
    configuredDomain: DefaultFirebaseOptions.currentPlatform.authDomain,
    firebaseAuth: FirebaseBackend.auth,
  );

  // This must be the first AuthService access.
  await AuthService.init(prefs: preferences);
  AppLogger.log(
    '[Main] AuthService initialized, currentUser: ${AuthService.currentUser?.email}',
  );
  final authenticatedUser = AuthService.currentUser;
  if (authenticatedUser != null) {
    await FirebaseEmulatorConfig.verifyAuthenticatedFirestore(
      authenticatedUser,
    );
  }

  // TEMPORARILY DISABLED: AppCheck uses AppleAppAttestProvider which only
  // activates in release mode and is suspected of causing a native crash
  // when the IAP purchase flow is triggered. AppCheck is NOT enforced on
  // any backend service (Cloud Functions, Firestore, Storage), so disabling
  // it has zero security impact. Re-enable after confirming the IAP fix.
  _activateAppCheckInBackground();

  UserAvatar.preloadAvatar();
  if (kIsWeb) {
    AppInstallService.instance.init();
  }

  final currentUser = AuthService.currentUser;
  final isReviewSession =
      currentUser != null && await ReviewAccess.authorize(currentUser);
  if (currentUser != null) {
    try {
      ReviewAccess.requireAuthorizedReviewIdentity(
        currentUser,
        isReviewSession,
      );
    } on ReviewAuthorizationException {
      await AuthService.signOut();
      rethrow;
    }
  }

  if (currentUser != null && !isReviewSession) {
    await E2EEService.instance.preloadCachedStatus();
  }
}

/// Activates FirebaseAppCheck in the background without blocking app startup.
/// This is safe to run after runApp since AppCheck is only needed for
/// authenticated Firebase operations.
void _activateAppCheckInBackground() {
  if (!kReleaseMode) {
    AppLogger.log('[Main] Skipping FirebaseAppCheck activation in debug mode');
    return;
  }

  if (kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    final androidProvider = AndroidPlayIntegrityProvider();
    final appleProvider = AppleAppAttestProvider();

    FirebaseAppCheck.instance
        .activate(
          providerWeb: ReCaptchaV3Provider(
            const String.fromEnvironment('GOOGLE_RECAPTCHA_SITE_KEY'),
          ),
          providerAndroid: androidProvider,
          providerApple: appleProvider,
        )
        .catchError((e) {
          AppLogger.error('[Main] FirebaseAppCheck activation failed', e);
        });
  }
}

class _FirebaseBootstrap extends StatefulWidget {
  const _FirebaseBootstrap({required this.preferences});

  final SharedPreferences preferences;

  @override
  State<_FirebaseBootstrap> createState() => _FirebaseBootstrapState();
}

class _FirebaseBootstrapState extends State<_FirebaseBootstrap> {
  bool _isReady = false;
  bool _isStarting = true;
  String? _fatalStartupError;
  bool _canRetryStartup = false;
  late final FirebaseBootstrapCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = FirebaseBootstrapCoordinator(
      initializeServices: () => _finishFirebaseStartup(widget.preferences),
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (shouldPromptForFirebaseEnvironment(isDebugMode: kDebugMode)) {
      if (mounted) {
        setState(() {
          _isStarting = false;
        });
      }
      return;
    }

    await _finishStartup(
      configureBackend: FirebaseEmulatorConfig.useLiveFirebase,
    );
  }

  Future<void> _finishStartup({
    Future<void> Function()? configureBackend,
  }) async {
    try {
      await _coordinator.start(configureBackend: configureBackend);
    } on FirebaseBootstrapException catch (error) {
      if (error.stage == FirebaseBootstrapStage.serviceInitialization &&
          mounted) {
        setState(() {
          _fatalStartupError = error.toString();
          _canRetryStartup = error.canRetryWithoutReconfiguringBackend;
          _isStarting = false;
        });
      }
      rethrow;
    }
    if (mounted) {
      setState(() {
        _isReady = true;
        _isStarting = false;
        _fatalStartupError = null;
        _canRetryStartup = false;
      });
    }
  }

  Future<void> _retryStartup() async {
    setState(() {
      _fatalStartupError = null;
      _canRetryStartup = false;
      _isStarting = true;
    });

    try {
      // Backend routing already succeeded before service initialization failed.
      // Reapplying it after Firebase services were accessed is unsafe.
      await _finishStartup();
    } catch (error) {
      AppLogger.error('[Main] Firebase startup retry failed', error);
    }
  }

  Future<void> _selectEnvironment(
    FirebaseEnvironment environment, {
    String? physicalDeviceHost,
    GoogleEmulatorAuthMode googleAuthMode = GoogleEmulatorAuthMode.mock,
  }) async {
    await _finishStartup(
      configureBackend: () {
        if (environment == FirebaseEnvironment.emulator) {
          return FirebaseEmulatorConfig.connectToEmulators(
            physicalDeviceHost: physicalDeviceHost,
            googleAuthMode: googleAuthMode,
          );
        }
        return FirebaseEmulatorConfig.useLiveFirebase();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isReady) return const BetterKeep();

    if (_fatalStartupError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppState.theme,
        builder: (context, child) => FirebaseEnvironmentBannerFrame(
          child: child ?? const SizedBox.shrink(),
        ),
        home: FirebaseStartupErrorView(
          error: _fatalStartupError!,
          onRetry: _canRetryStartup ? _retryStartup : null,
        ),
      );
    }

    if (_isStarting) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppState.theme,
        builder: (context, child) => FirebaseEnvironmentBannerFrame(
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _FirebaseBootstrapLoadingScreen(),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppState.theme,
      builder: (context, child) => FirebaseEnvironmentBannerFrame(
        child: child ?? const SizedBox.shrink(),
      ),
      home: FirebaseSelectionScreen(onSelected: _selectEnvironment),
    );
  }
}

class _FirebaseBootstrapLoadingScreen extends StatelessWidget {
  const _FirebaseBootstrapLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Starting Firebase...'),
          ],
        ),
      ),
    );
  }
}

class BetterKeep extends StatefulWidget {
  const BetterKeep({super.key});

  @override
  State<BetterKeep> createState() => _BetterKeepState();
}

class _BetterKeepState extends State<BetterKeep> {
  Database? db;
  String dbError = "";

  /// App links for deep linking (OAuth callback)
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _appLinksSubscription;

  @override
  void initState() {
    super.initState();

    // Initialize deep link handling for OAuth callback
    _initDeepLinks();

    _initDb().then((_) async {
      await ReminderCoordinator.instance.init();
      ReminderCoordinator.instance.attachUiActionListener();
      await ReminderCoordinator.instance.consumePendingUiActions();
      await ReminderCoordinator.instance.reconcileAll();

      // Check notification permission status (read-only, no prompt)
      ReminderPermissionService().checkAndNotify();

      // Initialize intent handler for opening/sharing files
      IntentHandlerService.instance.init();

      // Initialize subscription service for IAP early (doesn't require auth)
      // This allows products to load while user is logging in
      await SubscriptionService.instance.init();

      // Initialize subscription/plan tracking - this sets up auth state listener
      // so it will react when users sign in/out, even if not currently logged in
      await PlanService.instance.init();

      // Initialize E2EE for already logged-in users, then start sync
      if (AuthService.currentUser != null) {
        final shouldInitializeStandardSyncServices =
            await _initializeSignedInServices();
        if (shouldInitializeStandardSyncServices) {
          // These services initialize locally even when E2EE is unavailable.
          // Their readiness listeners start cloud activity after E2EE recovers.
          await NoteSyncService().init();
          await LabelSyncService().init();
          await NoteSortService().startCloudSync();
        }
      }
    });
  }

  Future<bool> _initializeSignedInServices() async {
    final user = AuthService.currentUser;
    if (user == null) return false;

    await FirebaseEmulatorConfig.verifyAuthenticatedFirestore(user);

    var isReviewSession = ReviewAccess.isAuthorizedSessionFor(user);
    if (!isReviewSession) {
      try {
        isReviewSession = await ReviewAccess.authorize(user);
        ReviewAccess.requireAuthorizedReviewIdentity(user, isReviewSession);
      } catch (e, stack) {
        AppLogger.error(
          '[Main] Review authorization refresh failed; cloud services disabled',
          e,
          stack,
        );
        if (e is ReviewAuthorizationException) {
          await AuthService.signOut();
        }
        return false;
      }
    }

    if (isReviewSession) {
      try {
        final authorization = ReviewAccess.authorizationFor(user);
        if (authorization == null) {
          throw StateError('Review authorization was not retained');
        }
        PlanService.instance.activateReviewSession(authorization);
        await E2EEService.instance.initializeReviewSession();
      } catch (e) {
        AppLogger.error('[Main] Review E2EE initialization error', e);
      }
      return false;
    }

    try {
      await E2EEService.instance.initialize();
    } catch (e) {
      AppLogger.error('[Main] E2EE initialization error', e);
    }

    try {
      await DeviceApprovalNotificationService().init();
    } catch (e) {
      AppLogger.error('[Main] DeviceApprovalNotificationService init error', e);
    }
    return true;
  }

  /// Initialize deep link handling for OAuth callback
  void _initDeepLinks() {
    _appLinks = AppLinks();

    // Handle app started via deep link
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) {
        _handleDeepLink(uri);
      }
    });

    // Handle deep links while app is running
    _appLinksSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
  }

  /// Handle deep link URI
  void _handleDeepLink(Uri uri) {
    // Query parameters can contain OAuth completion codes. Log only the route.
    AppLogger.log(
      '[DeepLink] Received: ${uri.scheme}://${uri.host}${uri.path}',
    );

    // Handle OAuth callback (betterkeep://auth?code=xxx&transactionId=xxx)
    if (uri.scheme == 'betterkeep' && uri.host == 'auth') {
      unawaited(
        AuthService.handleOAuthCallback(uri).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          AppLogger.error(
            '[DeepLink] OAuth completion failed',
            error,
            stackTrace,
          );
        }),
      );
    }

    // Handle password reset complete (betterkeep://password-reset-complete?email=xxx)
    // This is triggered when user completes password reset in browser (Windows/Linux)
    if (uri.scheme == 'betterkeep' && uri.host == 'password-reset-complete') {
      final email = uri.queryParameters['email'];
      AppLogger.log('[DeepLink] Password reset complete for: $email');

      // Show a snackbar notification to confirm password was reset
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = AppState.navigatorKey.currentContext;
        if (context != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Password reset successful! Please sign in with your new password.',
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    ReminderCoordinator.instance.detachUiActionListener();
    _appLinksSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (dbError.isNotEmpty) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    "Unable to start Better Keep",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "There was a problem initializing the database. "
                    "Please try restarting the app or reinstalling if the issue persists.",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Technical details: $dbError",
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        dbError = "";
                        db = null;
                      });
                      _initDb();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text("Retry"),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (db == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppState.theme,
        home: AuthScaffold(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: AppState.theme.colorScheme.primary
                        .withValues(alpha: 0.2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Starting...',
                style: TextStyle(
                  fontSize: 16,
                  color: AppState.theme.colorScheme.onSurface.withValues(
                    alpha: 0.7,
                  ),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return App();
  }

  Future<void> _initDb() async {
    try {
      final db = await initDatabase();
      LocalDataEncryption.setDatabaseGetter(() => db);
      await NoteSortService().init();
      // Resolve interrupted local lock transactions before the note UI, sync,
      // or preview repair can observe a partially switched set of file paths.
      final protectedFileOperations = await NoteLockFileOperations.platform();
      await NoteLockRecoveryService.recoverPending(
        database: db,
        fileOperations: protectedFileOperations,
      );
      await NoteLockRemovalRecoveryService.recoverPending(
        database: db,
        fileOperations: protectedFileOperations,
      );
      await LegacySketchMigrationRecoveryService.recoverPending(
        database: db,
        fileOperations: protectedFileOperations,
        journal: LegacySketchMigrationJournal(await AppState.prefs),
      );
      await NewAttachmentTransactionRecoveryService.recoverPending(
        database: db,
        operations: protectedFileOperations,
        journal: NewAttachmentTransactionJournal(await AppState.prefs),
      );
      await PendingAttachmentSourceCleanupRecoveryService.recoverPending(
        database: db,
        operations: protectedFileOperations,
        journal: PendingAttachmentSourceCleanupJournal(await AppState.prefs),
      );
      try {
        await (await AudioPlaybackSourceService.platform()).cleanupStaleFiles();
      } catch (error, stackTrace) {
        // Playback files are disposable. A cleanup failure must not prevent
        // the app from starting; the next launch will retry the same directory.
        AppLogger.error(
          'Failed to clean stale audio playback files',
          error,
          stackTrace,
        );
      }
      try {
        await (await ShareAttachmentStagingService.platform())
            .cleanupStaleFiles();
      } catch (error, stackTrace) {
        // Share copies contain plaintext by design but are disposable. Failure
        // is non-fatal and retried before notes are shown on the next launch.
        AppLogger.error(
          'Failed to clean stale share attachments',
          error,
          stackTrace,
        );
      }
      await Label.fixLabels();
      unawaited(SketchPreviewRepairService.runIfNeeded());
      setState(() {
        this.db = db;
      });
    } catch (e) {
      setState(() {
        dbError = e.toString();
      });
    }
  }
}

/// Firebase environment selection screen for debug mode
class FirebaseSelectionScreen extends StatefulWidget {
  final Future<void> Function(
    FirebaseEnvironment environment, {
    String? physicalDeviceHost,
    GoogleEmulatorAuthMode googleAuthMode,
  })
  onSelected;

  const FirebaseSelectionScreen({super.key, required this.onSelected});

  @override
  State<FirebaseSelectionScreen> createState() =>
      _FirebaseSelectionScreenState();
}

class _FirebaseSelectionScreenState extends State<FirebaseSelectionScreen> {
  bool _isLoading = false;
  String? _error;
  late final TextEditingController _hostController;
  late bool _useRealGoogleAuth;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(
      text: FirebaseEmulatorConfig.suggestedPhysicalDeviceHost,
    );
    _useRealGoogleAuth =
        FirebaseEmulatorConfig.savedGoogleAuthMode ==
        GoogleEmulatorAuthMode.real;
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _handleSelection(FirebaseEnvironment environment) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await widget.onSelected(
        environment,
        physicalDeviceHost:
            environment == FirebaseEnvironment.emulator &&
                FirebaseEmulatorConfig.isPhysicalDevice
            ? _hostController.text
            : null,
        googleAuthMode: _useRealGoogleAuth
            ? GoogleEmulatorAuthMode.real
            : GoogleEmulatorAuthMode.mock,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.build_circle,
                      size: 64,
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '🔧 Debug Mode',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Select Firebase environment:',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (FirebaseEmulatorConfig.isPhysicalDevice) ...[
                      const SizedBox(height: 24),
                      TextField(
                        controller: _hostController,
                        enabled: !_isLoading,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Computer LAN host',
                          hintText: '192.168.1.25',
                          helperText:
                              'Use the computer IP on the same Wi-Fi. Do not '
                              'include http:// or a port.',
                        ),
                      ),
                    ],
                    if (FirebaseEmulatorConfig
                        .supportsRealGoogleAuthToggle) ...[
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Use real Google OAuth'),
                        subtitle: const Text(
                          'Off uses a deterministic google.com test identity. '
                          'Real OAuth requires internet.',
                        ),
                        value: _useRealGoogleAuth,
                        onChanged: _isLoading
                            ? null
                            : (value) {
                                setState(() {
                                  _useRealGoogleAuth = value;
                                });
                              },
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_isLoading)
                      const Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Configuring Firebase...'),
                        ],
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: _EnvironmentCard(
                              icon: Icons.cloud,
                              iconColor: Colors.blue,
                              title: 'Live',
                              subtitle: 'Production Firebase',
                              onTap: () =>
                                  _handleSelection(FirebaseEnvironment.live),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: _EnvironmentCard(
                              icon: Icons.computer,
                              iconColor: Colors.orange,
                              title: 'Emulator',
                              subtitle: 'Local development',
                              onTap: () => _handleSelection(
                                FirebaseEnvironment.emulator,
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      SelectableText(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      'Choose an environment on every debug launch. The '
                      'emulator host and Google OAuth preference are '
                      'remembered. Emulator mode never falls back to '
                      'production.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EnvironmentCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _EnvironmentCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: iconColor),
              const SizedBox(height: 10),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
