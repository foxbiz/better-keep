import 'package:better_keep/services/reminder_notification_registration.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
