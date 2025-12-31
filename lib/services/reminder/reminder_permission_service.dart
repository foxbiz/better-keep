import 'dart:io';

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

  /// Ensures all required permissions for reminders are granted.
  /// Returns true if all permissions are granted, false otherwise.
  /// This should be called before setting a reminder.
  Future<bool> ensurePermissions() async {
    if (kIsWeb) {
      return true;
    }

    if (Platform.isAndroid) {
      return await _ensureAndroidPermissions();
    } else if (Platform.isIOS) {
      return await _ensureIOSPermissions();
    }

    return true;
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
  Future<bool> hasPermissions() async {
    if (kIsWeb) {
      return true;
    }

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
}
