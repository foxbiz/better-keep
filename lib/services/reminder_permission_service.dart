import 'dart:io';

import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service to handle just-in-time permission requests for reminders.
/// Permissions are only requested when the user actually tries to set a reminder,
/// not at app startup.
class ReminderPermissionService {
  static final ReminderPermissionService _instance =
      ReminderPermissionService._internal();

  factory ReminderPermissionService() => _instance;

  ReminderPermissionService._internal();

  /// Notifier that tracks whether all required permissions are granted.
  /// UI can listen to this to show/hide permission prompts.
  final ValueNotifier<bool> permissionGranted = ValueNotifier<bool>(true);

  /// Ensures all required permissions for reminders are granted.
  /// Returns true if all permissions are granted, false otherwise.
  /// This should be called before setting a reminder.
  Future<bool> ensurePermissions(ReminderType type) async {
    if (type == ReminderType.unsupported) return false;
    if (type == ReminderType.notification) {
      if (!LocalNotificationService.instance.supportsScheduling) return true;
      return LocalNotificationService.instance.requestReminderPermissions(
        exact: true,
      );
    }
    if (!isAlarmSupported) return true;

    bool result;
    if (Platform.isAndroid) {
      result = await _ensureAndroidPermissions();
    } else if (Platform.isIOS) {
      result = await _ensureIOSPermissions();
    } else {
      result = true;
    }

    if (result) {
      permissionGranted.value = true;
    }

    return result;
  }

  Future<bool> _ensureAndroidPermissions() async {
    // Request notification permission
    final notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted) {
      final result = await Permission.notification.request();
      if (!result.isGranted) {
        return false;
      }
    }

    // Request exact alarm permission (required for Android 12+)
    final exactAlarmStatus = await Permission.scheduleExactAlarm.status;
    if (!exactAlarmStatus.isGranted) {
      final result = await Permission.scheduleExactAlarm.request();
      if (!result.isGranted) {
        return false;
      }
    }

    return true;
  }

  Future<bool> _ensureIOSPermissions() async {
    final notificationStatus = await Permission.notification.status;
    if (!notificationStatus.isGranted) {
      final result = await Permission.notification.request();
      if (!result.isGranted) {
        return false;
      }
    }

    return true;
  }

  /// Checks if all required permissions are already granted without requesting them.
  Future<bool> hasPermissions([ReminderType type = ReminderType.alarm]) async {
    if (type == ReminderType.unsupported) return false;
    if (type == ReminderType.notification) {
      if (!LocalNotificationService.instance.supportsScheduling) return true;
      return LocalNotificationService.instance.hasReminderPermissions(
        exact: true,
      );
    }
    if (!isAlarmSupported) return true;

    if (Platform.isAndroid) {
      final notificationStatus = await Permission.notification.status;
      final exactAlarmStatus = await Permission.scheduleExactAlarm.status;
      return notificationStatus.isGranted && exactAlarmStatus.isGranted;
    } else if (Platform.isIOS) {
      final notificationStatus = await Permission.notification.status;
      return notificationStatus.isGranted;
    }

    return true;
  }

  Future<bool> openSystemSettings() => openAppSettings();

  /// Checks current permission status and updates [permissionGranted] notifier.
  /// This is a read-only check — it does NOT prompt the user.
  Future<void> checkAndNotify() async {
    if (!isAlarmSupported) {
      permissionGranted.value = true;
      return;
    }
    permissionGranted.value = await hasPermissions(ReminderType.alarm);
  }

  /// Reschedules alarms for all notes with active reminders.
  /// Call after permissions are newly granted to catch alarms that
  /// silently failed due to missing permissions.
  Future<void> rescheduleAllAlarms() async {
    if (!isAlarmSupported) return;

    try {
      final notes = await Note.get(NoteType.all);
      for (final note in notes) {
        if (note.reminder != null && !note.completed) {
          await note.setAlarm();
        }
      }
    } catch (e) {
      AppLogger.log("Error rescheduling alarms after permission grant: $e");
    }
  }
}
