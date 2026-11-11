import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    DeviceApprovalNotificationService().dispose();
  });

  test('new approval is posted after native cancellation fails', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final posted = <int>[];
    var cancellationAttempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return true;
        case 'getNotificationAppLaunchDetails':
          return null;
        case 'cancelAll':
          cancellationAttempts++;
          throw PlatformException(code: 'unavailable');
        case 'show':
          posted.add((call.arguments as Map)['id'] as int);
          return null;
        default:
          fail('Unexpected notification call ${call.method}');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final notifications = LocalNotificationService.instance;
    await notifications.init(
      onResponse: (_) {},
      onBackgroundResponse: reminderNotificationBackgroundResponse,
    );
    await notifications.retireDeliveries();
    expect(
      await notifications.showDeviceApproval(
        id: 77,
        title: 'New device',
        body: 'Approve',
        payload: 'qa',
      ),
      isTrue,
    );
    expect(cancellationAttempts, 1);
    expect(posted, [77]);
  });

  test(
    'unsupported platforms skip initialization and plugin operations',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(
        LocalNotificationService.instance.supportsDeviceApprovalNotifications,
        false,
      );
      await DeviceApprovalNotificationService().init();
      expect(
        await LocalNotificationService.instance.showDeviceApproval(
          id: 1,
          title: 'Approval',
          body: 'Body',
          payload: 'device',
        ),
        false,
      );
      expect(
        await LocalNotificationService.instance.cancelDeviceApproval(1),
        false,
      );
    },
  );
}
