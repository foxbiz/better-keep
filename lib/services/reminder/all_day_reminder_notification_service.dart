import 'dart:io';

import 'package:better_keep/models/note.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service to show persistent silent notifications for "All Day" reminders
class AllDayReminderNotificationService {
  static final AllDayReminderNotificationService _instance =
      AllDayReminderNotificationService._internal();
  factory AllDayReminderNotificationService() => _instance;
  AllDayReminderNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'all_day_reminder';
  static const String _channelName = 'All Day Reminders';
  static const String _channelDescription =
      'Persistent notifications for all day reminders';

  // Offset to avoid collision with other notification IDs
  static const int _notificationIdOffset = 100000;

  bool _initialized = false;

  /// Initialize the notification service
  Future<void> init() async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false, // Silent
    );
    const macosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false, // Silent
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: macosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    // Create Android notification channel - low importance for silent
    if (Platform.isAndroid) {
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.low, // Silent but visible
              playSound: false,
              enableVibration: false,
            ),
          );
    }

    _initialized = true;
  }

  /// Show a persistent silent notification for an all-day reminder
  Future<void> showAllDayNotification(Note note) async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    if (!_initialized) {
      await init();
    }

    if (note.id == null || note.reminder == null || !note.reminder!.isAllDay) {
      return;
    }

    final notificationId = _getNotificationId(note.id!);
    final title = note.title ?? 'Reminder';
    final body = note.body;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true, // Persistent - can't be swiped away
      autoCancel: false, // Don't cancel when tapped
      playSound: false,
      enableVibration: false,
      showWhen: true,
      category: AndroidNotificationCategory.reminder,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
    );

    const macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: macosDetails,
    );

    await _notifications.show(
      notificationId,
      title,
      body,
      details,
      payload: note.id.toString(),
    );
  }

  /// Cancel notification for a specific note
  Future<void> cancelNotification(int noteId) async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    final notificationId = _getNotificationId(noteId);
    await _notifications.cancel(notificationId);
  }

  /// Cancel all all-day reminder notifications
  Future<void> cancelAllNotifications() async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    // Note: This will cancel ALL notifications from this plugin
    // In a production app, you might want to track and cancel only specific IDs
    await _notifications.cancelAll();
  }

  /// Check all notes and show notifications for active all-day reminders
  Future<void> showActiveAllDayReminders(List<Note> notes) async {
    if (kIsWeb ||
        (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS)) {
      return;
    }

    if (!_initialized) {
      await init();
    }

    for (final note in notes) {
      if (note.isAllDayReminderActive) {
        await showAllDayNotification(note);
      }
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    // User tapped notification - app will open to handle it
  }

  int _getNotificationId(int noteId) {
    // Use offset to avoid collision with other services
    return (noteId.hashCode.abs() % _notificationIdOffset) +
        _notificationIdOffset;
  }
}
