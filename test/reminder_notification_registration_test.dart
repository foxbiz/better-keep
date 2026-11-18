import 'dart:async';

import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_notification_plan.dart';
import 'package:better_keep/services/reminder_notification_registration.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_sign_out_cleanup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _WindowsNotifications extends Fake
    with MockPlatformInterfaceMixin
    implements FlutterLocalNotificationsWindows {
  final calls = <String>[];
  bool failInitialization = false;

  @override
  Future<bool> initialize({
    required WindowsInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    calls.add('initialize');
    if (failInitialization) throw PlatformException(code: 'unavailable');
    return true;
  }

  @override
  Future<void> cancelAll() async => calls.add('cancelAll');
}

const mobileAndMac = {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.macOS,
};
void registerPlugin() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      AndroidFlutterLocalNotificationsPlugin.registerWith();
    case TargetPlatform.iOS:
      IOSFlutterLocalNotificationsPlugin.registerWith();
    case TargetPlatform.macOS:
      MacOSFlutterLocalNotificationsPlugin.registerWith();
    default:
      throw UnsupportedError('Unexpected test platform');
  }
}

void main() {
  testWidgets(
    'a lost sign-out reply can be retried without cancelling later deliveries',
    (tester) async {
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final firstReply = Completer<void>();
      final calls = <String>[];
      registerPlugin();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (calls.length == 1) await firstReply.future;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
      });
      final notifications = LocalNotificationService.instance;
      final timedOut = expectLater(
        notifications.cancelForSignOut(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump(const Duration(seconds: 11));
      await timedOut;
      await notifications.cancelForSignOut();
      firstReply.complete();
      await tester.pump();
      expect(calls, ['cancelAll', 'cancelAll']);
    },
    variant: TargetPlatformVariant(mobileAndMac),
  );

  testWidgets('sign-out clears reminder navigation after a platform error', (
    tester,
  ) async {
    registerPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = tester.binding.defaultBinaryMessenger;
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'cancelAll');
      attempts++;
      throw PlatformException(code: 'unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    SharedPreferences.setMockInitialValues({
      'pending_reminder_navigation_note_id': 101,
    });
    await ReminderSignOutCleanupService.cancelDeliveries();
    final notifications = LocalNotificationService.instance;
    final generation = await notifications.prepareDeliveries();
    expect(generation, isNotNull);
    expect(
      await notifications.acceptsReminder({'deliveryGeneration': generation}),
      isTrue,
    );
    expect(await notifications.acceptsReminder({'noteId': 1}), isFalse);
    expect(attempts, 1);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'pending_reminder_navigation_note_id',
      ),
      false,
    );
  }, variant: TargetPlatformVariant(mobileAndMac));

  testWidgets('sign-out during a reminder plan quietly supersedes scheduling', (
    tester,
  ) async {
    registerPlugin();
    SharedPreferences.setMockInitialValues({
      'notification_delivery_generation': 'before',
    });
    final prefs = await SharedPreferences.getInstance();
    final notifications = LocalNotificationService.forTesting(
      initialize: () async {},
    );
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'pendingNotificationRequests');
      await prefs.setString('notification_delivery_generation', 'after');
      return [];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final due = DateTime.utc(2030);
    final planned = PlannedReminderNotification(
      candidate: ReminderNotificationCandidate(
        noteId: 42,
        reminder: Reminder(dateTime: due),
        title: 'QA',
        body: '',
      ),
      occurrenceIndex: 0,
      dueAt: due,
    );
    await notifications.applyReminderPlan([
      planned,
    ], deliveryGeneration: 'before');
    expect(calls, ['pendingNotificationRequests']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  test('late native scheduling removes the retired notification', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    registerPlugin();
    SharedPreferences.setMockInitialValues({
      'notification_delivery_generation': 'v2:first',
    });
    final prefs = await SharedPreferences.getInstance();
    final notifications = LocalNotificationService.forTesting(
      initialize: () async {},
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const zone = MethodChannel('flutter_timezone');
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    messenger.setMockMethodCallHandler(zone, (_) async => 'UTC');
    addTearDown(() => messenger.setMockMethodCallHandler(zone, null));
    final pending = <Map<String, dynamic>>[];
    final cancelled = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'pendingNotificationRequests':
          return pending;
        case 'zonedSchedule':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          pending.add(args);
          await prefs.setString('notification_delivery_generation', 'v2:next');
          return null;
        case 'cancel':
          cancelled.add((call.arguments as Map)['id'] as int);
          return null;
        default:
          fail('Unexpected notification call ${call.method}');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await notifications.refreshTimeZone();
    final due = DateTime.now().add(const Duration(days: 1));
    await notifications.applyReminderPlan([
      PlannedReminderNotification(
        candidate: ReminderNotificationCandidate(
          noteId: 42,
          reminder: Reminder(dateTime: due),
          title: 'QA',
          body: '',
        ),
        occurrenceIndex: 0,
        dueAt: due,
      ),
    ], deliveryGeneration: 'v2:first');
    expect(cancelled, [
      notifications.reminderNotificationId(42, 0, 'v2:first'),
    ]);
  });

  testWidgets('a retired action can dismiss only its own notification', (
    tester,
  ) async {
    registerPlugin();
    final notifications = LocalNotificationService.forTesting(
      initialize: () async {},
    );
    SharedPreferences.setMockInitialValues({
      'notification_delivery_generation': 'v2:new',
    });
    final oldId = notifications.reminderNotificationId(42, 0, 'old');
    final currentId = notifications.reminderNotificationId(42, 0, 'v2:new');
    expect(oldId, notifications.reminderNotificationId(42));
    final dismissed = <int>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pendingNotificationRequests') return [];
      expect(call.method, 'cancel');
      dismissed.add((call.arguments as Map)['id'] as int);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final stale = {
      'kind': 'reminder',
      'noteId': 42,
      'deliveryGeneration': 'old',
    };
    await notifications.dismissRetiredReminder(currentId, stale);
    await notifications.dismissRetiredReminder(oldId, stale);
    expect(dismissed, [oldId]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Windows sign-out initializes a cold plugin and tolerates unavailable initialization',
    (tester) async {
      final plugin = _WindowsNotifications();
      FlutterLocalNotificationsPlatform.instance = plugin;
      await LocalNotificationService.instance.cancelForSignOut();
      expect(plugin.calls, ['initialize', 'cancelAll']);
      plugin.failInitialization = true;
      SharedPreferences.setMockInitialValues({
        'pending_reminder_navigation_note_id': 101,
      });
      await ReminderSignOutCleanupService.cancelDeliveries();
      expect(plugin.calls, ['initialize', 'cancelAll', 'initialize']);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          'pending_reminder_navigation_note_id',
        ),
        false,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  group('containsPendingReminderRegistration', () {
    const payload =
        '{"kind":"reminder","noteId":42,"revision":3,"occurrence":"x"}';
    const request = PendingNotificationRequest(
      1234,
      'Reminder',
      'Body',
      payload,
    );

    test('accepts the exact notification ID and payload', () {
      expect(
        containsPendingReminderRegistration(
          requests: const [request],
          notificationId: 1234,
          payload: payload,
        ),
        isTrue,
      );
    });

    test('rejects a missing notification ID', () {
      expect(
        containsPendingReminderRegistration(
          requests: const [request],
          notificationId: 5678,
          payload: payload,
        ),
        isFalse,
      );
    });

    test('rejects a stale payload for the same ID', () {
      expect(
        containsPendingReminderRegistration(
          requests: const [request],
          notificationId: 1234,
          payload: '{"kind":"reminder","noteId":42,"revision":2}',
        ),
        isFalse,
      );
    });

    test('rejects an empty pending registry', () {
      expect(
        containsPendingReminderRegistration(
          requests: const [],
          notificationId: 1234,
          payload: payload,
        ),
        isFalse,
      );
    });
  });

  test('reminder cleanup ignores unrelated notification payloads', () {
    const reminderPayload =
        '{"kind":"reminder","noteId":42,"revision":3,"dueAt":"2026-07-20T10:00:00","token":"42:3:2026-07-20T10:00:00"}';
    final ids = reminderDeliveryIds(
      pending: const [
        PendingNotificationRequest(10, 'Reminder', 'Body', reminderPayload),
        PendingNotificationRequest(
          11,
          'Approve device',
          'Body',
          '{"kind":"device_approval"}',
        ),
      ],
      active: const [
        ActiveNotification(id: 10, payload: reminderPayload),
        ActiveNotification(id: 12, payload: '{"kind":"device_approval"}'),
      ],
    );

    expect(ids, {10});
  });
}
