import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_notification_plan.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const morning = TimeOfDay(hour: 9, minute: 15);

  ReminderNotificationCandidate candidate(int id, Reminder reminder) =>
      ReminderNotificationCandidate(
        noteId: id,
        reminder: reminder,
        title: 'Reminder $id',
        body: 'Body',
      );

  test('monthly plan clamps month end and recovers the anchor day', () {
    final reminder = Reminder(
      dateTime: DateTime(2026, 1, 31, 8),
      recurrenceAnchor: DateTime(2026, 1, 31, 8),
      repeat: Reminder.repeatMonthly,
    );

    final plan = ReminderNotificationPlanner.build(
      candidates: [candidate(1, reminder)],
      platform: ReminderNotificationPlatform.android,
      morningTime: morning,
      now: DateTime(2026, 1, 1),
    );

    expect(plan.notifications.take(3).map((item) => item.dueAt), [
      DateTime(2026, 1, 31, 8),
      DateTime(2026, 2, 28, 8),
      DateTime(2026, 3, 31, 8),
    ]);
    expect(
      plan.notifications.map((item) => item.occurrenceIndex).toSet().length,
      plan.notifications.length,
    );
  });

  test('yearly plan clamps leap day and recovers in a leap year', () {
    final reminder = Reminder(
      dateTime: DateTime(2024, 2, 29, 7),
      recurrenceAnchor: DateTime(2024, 2, 29, 7),
      repeat: Reminder.repeatYearly,
    );

    final nonLeap = ReminderNotificationPlanner.build(
      candidates: [candidate(1, reminder)],
      platform: ReminderNotificationPlatform.ios,
      morningTime: morning,
      now: DateTime(2024, 3, 1),
    );
    expect(nonLeap.notifications.map((item) => item.dueAt), [
      DateTime(2025, 2, 28, 7),
      DateTime(2026, 2, 28, 7),
    ]);

    final recovered = ReminderNotificationPlanner.build(
      candidates: [candidate(1, reminder)],
      platform: ReminderNotificationPlatform.ios,
      morningTime: morning,
      now: DateTime(2027, 3, 1),
    );
    expect(recovered.notifications.first.dueAt, DateTime(2028, 2, 29, 7));
  });

  test('daily and weekly stay native outside Windows', () {
    final plan = ReminderNotificationPlanner.build(
      candidates: [
        candidate(
          1,
          Reminder(
            dateTime: DateTime(2026, 7, 21, 10),
            repeat: Reminder.repeatDaily,
          ),
        ),
        candidate(
          2,
          Reminder(
            dateTime: DateTime(2026, 7, 22, 10),
            repeat: Reminder.repeatWeekly,
          ),
        ),
      ],
      platform: ReminderNotificationPlatform.android,
      morningTime: morning,
      now: DateTime(2026, 7, 20),
    );

    expect(plan.notifications, hasLength(2));
    expect(plan.notifications[0].nativeRepeat, ReminderNativeRepeat.daily);
    expect(plan.notifications[1].nativeRepeat, ReminderNativeRepeat.weekly);
  });

  test('Windows materializes repeats within its bounded horizon', () {
    final plan = ReminderNotificationPlanner.build(
      candidates: [
        candidate(
          1,
          Reminder(
            dateTime: DateTime(2026, 7, 21, 10),
            repeat: Reminder.repeatDaily,
          ),
        ),
      ],
      platform: ReminderNotificationPlatform.windows,
      morningTime: morning,
      now: DateTime(2026, 7, 20),
    );

    expect(plan.notifications, hasLength(32));
    expect(plan.notifications.every((item) => item.nativeRepeat == null), true);
  });

  test('all-day occurrences use Morning without changing date semantics', () {
    final plan = ReminderNotificationPlanner.build(
      candidates: [
        candidate(
          1,
          Reminder(
            dateTime: DateTime(2026, 1, 31, 22),
            recurrenceAnchor: DateTime(2026, 1, 31, 22),
            repeat: Reminder.repeatMonthly,
            isAllDay: true,
          ),
        ),
      ],
      platform: ReminderNotificationPlatform.android,
      morningTime: morning,
      now: DateTime(2026, 1, 1),
    );

    expect(plan.notifications[0].dueAt, DateTime(2026, 1, 31, 9, 15));
    expect(plan.notifications[1].dueAt, DateTime(2026, 2, 28, 9, 15));
    expect(plan.notifications[0].reminder.dateTime.hour, 0);
  });

  test('iOS capacity preserves nearest occurrence for sixty reminders', () {
    final candidates = List.generate(
      61,
      (index) => candidate(
        index + 1,
        Reminder(dateTime: DateTime(2026, 7, 21 + index, 10)),
      ),
    );

    final plan = ReminderNotificationPlanner.build(
      candidates: candidates,
      platform: ReminderNotificationPlatform.ios,
      morningTime: morning,
      now: DateTime(2026, 7, 20),
    );

    expect(plan.notifications, hasLength(60));
    expect(plan.capacityExceededNoteIds, {61});
  });

  test('materialized payloads have distinct occurrence tokens', () {
    final reminder = Reminder(
      dateTime: DateTime(2026, 1, 31, 8),
      repeat: Reminder.repeatMonthly,
      revision: 8,
    );
    final plan = ReminderNotificationPlanner.build(
      candidates: [candidate(9, reminder)],
      platform: ReminderNotificationPlatform.android,
      morningTime: morning,
      now: DateTime(2026, 1, 1),
    );

    final tokens = plan.notifications
        .map(
          (item) => reminderOccurrenceToken(
            item.noteId,
            item.reminder.revision,
            item.dueAt,
          ),
        )
        .toSet();
    expect(tokens, hasLength(plan.notifications.length));
  });
}
