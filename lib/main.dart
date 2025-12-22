import 'dart:io';
import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:better_keep/app.dart';
import 'package:better_keep/components/alarm_banner.dart';
import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/all_day_reminder_notification_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:better_keep/utils/db_init.dart'
    if (dart.library.html) 'package:better_keep/utils/db_init_web.dart'
    if (dart.library.io) 'package:better_keep/utils/db_init_native.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  initializeDb();

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await Alarm.init();
  }

  await AlarmIdService.init();
  await AppState.init();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Configure Firebase Emulators if enabled (for local development)
  await FirebaseEmulatorConfig.configureEmulators();

  if (kIsWeb || Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    // Use debug provider in debug/profile mode, production providers in release
    // kReleaseMode is true only in release builds
    final androidProvider = kReleaseMode
        ? AndroidPlayIntegrityProvider()
        : AndroidDebugProvider();
    final appleProvider = kReleaseMode
        ? AppleAppAttestProvider()
        : AppleDebugProvider();

    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaV3Provider(
        const String.fromEnvironment('GOOGLE_RECAPTCHA_SITE_KEY'),
      ),
      providerAndroid: androidProvider,
      providerApple: appleProvider,
    );
  }
  await AuthService.init();
  AppLogger.log(
    '[Main] AuthService initialized, currentUser: ${AuthService.currentUser?.email}',
  );

  // Pre-load user avatar for smooth Hero transitions
  UserAvatar.preloadAvatar();

  AppLogger.log('[Main] Starting runApp');
  runApp(BetterKeep());
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

  @override
  void initState() {
    super.initState();

    // Initialize the ringing alarm service for in-app banner
    RingingAlarmService().init();

    _initDb().then((_) async {
      _startAlarmListeners();
      // Check for active all-day reminders on app startup
      _showActiveAllDayReminders();

      // Initialize subscription service for IAP early (doesn't require auth)
      // This allows products to load while user is logging in
      await SubscriptionService.instance.init();

      // Initialize E2EE for already logged-in users, then start sync
      if (AuthService.currentUser != null) {
        // Initialize subscription/plan tracking
        await PlanService.instance.init();
        try {
          await E2EEService.instance.initialize();
          // Initialize device approval notifications
          try {
            await DeviceApprovalNotificationService().init();
          } catch (e) {
            AppLogger.error(
              '[Main] DeviceApprovalNotificationService init error',
              e,
            );
          }
          // Initialize all-day reminder notifications
          AllDayReminderNotificationService().init();
          // Start sync after E2EE is initialized
          NoteSyncService().init();
          LabelSyncService().init();
        } catch (e) {
          AppLogger.error('[Main] E2EE initialization error', e);
          // Still try to start sync services even if E2EE fails
          AllDayReminderNotificationService().init();
          NoteSyncService().init();
          LabelSyncService().init();
        }
      } else {
        // No user logged in, start sync services anyway
        AllDayReminderNotificationService().init();
        NoteSyncService().init();
        LabelSyncService().init();
      }
    });
  }

  Future<void> _showActiveAllDayReminders() async {
    final notes = await Note.get(NoteType.all);
    await AllDayReminderNotificationService().showActiveAllDayReminders(notes);
  }

  @override
  void dispose() {
    _alarmRingingSubscription?.cancel();
    RingingAlarmService().dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (dbError.isNotEmpty) {
      return MaterialApp(
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
      // Set up database getter for local data encryption migration
      LocalDataEncryption.setDatabaseGetter(() => db);
      setState(() {
        this.db = db;
      });
    } catch (e) {
      setState(() {
        dbError = e.toString();
      });
    }
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
