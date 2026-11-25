import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_navigation_service.dart';

class ReminderSignOutCleanupService {
  ReminderSignOutCleanupService._();

  static Future<void> cancelDeliveries() async {
    await LocalNotificationService.instance.retireDeliveries();
    await ReminderNavigationService.instance.clearForSignOut();
  }
}
