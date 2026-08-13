import 'dart:async';
import 'dart:io';

import 'package:better_keep/config.dart';
import 'package:better_keep/services/async_initialization_gate.dart';
import 'package:better_keep/services/reminder_notification_registration.dart';
import 'package:better_keep/services/reminder_notification_plan.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:better_keep/services/reminder_time_zone_resolver.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

typedef ReminderNotificationResponseHandler =
    FutureOr<void> Function(NotificationResponse response);

/// Owns the single flutter_local_notifications instance used by the app.
/// Feature services get their own ID namespaces, but initialization and action
/// routing happen exactly once so callbacks cannot overwrite each other.
class LocalNotificationService {
  LocalNotificationService._() : _initializationOverride = null;

  @visibleForTesting
  LocalNotificationService.forTesting({
    required Future<void> Function() initialize,
  }) : _initializationOverride = initialize;

  static final instance = LocalNotificationService._();

  static const reminderChannelId = 'note_reminders_v1';
  static const reminderCategoryId = 'note_reminder';
  static const markDoneActionId = 'mark_done';
  static const smallIcon = 'ic_stat_better_keep';
  static const _maxOccurrenceSlots =
      ReminderNotificationPlanner.maxOccurrenceSlots;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final Future<void> Function()? _initializationOverride;
  final AsyncInitializationGate _initializationGate = AsyncInitializationGate();
  ReminderNotificationResponseHandler? _responseHandler;
  String? _timeZoneIdentifier;
  tz.Location? _timeZoneLocation;
  Object? _timeZoneError;
  String _markDoneLabel = 'Mark as Done';
  String _reminderChannelName = 'Better Keep';
  String _reminderChannelDescription = 'Better Keep';
  bool _pluginInitialized = false;

  bool get supportsScheduling {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get supportsDeviceApprovalNotifications => supportsScheduling;

  bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  String? get timeZoneIdentifier => _timeZoneIdentifier;
  bool get hasResolvedTimeZone => _timeZoneLocation != null;
  String get markDoneLabel => _markDoneLabel;

  Future<void> init({
    required ReminderNotificationResponseHandler onResponse,
    required DidReceiveBackgroundNotificationResponseCallback
    onBackgroundResponse,
  }) {
    _responseHandler = onResponse;
    return _initializationGate.run(() async {
      final override = _initializationOverride;
      if (override != null) return override();
      await _init(onBackgroundResponse, handleLaunchResponse: true);
    });
  }

  Future<void> initForBackgroundAction({
    required DidReceiveBackgroundNotificationResponseCallback
    onBackgroundResponse,
  }) {
    _responseHandler ??= (_) {};
    return _initializationGate.run(() async {
      final override = _initializationOverride;
      if (override != null) return override();
      await _init(onBackgroundResponse, handleLaunchResponse: false);
    });
  }

  Future<void> _init(
    DidReceiveBackgroundNotificationResponseCallback onBackgroundResponse, {
    required bool handleLaunchResponse,
  }) async {
    if (!supportsScheduling) return;
    await _configureTimeZone();

    final l10n = currentAppLocalizations();
    _markDoneLabel = l10n.markAsDone;
    _reminderChannelName = l10n.noteReminders;
    _reminderChannelDescription = l10n.noteRemindersDescription;

    final categories = <DarwinNotificationCategory>[
      DarwinNotificationCategory(
        reminderCategoryId,
        actions: <DarwinNotificationAction>[
          DarwinNotificationAction.plain(markDoneActionId, _markDoneLabel),
        ],
      ),
    ];
    final settings = InitializationSettings(
      android: const AndroidInitializationSettings(smallIcon),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: categories,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        notificationCategories: categories,
      ),
      windows: const WindowsInitializationSettings(
        appName: appLabel,
        appUserModelId: 'FoxbizSotware.BetterKeepNotes',
        guid: '886c9a5b-2d6e-4ae6-822d-de6c845ecd7d',
      ),
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _dispatchResponse,
      onDidReceiveBackgroundNotificationResponse: onBackgroundResponse,
    );
    if (!kIsWeb && Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            AndroidNotificationChannel(
              reminderChannelId,
              _reminderChannelName,
              description: _reminderChannelDescription,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
              audioAttributesUsage: AudioAttributesUsage.notification,
            ),
          );
    }

    if (handleLaunchResponse) {
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final response = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true && response != null) {
        await _dispatchResponse(response);
      }
    }
    _pluginInitialized = true;
  }

  Future<bool> refreshTimeZone() async {
    if (!supportsScheduling) return false;
    final previous = _timeZoneIdentifier;
    final wasResolved = hasResolvedTimeZone;
    await _configureTimeZone();
    return previous != _timeZoneIdentifier ||
        wasResolved != hasResolvedTimeZone;
  }

  Future<void> _configureTimeZone() async {
    try {
      final timeZone = await FlutterTimezone.getLocalTimezone();
      _timeZoneIdentifier = timeZone.identifier;
      _timeZoneLocation = ReminderTimeZoneResolver.resolve(timeZone.identifier);
      _timeZoneError = null;
      tz.setLocalLocation(_timeZoneLocation!);
      await AppLogger.log(
        'Reminder timezone resolved: native=${timeZone.identifier}, '
        'location=${_timeZoneLocation!.name}',
      );
    } catch (error, stackTrace) {
      _timeZoneLocation = null;
      _timeZoneError = error;
      await AppLogger.error(
        'Reminder timezone resolution failed '
        '(native=${_timeZoneIdentifier ?? 'unavailable'})',
        error,
        stackTrace,
      );
    }
  }

  Future<bool> requestReminderPermissions({required bool exact}) async {
    if (!supportsScheduling) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;
      final notifications =
          await android.requestNotificationsPermission() ?? false;
      await AppLogger.log(
        'Reminder notification permission request: notifications=$notifications',
      );
      if (!notifications) return false;
      if (!exact) return true;
      if (await android.canScheduleExactNotifications() == true) {
        await AppLogger.log(
          'Reminder notification permission request: exact=true',
        );
        return true;
      }
      final exactGranted =
          await android.requestExactAlarmsPermission() ?? false;
      await AppLogger.log(
        'Reminder notification permission request: exact=$exactGranted',
      );
      return exactGranted;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false) ??
          false;
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false) ??
          false;
    }

    return true;
  }

  Future<bool> hasReminderPermissions({required bool exact}) async {
    if (!supportsScheduling) return false;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;
      if (await android.areNotificationsEnabled() != true) return false;
      return !exact || await android.canScheduleExactNotifications() == true;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final permissions = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return permissions?.isEnabled ?? false;
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final permissions = await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return permissions?.isEnabled ?? false;
    }
    return true;
  }

  Future<void> scheduleReminder({
    required int noteId,
    required int occurrenceIndex,
    required DateTime dateTime,
    required String title,
    required String body,
    required String payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    final location = _timeZoneLocation;
    if (location == null) {
      final resolutionError = _timeZoneError;
      if (resolutionError is ReminderTimeZoneException) {
        throw resolutionError;
      }
      throw ReminderTimeZoneException(_timeZoneIdentifier, resolutionError);
    }
    final scheduledDate = tz.TZDateTime(
      location,
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      dateTime.second,
    );
    final androidDetails = AndroidNotificationDetails(
      reminderChannelId,
      _reminderChannelName,
      channelDescription: _reminderChannelDescription,
      icon: smallIcon,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.private,
      playSound: true,
      enableVibration: true,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          markDoneActionId,
          _markDoneLabel,
          semanticAction: SemanticAction.markAsRead,
          showsUserInterface: false,
          cancelNotification: false,
        ),
      ],
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
      categoryIdentifier: reminderCategoryId,
      interruptionLevel: InterruptionLevel.timeSensitive,
      threadIdentifier: 'note-reminders',
    );
    final windowsDetails = WindowsNotificationDetails(
      scenario: WindowsNotificationScenario.reminder,
      actions: <WindowsAction>[
        WindowsAction(content: _markDoneLabel, arguments: markDoneActionId),
      ],
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      windows: windowsDetails,
    );

    final notificationId = reminderNotificationId(noteId, occurrenceIndex);
    await AppLogger.log(
      'Scheduling reminder notification: id=$notificationId, '
      'local=${scheduledDate.toIso8601String()}, zone=${location.name}, '
      'utc=${scheduledDate.toUtc().toIso8601String()}',
    );

    await _plugin.zonedSchedule(
      id: notificationId,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: isWindows ? null : matchDateTimeComponents,
      payload: payload,
    );

    final pending = await _plugin.pendingNotificationRequests();
    final registered = containsPendingReminderRegistration(
      requests: pending,
      notificationId: notificationId,
      payload: payload,
    );
    if (!registered) {
      await AppLogger.error(
        'Reminder notification registration verification failed: '
        'id=$notificationId, pending=${pending.length}',
      );
      // A platform implementation may fail to expose a just-scheduled
      // request consistently. Cancel defensively so a failed result cannot
      // leave an untracked notification behind.
      await _plugin.cancel(id: notificationId);
      throw ReminderNotificationRegistrationException(notificationId);
    }
    await AppLogger.log(
      'Reminder notification registered: id=$notificationId, '
      'zone=${location.name}, pending=${pending.length}',
    );
  }

  Future<void> applyReminderPlan(
    Iterable<PlannedReminderNotification> notifications, {
    bool forceRecreate = false,
  }) async {
    if (!supportsScheduling) return;
    final desired = <int, PlannedReminderNotification>{};
    for (final notification in notifications) {
      desired[reminderNotificationId(
            notification.noteId,
            notification.occurrenceIndex,
          )] =
          notification;
    }

    final pending = await _plugin.pendingNotificationRequests();
    final current = <int, PendingNotificationRequest>{
      for (final request in pending)
        if (isReminderNotificationPayload(request.payload)) request.id: request,
    };

    for (final entry in current.entries) {
      final planned = desired[entry.key];
      final payload = planned == null
          ? null
          : encodeReminderNotificationPayload(
              planned.noteId,
              planned.reminder,
              planned.dueAt,
            );
      final unchanged =
          !forceRecreate &&
          planned != null &&
          entry.value.payload == payload &&
          entry.value.title == planned.title &&
          entry.value.body == planned.body;
      if (!unchanged) await _plugin.cancel(id: entry.key);
    }

    for (final entry in desired.entries) {
      final planned = entry.value;
      final payload = encodeReminderNotificationPayload(
        planned.noteId,
        planned.reminder,
        planned.dueAt,
      );
      final existing = current[entry.key];
      final unchanged =
          !forceRecreate &&
          existing?.payload == payload &&
          existing?.title == planned.title &&
          existing?.body == planned.body;
      if (unchanged) continue;
      await scheduleReminder(
        noteId: planned.noteId,
        occurrenceIndex: planned.occurrenceIndex,
        dateTime: planned.dueAt,
        title: planned.title,
        body: planned.body,
        payload: payload,
        matchDateTimeComponents: switch (planned.nativeRepeat) {
          ReminderNativeRepeat.daily => DateTimeComponents.time,
          ReminderNativeRepeat.weekly => DateTimeComponents.dayOfWeekAndTime,
          null => null,
        },
      );
    }
  }

  Future<void> cancelReminder(int noteId) async {
    if (!supportsScheduling) return;
    for (var index = 0; index < _maxOccurrenceSlots; index++) {
      await _plugin.cancel(id: reminderNotificationId(noteId, index));
    }
    // Remove the ongoing notification created by releases before reminder
    // types existed. This is intentionally scoped to the legacy ID formula.
    await _plugin.cancel(id: (noteId.abs() % 100000) + 100000);
  }

  Future<int> cancelAllReminderDeliveries() async {
    if (!supportsScheduling) return 0;
    var pending = <PendingNotificationRequest>[];
    var active = <ActiveNotification>[];
    try {
      pending = await _plugin.pendingNotificationRequests();
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Failed to inspect pending reminder notifications',
        error,
        stackTrace,
      );
    }
    try {
      active = await _plugin.getActiveNotifications();
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Failed to inspect active reminder notifications',
        error,
        stackTrace,
      );
    }
    final ids = reminderDeliveryIds(pending: pending, active: active);
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
    await AppLogger.log(
      'Reminder delivery cleanup complete: cancelled=${ids.length}',
    );
    return ids.length;
  }

  Future<bool> showDeviceApproval({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!supportsDeviceApprovalNotifications || !_pluginInitialized) {
      return false;
    }
    final l10n = currentAppLocalizations();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'device_approval',
        l10n.deviceApproval,
        channelDescription: l10n.deviceApprovalDescription,
        icon: smallIcon,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
    return true;
  }

  Future<bool> cancelDeviceApproval(int id) async {
    if (!supportsDeviceApprovalNotifications || !_pluginInitialized) {
      return false;
    }
    await _plugin.cancel(id: id);
    return true;
  }

  Future<void> cancel(int id) async {
    if (!supportsScheduling || !_pluginInitialized) return;
    await _plugin.cancel(id: id);
  }

  int reminderNotificationId(int noteId, [int occurrenceIndex = 0]) {
    // Stable 31-bit FNV-1a keeps IDs deterministic across restarts without
    // relying on Dart hashCode randomisation.
    var hash = 0x811c9dc5;
    for (final unit in 'reminder:$noteId:$occurrenceIndex'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  Future<void> _dispatchResponse(NotificationResponse response) async {
    await _responseHandler?.call(response);
  }
}
