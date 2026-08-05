import 'package:better_keep/state.dart';
import 'package:better_keep/utils/calendar_date.dart';
import 'package:flutter/material.dart';

enum ReminderType { notification, alarm, unsupported }

enum ReminderDeliveryState {
  scheduled,
  unsupported,
  permissionDenied,
  pastDue,
  superseded,
  capacityExceeded,
  failed,
}

enum ReminderDeliveryReason {
  signedOut,
  unsupportedType,
  notificationUnsupportedPlatform,
  alarmUnsupportedPlatform,
  permissionRequired,
  timeZoneUnavailable,
  alarmRequiresSpecificTime,
  capacityExceeded,
}

class ReminderScheduleResult {
  const ReminderScheduleResult(this.state, {this.reason, this.error});

  final ReminderDeliveryState state;
  final ReminderDeliveryReason? reason;
  final Object? error;

  bool get isScheduled => state == ReminderDeliveryState.scheduled;
}

/// The complete outcome of saving and scheduling a reminder edit.
///
/// Persistence and device delivery are separate: a reminder can be saved and
/// synced even when this device cannot schedule it locally.
class ReminderUpdateResult {
  const ReminderUpdateResult({
    required this.rowId,
    this.savedReminder,
    this.delivery,
  });

  final int rowId;
  final Reminder? savedReminder;
  final ReminderScheduleResult? delivery;

  bool get persisted => rowId >= 0 && savedReminder != null;
}

class Reminder {
  static const String repeatNever = "Never";
  static const String repeatOnce = "Once";
  static const String repeatDaily = "Daily";
  static const String repeatWeekly = "Weekly";
  static const String repeatMonthly = "Monthly";
  static const String repeatYearly = "Yearly";

  static const String today = "Today";
  static const String tomorrow = "Tomorrow";
  static const String nextWeek = "Next Week";
  static const String nextMonth = "Next Month";

  static const String morning = "Morning";
  static const String afternoon = "Afternoon";
  static const String evening = "Evening";
  static const String allDay = "All Day";

  static const String custom = "Custom";

  static String get todayValue {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String get tomorrowValue {
    final now = DateTime.now().add(const Duration(days: 1));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String get nextWeekValue {
    final now = DateTime.now().add(const Duration(days: 7));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String get nextMonthValue {
    final now = DateTime.now().add(const Duration(days: 30));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String formatTimeOfDay(BuildContext context, TimeOfDay time) =>
      time.format(context);

  static String getMorningValue(BuildContext context) =>
      formatTimeOfDay(context, AppState.morningTime);

  static String getAfternoonValue(BuildContext context) =>
      formatTimeOfDay(context, AppState.afternoonTime);

  static String getEveningValue(BuildContext context) =>
      formatTimeOfDay(context, AppState.eveningTime);

  static const List<String> dateOptions = [
    today,
    tomorrow,
    nextWeek,
    nextMonth,
    custom,
  ];

  static const List<String> timeOptions = [
    morning,
    afternoon,
    evening,
    allDay,
    custom,
  ];

  static const List<String> repeatOptions = [
    repeatNever,
    repeatOnce,
    repeatDaily,
    repeatWeekly,
    repeatMonthly,
    repeatYearly,
  ];

  static String getValueOf(BuildContext context, String option) {
    return switch (option) {
      today => todayValue,
      tomorrow => tomorrowValue,
      nextWeek => nextWeekValue,
      nextMonth => nextMonthValue,
      morning => getMorningValue(context),
      afternoon => getAfternoonValue(context),
      evening => getEveningValue(context),
      _ => '',
    };
  }

  final DateTime dateTime;
  final String repeat;
  final bool isAllDay;
  final ReminderType type;
  final DateTime recurrenceAnchor;
  final int revision;

  factory Reminder.build(
    String dateStr,
    String timeStr,
    String repeat, {
    ReminderType type = ReminderType.notification,
    int revision = 1,
  }) {
    DateTime date = DateTime.parse(dateStr);

    if (timeStr != allDay) {
      final timeParts = timeStr.split(' ');
      final hmParts = timeParts[0].split(':');
      int hour = int.parse(hmParts[0]);
      final minute = int.parse(hmParts[1]);

      if (timeParts.length > 1) {
        final period = timeParts[1].toUpperCase();
        if (period == 'PM' && hour != 12) {
          hour += 12;
        } else if (period == 'AM' && hour == 12) {
          hour = 0;
        }
      }
      date = DateTime(date.year, date.month, date.day, hour, minute);
    }

    return Reminder(
      dateTime: date,
      recurrenceAnchor: date,
      repeat: repeat,
      isAllDay: timeStr == allDay,
      type: type,
      revision: revision,
    );
  }

  factory Reminder.fromJson(Map<String, Object?> json) {
    final dateTime = DateTime.parse(json['dateTime'] as String);
    final isAllDay = json['isAllDay'] as bool? ?? false;
    final rawType = json['type'] as String?;
    final type = switch (rawType) {
      'notification' => ReminderType.notification,
      'alarm' => ReminderType.alarm,
      null => isAllDay ? ReminderType.notification : ReminderType.alarm,
      _ => ReminderType.unsupported,
    };

    return Reminder(
      dateTime: dateTime,
      recurrenceAnchor:
          DateTime.tryParse(json['recurrenceAnchor'] as String? ?? '') ??
          dateTime,
      repeat: json['repeat'] as String? ?? repeatNever,
      isAllDay: isAllDay,
      type: type,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }

  Reminder({
    required DateTime dateTime,
    DateTime? recurrenceAnchor,
    this.repeat = repeatNever,
    this.isAllDay = false,
    ReminderType type = ReminderType.notification,
    this.revision = 1,
  }) : dateTime = isAllDay ? _dateOnly(dateTime) : dateTime,
       type = isAllDay && type == ReminderType.alarm
           ? ReminderType.notification
           : type,
       recurrenceAnchor = isAllDay
           ? _dateOnly(recurrenceAnchor ?? dateTime)
           : recurrenceAnchor ?? dateTime;

  bool get isRepeating => repeat != repeatNever && repeat != repeatOnce;

  bool get isSupportedType => type != ReminderType.unsupported;

  /// The point after which this reminder is overdue.
  ///
  /// All-day reminders remain active for their entire calendar day. Their
  /// delivery time (for example, the configured Morning time) is deliberately
  /// separate from this date-only boundary.
  DateTime get overdueAt => isAllDay
      ? DateTime(dateTime.year, dateTime.month, dateTime.day + 1)
      : dateTime;

  bool isOverdueAt(DateTime time) => !overdueAt.isAfter(time);

  Reminder copyWith({
    DateTime? dateTime,
    String? repeat,
    bool? isAllDay,
    ReminderType? type,
    DateTime? recurrenceAnchor,
    int? revision,
  }) {
    return Reminder(
      dateTime: dateTime ?? this.dateTime,
      repeat: repeat ?? this.repeat,
      isAllDay: isAllDay ?? this.isAllDay,
      type: type ?? this.type,
      recurrenceAnchor: recurrenceAnchor ?? this.recurrenceAnchor,
      revision: revision ?? this.revision,
    );
  }

  /// Returns the first occurrence strictly after [after]. Calendar arithmetic
  /// is used instead of durations so wall-clock reminders retain their time
  /// across daylight-saving transitions.
  Reminder? getNextOccurrence({DateTime? after}) {
    if (!isRepeating) return null;

    final threshold = after ?? DateTime.now();
    late DateTime candidate;

    switch (repeat) {
      case repeatDaily:
        candidate = _nextDailyOrWeekly(threshold, 1);
      case repeatWeekly:
        candidate = _nextDailyOrWeekly(threshold, 7);
      case repeatMonthly:
        candidate = _nextMonthly(threshold);
      case repeatYearly:
        candidate = _nextYearly(threshold);
      default:
        return null;
    }

    return copyWith(dateTime: candidate);
  }

  DateTime _nextDailyOrWeekly(DateTime after, int intervalDays) {
    var candidate = dateTime;
    if (candidate.isAfter(after)) return candidate;

    final elapsedDays = calendarDayDelta(candidate, after);
    final intervals = elapsedDays ~/ intervalDays;
    candidate = DateTime(
      candidate.year,
      candidate.month,
      candidate.day + (intervals * intervalDays),
      recurrenceAnchor.hour,
      recurrenceAnchor.minute,
      recurrenceAnchor.second,
    );
    if (!candidate.isAfter(after)) {
      candidate = DateTime(
        candidate.year,
        candidate.month,
        candidate.day + intervalDays,
        recurrenceAnchor.hour,
        recurrenceAnchor.minute,
        recurrenceAnchor.second,
      );
    }
    return candidate;
  }

  DateTime _nextMonthly(DateTime after) {
    var monthIndex = dateTime.year * 12 + dateTime.month - 1;
    final afterIndex = after.year * 12 + after.month - 1;
    if (monthIndex < afterIndex) monthIndex = afterIndex;

    var candidate = _dateInMonth(monthIndex, recurrenceAnchor.day);
    if (!candidate.isAfter(after)) {
      candidate = _dateInMonth(monthIndex + 1, recurrenceAnchor.day);
    }
    return candidate;
  }

  DateTime _dateInMonth(int monthIndex, int anchorDay) {
    final year = monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(
      year,
      month,
      anchorDay.clamp(1, lastDay),
      recurrenceAnchor.hour,
      recurrenceAnchor.minute,
      recurrenceAnchor.second,
    );
  }

  DateTime _nextYearly(DateTime after) {
    var year = dateTime.year < after.year ? after.year : dateTime.year;
    var candidate = _dateInYear(year);
    if (!candidate.isAfter(after)) candidate = _dateInYear(year + 1);
    return candidate;
  }

  DateTime _dateInYear(int year) {
    final lastDay = DateTime(year, recurrenceAnchor.month + 1, 0).day;
    return DateTime(
      year,
      recurrenceAnchor.month,
      recurrenceAnchor.day.clamp(1, lastDay),
      recurrenceAnchor.hour,
      recurrenceAnchor.minute,
      recurrenceAnchor.second,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'dateTime': dateTime.toIso8601String(),
      'repeat': repeat,
      'isAllDay': isAllDay,
      'type': type.name,
      'recurrenceAnchor': recurrenceAnchor.toIso8601String(),
      'revision': revision,
    };
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
