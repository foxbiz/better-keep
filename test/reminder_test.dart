import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Reminder serialization', () {
    test('new reminders default to notification', () {
      final reminder = Reminder(dateTime: DateTime(2026, 7, 20, 10));

      expect(reminder.type, ReminderType.notification);
      expect(
        Reminder.fromJson(reminder.toJson()).type,
        ReminderType.notification,
      );
    });

    test('legacy timed reminders remain alarms', () {
      final reminder = Reminder.fromJson({
        'dateTime': '2026-07-20T10:00:00.000',
        'repeat': Reminder.repeatNever,
        'isAllDay': false,
      });

      expect(reminder.type, ReminderType.alarm);
      expect(reminder.revision, 0);
    });

    test('legacy all-day reminders preserve quiet notification behavior', () {
      final reminder = Reminder.fromJson({
        'dateTime': '2026-07-20T00:00:00.000',
        'repeat': Reminder.repeatNever,
        'isAllDay': true,
      });

      expect(reminder.type, ReminderType.notification);
    });

    test('unknown future types fail closed', () {
      final reminder = Reminder.fromJson({
        'dateTime': '2026-07-20T10:00:00.000',
        'repeat': Reminder.repeatNever,
        'isAllDay': false,
        'type': 'future-delivery',
      });

      expect(reminder.type, ReminderType.unsupported);
      expect(reminder.isSupportedType, isFalse);
    });

    test('unknown future all-day types also fail closed', () {
      final reminder = Reminder.fromJson({
        'dateTime': '2026-07-20T10:00:00.000',
        'repeat': Reminder.repeatNever,
        'isAllDay': true,
        'type': 'future-delivery',
      });

      expect(reminder.type, ReminderType.unsupported);
      expect(reminder.dateTime, DateTime(2026, 7, 20));
    });

    test('custom date and time are combined without retaining stale time', () {
      final reminder = Reminder.build(
        '2026-07-20T00:00:00.000',
        '11:59 PM',
        Reminder.repeatNever,
      );

      expect(reminder.dateTime, DateTime(2026, 7, 20, 23, 59));
      expect(reminder.recurrenceAnchor, reminder.dateTime);
      expect(reminder.type, ReminderType.notification);
    });

    test('new all-day reminders discard hidden time components', () {
      final reminder = Reminder.build(
        '2026-07-20T14:37:42.000',
        Reminder.allDay,
        Reminder.repeatMonthly,
      );

      expect(reminder.dateTime, DateTime(2026, 7, 20));
      expect(reminder.recurrenceAnchor, DateTime(2026, 7, 20));
      expect(reminder.isAllDay, isTrue);
      expect(reminder.type, ReminderType.notification);
    });

    test('legacy all-day reminders normalize their date and anchor', () {
      final reminder = Reminder.fromJson({
        'dateTime': '2026-07-20T14:37:42.000',
        'recurrenceAnchor': '2026-01-31T22:15:00.000',
        'repeat': Reminder.repeatMonthly,
        'isAllDay': true,
        'type': 'alarm',
        'revision': 7,
      });

      expect(reminder.dateTime, DateTime(2026, 7, 20));
      expect(reminder.recurrenceAnchor, DateTime(2026, 1, 31));
      expect(reminder.repeat, Reminder.repeatMonthly);
      expect(reminder.type, ReminderType.notification);
      expect(reminder.revision, 7);
    });

    test(
      'copying to all day also enforces date-only notification semantics',
      () {
        final reminder = Reminder(
          dateTime: DateTime(2026, 7, 20, 18, 45),
          type: ReminderType.alarm,
        ).copyWith(isAllDay: true);

        expect(reminder.dateTime, DateTime(2026, 7, 20));
        expect(reminder.recurrenceAnchor, DateTime(2026, 7, 20));
        expect(reminder.type, ReminderType.notification);
      },
    );
  });

  group('Reminder overdue boundary', () {
    test('timed reminders become overdue at their selected time', () {
      final reminder = Reminder(dateTime: DateTime(2026, 7, 20, 14, 30));

      expect(reminder.overdueAt, DateTime(2026, 7, 20, 14, 30));
      expect(reminder.isOverdueAt(DateTime(2026, 7, 20, 14, 29)), isFalse);
      expect(reminder.isOverdueAt(DateTime(2026, 7, 20, 14, 30)), isTrue);
    });

    test('all-day reminders remain active through the selected day', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 7, 20, 16, 45),
        isAllDay: true,
      );

      expect(reminder.overdueAt, DateTime(2026, 7, 21));
      expect(reminder.isOverdueAt(DateTime(2026, 7, 20, 23, 59, 59)), isFalse);
      expect(reminder.isOverdueAt(DateTime(2026, 7, 21)), isTrue);
    });

    test('all-day overdue boundary uses calendar arithmetic at month end', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 3, 31, 23),
        isAllDay: true,
      );

      expect(reminder.overdueAt, DateTime(2026, 4, 1));
    });

    test('Morning remains delivery-only for all-day reminders', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 7, 20),
        isAllDay: true,
      );

      expect(
        effectiveReminderDateTime(
          reminder,
          morningTime: const TimeOfDay(hour: 9, minute: 15),
        ),
        DateTime(2026, 7, 20, 9, 15),
      );
      expect(reminder.overdueAt, DateTime(2026, 7, 21));
    });
  });

  group('Reminder recurrence', () {
    test('daily recurrence keeps an upcoming occurrence on the same day', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 7, 1, 9, 30),
        repeat: Reminder.repeatDaily,
      );

      final next = reminder.getNextOccurrence(after: DateTime(2026, 7, 20, 9));

      expect(next!.dateTime, DateTime(2026, 7, 20, 9, 30));
    });

    test('weekly recurrence keeps an upcoming occurrence on the same day', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 7, 6, 9, 30),
        repeat: Reminder.repeatWeekly,
      );

      final next = reminder.getNextOccurrence(after: DateTime(2026, 7, 20, 9));

      expect(next!.dateTime, DateTime(2026, 7, 20, 9, 30));
    });

    test('weekly recurrence retains its original weekday', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 7, 6, 9, 30), // Monday
        repeat: Reminder.repeatWeekly,
      );

      final next = reminder.getNextOccurrence(after: DateTime(2026, 7, 20, 10));

      expect(next!.dateTime, DateTime(2026, 7, 27, 9, 30));
      expect(next.dateTime.weekday, DateTime.monday);
    });

    test('month-end clamping recovers the anchor day', () {
      final reminder = Reminder(
        dateTime: DateTime(2026, 1, 31, 8),
        recurrenceAnchor: DateTime(2026, 1, 31, 8),
        repeat: Reminder.repeatMonthly,
      );

      final february = reminder.getNextOccurrence(
        after: DateTime(2026, 1, 31, 8),
      )!;
      final march = february.getNextOccurrence(
        after: DateTime(2026, 2, 28, 8),
      )!;

      expect(february.dateTime, DateTime(2026, 2, 28, 8));
      expect(march.dateTime, DateTime(2026, 3, 31, 8));
    });

    test('leap-day yearly recurrence recovers in a leap year', () {
      final reminder = Reminder(
        dateTime: DateTime(2024, 2, 29, 7),
        repeat: Reminder.repeatYearly,
      );

      final nonLeap = reminder.getNextOccurrence(after: DateTime(2024, 3, 1))!;
      final leap = nonLeap.getNextOccurrence(after: DateTime(2027, 3, 1))!;

      expect(nonLeap.dateTime, DateTime(2025, 2, 28, 7));
      expect(leap.dateTime, DateTime(2028, 2, 29, 7));
    });

    test('all-day recurrence stays date-only for every frequency', () {
      final cases = <(Reminder, DateTime, DateTime)>[
        (
          Reminder(
            dateTime: DateTime(2026, 7, 20, 12),
            repeat: Reminder.repeatDaily,
            isAllDay: true,
          ),
          DateTime(2026, 7, 20, 12),
          DateTime(2026, 7, 21),
        ),
        (
          Reminder(
            dateTime: DateTime(2026, 7, 20, 12),
            repeat: Reminder.repeatWeekly,
            isAllDay: true,
          ),
          DateTime(2026, 7, 20, 12),
          DateTime(2026, 7, 27),
        ),
        (
          Reminder(
            dateTime: DateTime(2026, 1, 31, 12),
            repeat: Reminder.repeatMonthly,
            isAllDay: true,
          ),
          DateTime(2026, 1, 31, 12),
          DateTime(2026, 2, 28),
        ),
        (
          Reminder(
            dateTime: DateTime(2024, 2, 29, 12),
            repeat: Reminder.repeatYearly,
            isAllDay: true,
          ),
          DateTime(2024, 2, 29, 12),
          DateTime(2025, 2, 28),
        ),
      ];

      for (final (reminder, after, expected) in cases) {
        final next = reminder.getNextOccurrence(after: after)!;
        expect(next.dateTime, expected);
        expect(next.recurrenceAnchor.hour, 0);
        expect(next.isAllDay, isTrue);
        expect(next.type, ReminderType.notification);
      }
    });
  });
}
