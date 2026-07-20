import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class ReminderNotificationRegistrationException implements Exception {
  const ReminderNotificationRegistrationException(this.notificationId);

  final int notificationId;

  @override
  String toString() {
    return 'Notification $notificationId was not registered by the platform.';
  }
}

bool containsPendingReminderRegistration({
  required Iterable<PendingNotificationRequest> requests,
  required int notificationId,
  required String payload,
}) {
  return requests.any(
    (request) => request.id == notificationId && request.payload == payload,
  );
}

/// Returns only notification IDs whose payload identifies a note reminder.
/// Device approval and future notification features are deliberately ignored.
Set<int> reminderDeliveryIds({
  required Iterable<PendingNotificationRequest> pending,
  required Iterable<ActiveNotification> active,
}) {
  final ids = <int>{};
  for (final request in pending) {
    if (isReminderNotificationPayload(request.payload)) ids.add(request.id);
  }
  for (final notification in active) {
    final id = notification.id;
    if (id != null && isReminderNotificationPayload(notification.payload)) {
      ids.add(id);
    }
  }
  return ids;
}
