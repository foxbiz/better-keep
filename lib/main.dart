import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:app_links/app_links.dart';
import 'package:better_keep/app.dart';
import 'package:better_keep/components/alarm_banner.dart';
import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/all_day_reminder_notification_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/note_sync_service.dart';
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
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Load SharedPreferences once and share across services
  final prefsInstance = await SharedPreferences.getInstance();

  // Run independent initializations in parallel for faster startup
  await Future.wait([
    // Alarm init (Android/iOS only)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) Alarm.init(),
    // Load alarm ID mappings
    AlarmIdService.init(prefs: prefsInstance),
    // Load app state (theme, settings, etc.)
    AppState.init(prefs: prefsInstance),
    // Initialize Firebase
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    // Detect physical vs emulator Android so the correct emulator host is used
    FirebaseEmulatorConfig.initDeviceInfo(),
  ]);

  // In release mode, no emulator configuration needed
  // In debug mode, the user will be prompted to select Firebase environment
  // after the app UI is ready (in _BetterKeepState) if no saved choice exists
  FirebaseEmulatorConfig.init(prefsInstance);
  if (!kDebugMode) {
    await FirebaseEmulatorConfig.configureEmulators();
  }

  // Initialize AuthService (uses cached prefs, deferred token validation)
  await AuthService.init(prefs: prefsInstance);
  AppLogger.log(
    '[Main] AuthService initialized, currentUser: ${AuthService.currentUser?.email}',
  );

  // Activate FirebaseAppCheck in the background (not blocking startup)
  // This runs after runApp so it doesn't delay first frame
  _activateAppCheckInBackground();

  // Pre-load user avatar for smooth Hero transitions
  UserAvatar.preloadAvatar();

  // Initialize app install service for web PWA prompts
  if (kIsWeb) {
    AppInstallService.instance.init();
  }

  // For logged-in users, pre-load E2EE cached status before runApp
  // This allows returning approved users to skip the loading screen
  if (AuthService.currentUser != null) {
    await E2EEService.instance.preloadCachedStatus();
  }

  AppLogger.log('[Main] Starting runApp');

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

  runApp(BetterKeep());
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

class BetterKeep extends StatefulWidget {
  const BetterKeep({super.key});

  @override
  State<BetterKeep> createState() => _BetterKeepState();
}

class _BetterKeepState extends State<BetterKeep> {
  Database? db;
  String dbError = "";
  StreamSubscription<AlarmSet>? _alarmRingingSubscription;
  final Map<int, int> _ringingAlarmNoteIds = {};

  /// Whether Firebase environment has been selected (debug mode only)
  bool _firebaseConfigured = !kDebugMode;

  /// App links for deep linking (OAuth callback)
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _appLinksSubscription;

  @override
  void initState() {
    super.initState();

    // Initialize the ringing alarm service for in-app banner
    RingingAlarmService().init();

    // Initialize deep link handling for OAuth callback
    _initDeepLinks();

    // In debug mode, check for saved Firebase choice and apply it
    if (kDebugMode) {
      _initFirebaseConfig();
    }

    _initDb().then((_) async {
      _startAlarmListeners();
      // Check for active all-day reminders on app startup
      _showActiveAllDayReminders();

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
        AllDayReminderNotificationService().init();
        await _initializeSignedInServices();
        NoteSyncService().init();
        LabelSyncService().init();
      } else {
        AllDayReminderNotificationService().init();
      }
    });
  }

  Future<void> _showActiveAllDayReminders() async {
    final notes = await Note.get(NoteType.all);
    await AllDayReminderNotificationService().showActiveAllDayReminders(notes);
  }

  Future<void> _initializeSignedInServices() async {
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
    AppLogger.log('[DeepLink] Received: $uri');

    // Handle OAuth callback (betterkeep://auth?token=xxx)
    if (uri.scheme == 'betterkeep' && uri.host == 'auth') {
      AuthService.handleOAuthCallback(uri);
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
    _alarmRingingSubscription?.cancel();
    _appLinksSubscription?.cancel();
    RingingAlarmService().dispose();
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

    // In debug mode, show Firebase selection screen if not configured
    if (kDebugMode && !_firebaseConfigured) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppState.theme,
        home: _FirebaseSelectionScreen(
          onSelected: (useEmulators) async {
            if (useEmulators) {
              await FirebaseEmulatorConfig.connectToEmulators();
            } else {
              await FirebaseEmulatorConfig.useLiveFirebase();
            }
            setState(() {
              _firebaseConfigured = true;
            });
          },
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
      await Label.fixLabels();
      setState(() {
        this.db = db;
      });
    } catch (e) {
      setState(() {
        dbError = e.toString();
      });
    }
  }

  /// Initialize Firebase configuration in debug mode
  /// If a choice was previously saved, it will be applied automatically.
  Future<void> _initFirebaseConfig() async {
    if (!kDebugMode) return;

    // Check if user already made a choice before
    if (FirebaseEmulatorConfig.hasSavedChoice) {
      try {
        await FirebaseEmulatorConfig.applySavedChoice();
        if (mounted) {
          setState(() {
            _firebaseConfigured = true;
          });
        }
      } catch (e) {
        // Saved emulator choice is no longer valid (emulators not running).
        // Leave _firebaseConfigured = false so the selection screen is shown.
        AppLogger.log(
          '[Main] Saved Firebase choice failed, showing selection screen: $e',
        );
      }
    }
    // If no saved choice (or saved choice failed), the selection screen will be shown in build()
  }

  void _startAlarmListeners() {
    _alarmRingingSubscription ??= Alarm.ringing.listen((alarmSet) {
      final currentAlarms = alarmSet.alarms;
      final currentIds = currentAlarms.map((alarm) => alarm.id).toSet();

      for (final alarm in currentAlarms) {
        final noteId = int.tryParse(alarm.payload ?? '');
        if (noteId != null) {
          _ringingAlarmNoteIds[alarm.id] = noteId;
        }
      }

      final endedAlarmIds = _ringingAlarmNoteIds.keys
          .where((alarmId) => !currentIds.contains(alarmId))
          .toList();

      for (final alarmId in endedAlarmIds) {
        final noteId = _ringingAlarmNoteIds.remove(alarmId);
        if (noteId == null) {
          continue;
        }

        unawaited(_completeNoteFromAlarm(noteId));
      }
    });
  }

  Future<void> _completeNoteFromAlarm(int noteId) async {
    if (db == null) {
      return;
    }

    final note = await Note.findById(noteId);
    if (note == null) {
      return;
    }

    if (note.completed) {
      return;
    }

    await note.done();
  }
}

/// Firebase environment selection screen for debug mode
class _FirebaseSelectionScreen extends StatefulWidget {
  final Future<void> Function(bool useEmulators) onSelected;

  const _FirebaseSelectionScreen({required this.onSelected});

  @override
  State<_FirebaseSelectionScreen> createState() =>
      _FirebaseSelectionScreenState();
}

class _FirebaseSelectionScreenState extends State<_FirebaseSelectionScreen> {
  bool _isLoading = false;
  String? _error;

  Future<void> _handleSelection(bool useEmulators) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await widget.onSelected(useEmulators);
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.build_circle, size: 64, color: Colors.orange),
                const SizedBox(height: 24),
                Text(
                  '🔧 Debug Mode',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Select Firebase environment:',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
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
                          onTap: () => _handleSelection(false),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: _EnvironmentCard(
                          icon: Icons.computer,
                          iconColor: Colors.orange,
                          title: 'Emulator',
                          subtitle: 'Local development',
                          onTap: () => _handleSelection(true),
                        ),
                      ),
                    ],
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
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
                  'This choice will be remembered.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
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
