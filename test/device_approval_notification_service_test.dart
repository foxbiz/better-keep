import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    DeviceApprovalNotificationService().dispose();
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
