import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_action_processor.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  setUpAll(() {
    // This dedicated suite must be launched through tool/test_reminder_dst.sh.
    // Failing here is intentional: running in UTC would provide false coverage.
    expect(
      DateTime(2026, 1, 1).timeZoneOffset,
      const Duration(hours: -5),
    );
    expect(
      DateTime(2026, 7, 1).timeZoneOffset,
      const Duration(hours: -4),
    );
  });

  group('America/New_York recurrence', () {
    test('weekly occurrence validation crosses spring and fall DST', () {
      final spring = Reminder(
        dateTime: DateTime(2026, 3, 1, 9),
        recurrenceAnchor: DateTime(2026, 3, 1, 9),
        repeat: Reminder.repeatWeekly,
      );
      final fall = Reminder(
        dateTime: DateTime(2026, 10, 25, 9),
        recurrenceAnchor: DateTime(2026, 10, 25, 9),
        repeat: Reminder.repeatWeekly,
      );

      expect(
        isReminderOccurrence(
          spring,
          DateTime(2026, 3, 15, 9),
          morningTime: const TimeOfDay(hour: 9, minute: 0),
        ),
        isTrue,
      );
      expect(
        isReminderOccurrence(
          fall,
          DateTime(2026, 11, 8, 9),
          morningTime: const TimeOfDay(hour: 9, minute: 0),
        ),
        isTrue,
      );
    });

    test('daily recurrence keeps the next wall-clock time across DST', () {
      final spring = Reminder(
        dateTime: DateTime(2026, 3, 7, 9),
        repeat: Reminder.repeatDaily,
      );
      final fall = Reminder(
        dateTime: DateTime(2026, 10, 31, 9),
        repeat: Reminder.repeatDaily,
      );

      expect(
        spring.getNextOccurrence(after: DateTime(2026, 3, 9, 8))!.dateTime,
        DateTime(2026, 3, 9, 9),
      );
      expect(
        fall.getNextOccurrence(after: DateTime(2026, 11, 2, 8))!.dateTime,
        DateTime(2026, 11, 2, 9),
      );
    });

    test('weekly recurrence does not skip the fall-back occurrence', () {
      final spring = Reminder(
        dateTime: DateTime(2026, 3, 2, 9),
        repeat: Reminder.repeatWeekly,
      );
      final fall = Reminder(
        dateTime: DateTime(2026, 10, 26, 9),
        repeat: Reminder.repeatWeekly,
      );

      expect(
        spring.getNextOccurrence(after: DateTime(2026, 3, 9, 8))!.dateTime,
        DateTime(2026, 3, 9, 9),
      );
      expect(
        fall.getNextOccurrence(after: DateTime(2026, 11, 2, 8))!.dateTime,
        DateTime(2026, 11, 2, 9),
      );
      expect(
        fall.getNextOccurrence(after: DateTime(2026, 11, 2, 10))!.dateTime,
        DateTime(2026, 11, 9, 9),
      );
    });

    test('all-day daily and weekly reminders retain calendar dates', () {
      final daily = Reminder(
        dateTime: DateTime(2026, 3, 7, 14),
        repeat: Reminder.repeatDaily,
        isAllDay: true,
      );
      final weekly = Reminder(
        dateTime: DateTime(2026, 10, 26, 14),
        repeat: Reminder.repeatWeekly,
        isAllDay: true,
      );

      expect(
        daily.getNextOccurrence(after: DateTime(2026, 3, 8, 12))!.dateTime,
        DateTime(2026, 3, 9),
      );
      expect(
        weekly.getNextOccurrence(after: DateTime(2026, 11, 2, 12))!.dateTime,
        DateTime(2026, 11, 9),
      );
    });
  });

  test('Mark as Done accepts a weekly occurrence after spring DST', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    await Note.createTable(database);
    await NoteSyncTrack.createTable(database);
    await ReminderActionReceiptService.createTable(database);

    const noteId = 42;
    final reminder = Reminder(
      dateTime: DateTime(2026, 3, 1, 9),
      recurrenceAnchor: DateTime(2026, 3, 1, 9),
      repeat: Reminder.repeatWeekly,
      type: ReminderType.notification,
      revision: 3,
    );
    final dueAt = DateTime(2026, 3, 15, 9);
    await database.insert(Note.model, {
      'id': noteId,
      'title': 'DST action test',
      'reminder': jsonEncode(reminder.toJson()),
      'completed': 0,
      'trashed': 0,
    });
    final payload = decodeReminderNotificationPayload(
      encodeReminderNotificationPayload(noteId, reminder, dueAt),
    )!;

    final result = await ReminderActionProcessor.instance.markDone(
      payload,
      database: database,
      now: dueAt,
    );

    expect(result.state, ReminderActionState.applied);
    expect(result.activeReminder?.dateTime, DateTime(2026, 3, 22, 9));
    expect(result.activeReminder?.revision, 4);
    expect(
      await database.query(ReminderActionReceiptService.table),
      hasLength(1),
    );
    expect(await database.query(NoteSyncTrack.model), hasLength(1));
  });
}
