import 'dart:convert';

import 'package:better_keep/models/reminder.dart';
import 'package:flutter/material.dart';

DateTime effectiveReminderDateTime(
  Reminder reminder, {
  required TimeOfDay morningTime,
}) {
  if (!reminder.isAllDay) return reminder.dateTime;
  return DateTime(
    reminder.dateTime.year,
    reminder.dateTime.month,
    reminder.dateTime.day,
    morningTime.hour,
    morningTime.minute,
  );
}

String reminderOccurrenceToken(int noteId, int revision, DateTime dueAt) {
  return '$noteId:$revision:${dueAt.toIso8601String()}';
}

bool isReminderOccurrence(
  Reminder reminder,
  DateTime dueAt, {
  required TimeOfDay morningTime,
}) {
  if (effectiveReminderDateTime(reminder, morningTime: morningTime) == dueAt) {
    return true;
  }
  if (!reminder.isRepeating) return false;

  final anchor = reminder.recurrenceAnchor;
  final expectedTime = reminder.isAllDay
      ? morningTime
      : TimeOfDay(hour: anchor.hour, minute: anchor.minute);
  if (dueAt.hour != expectedTime.hour || dueAt.minute != expectedTime.minute) {
    return false;
  }

  final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
  final dueDay = DateTime(dueAt.year, dueAt.month, dueAt.day);
  if (dueDay.isBefore(anchorDay)) return false;
  return switch (reminder.repeat) {
    Reminder.repeatDaily => true,
    Reminder.repeatWeekly =>
      dueDay.difference(anchorDay).inDays % DateTime.daysPerWeek == 0,
    Reminder.repeatMonthly =>
      dueAt.day ==
          anchor.day.clamp(1, DateTime(dueAt.year, dueAt.month + 1, 0).day),
    Reminder.repeatYearly =>
      dueAt.month == anchor.month &&
          dueAt.day ==
              anchor.day.clamp(
                1,
                DateTime(dueAt.year, anchor.month + 1, 0).day,
              ),
    _ => false,
  };
}

String encodeReminderNotificationPayload(
  int noteId,
  Reminder reminder,
  DateTime dueAt,
) {
  return jsonEncode({
    'kind': 'reminder',
    'scheduleVersion': 2,
    'noteId': noteId,
    'revision': reminder.revision,
    'dueAt': dueAt.toIso8601String(),
    'token': reminderOccurrenceToken(noteId, reminder.revision, dueAt),
  });
}

Map<String, dynamic>? decodeReminderNotificationPayload(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

bool isReminderNotificationPayload(String? raw) {
  return decodeReminderNotificationPayload(raw)?['kind'] == 'reminder';
}
