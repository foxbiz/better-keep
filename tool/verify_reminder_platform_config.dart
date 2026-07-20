import 'dart:io';

void main() {
  final checks = <String, List<String>>{
    'android/app/src/main/AndroidManifest.xml': [
      'ScheduledNotificationReceiver',
      'ScheduledNotificationBootReceiver',
      'ActionBroadcastReceiver',
      'android.permission.SCHEDULE_EXACT_ALARM',
    ],
    'android/app/src/main/res/drawable/ic_stat_better_keep.xml': [
      'android:width="24dp"',
      'android:fillColor="#FFFFFFFF"',
    ],
    'ios/Runner/AppDelegate.swift': [
      'import flutter_local_notifications',
      'setPluginRegistrantCallback',
    ],
    'ios/Runner/Runner.entitlements': [
      'com.apple.developer.usernotifications.time-sensitive',
    ],
    'macos/Runner/DebugProfile.entitlements': [
      'com.apple.developer.usernotifications.time-sensitive',
    ],
    'macos/Runner/Release.entitlements': [
      'com.apple.developer.usernotifications.time-sensitive',
    ],
    'pubspec.yaml': [
      'flutter_local_notifications: ^22.0.1',
      'flutter_timezone: ^5.1.0',
      'timezone: ^0.11.1',
      'identity_name: FoxbizSotware.BetterKeepNotes',
    ],
    'lib/services/reminder_time_zone_resolver.dart': [
      'timezone/data/latest_all.dart',
      'ReminderTimeZoneException',
    ],
    'lib/services/local_notification_service.dart': [
      'ReminderTimeZoneResolver.resolve',
      'pendingNotificationRequests()',
      'containsPendingReminderRegistration',
      'showsUserInterface: false',
      'cancelNotification: false',
      'cancelAllReminderDeliveries',
      'applyReminderPlan',
      'supportsDeviceApprovalNotifications',
    ],
    'lib/services/reminder_notification_plan.dart': [
      'ReminderNotificationPlanner',
      'Reminder.repeatMonthly',
      'Reminder.repeatYearly',
      '_iosCapacity = 60',
      '_androidCapacity = 480',
    ],
    'lib/services/reminder_sync_codec.dart': [
      "stateField = 'reminder_state_v3'",
      "'source': source",
      "'generation':",
    ],
    'functions/src/exports/resolveLegacyReminderState.ts': [
      'detectLegacyReminderTransition',
      'FieldValue.delete()',
      'reminder_state_v3',
    ],
    'lib/services/reminder_action_processor.dart': [
      'ReminderActionState',
      'ReminderActionReceiptService.claim',
      "'sync_track'",
    ],
    'lib/services/reminder_navigation_service.dart': [
      'pending_reminder_navigation_note_id',
      'registerReadyHost',
      'openFromNotification',
      'duplicate_activation',
      'Duration(seconds: 10)',
      'ReminderSessionService.isSignedIn',
    ],
    'lib/services/device_approval_notification_service.dart': [
      'supportsDeviceApprovalNotifications',
      '_listenerAttached',
      'cancelDeviceApproval',
    ],
    'lib/services/reminder_action_receipt_service.dart': [
      'note_id INTEGER',
      'action TEXT',
      'ui_consumed_at TEXT',
    ],
  };

  final failures = <String>[];
  for (final entry in checks.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      failures.add('${entry.key}: missing');
      continue;
    }
    final contents = file.readAsStringSync();
    for (final expected in entry.value) {
      if (!contents.contains(expected)) {
        failures.add('${entry.key}: missing "$expected"');
      }
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('Reminder platform configuration is incomplete:');
    for (final failure in failures) {
      stderr.writeln(' - $failure');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Reminder platform configuration verified.');
}
