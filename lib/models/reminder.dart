import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';

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
    final now = DateTime.now().add(Duration(days: 1));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String get nextWeekValue {
    final now = DateTime.now().add(Duration(days: 7));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String get nextMonthValue {
    final now = DateTime.now().add(Duration(days: 30));
    return DateTime(now.year, now.month, now.day).toIso8601String();
  }

  static String formatTimeOfDay(BuildContext context, TimeOfDay time) {
    return time.format(context);
  }

  static String getMorningValue(BuildContext context) {
    return formatTimeOfDay(context, AppState.morningTime);
  }

  static String getAfternoonValue(BuildContext context) {
    return formatTimeOfDay(context, AppState.afternoonTime);
  }

  static String getEveningValue(BuildContext context) {
    return formatTimeOfDay(context, AppState.eveningTime);
  }

  static List<String> dateOptions = [
    today,
    tomorrow,
    nextWeek,
    nextMonth,
    custom,
  ];

  static List<String> timeOptions = [
    morning,
    afternoon,
    evening,
    allDay,
    custom,
  ];

  static List<String> repeatOptions = [
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

  factory Reminder.build(String dateStr, String timeStr, String repeat) {
    DateTime date = DateTime.parse(dateStr);

    if (timeStr != "All Day") {
      final timeParts = timeStr.split(' ');
      final hmParts = timeParts[0].split(':');
      int hour = int.parse(hmParts[0]);
      final int minute = int.parse(hmParts[1]);

      // Handle 12-hour format (with AM/PM)
      if (timeParts.length > 1) {
        final period = timeParts[1];
        if (period == 'PM' && hour != 12) {
          hour += 12;
        } else if (period == 'AM' && hour == 12) {
          hour = 0;
        }
      }
      // For 24-hour format, hour is already correct

      date = DateTime(date.year, date.month, date.day, hour, minute);
    }

    return Reminder(
      dateTime: date,
      repeat: repeat,
      isAllDay: timeStr == "All Day",
    );
  }

  factory Reminder.fromJson(Map<String, Object?> json) {
    return Reminder(
      dateTime: DateTime.parse(json["dateTime"] as String),
      repeat: json["repeat"] as String,
      isAllDay: json["isAllDay"] as bool,
    );
  }

  Reminder({
    required this.dateTime,
    this.repeat = repeatNever,
    this.isAllDay = false,
  });

  /// Returns true if this reminder repeats
  bool get isRepeating {
    return repeat != repeatNever && repeat != repeatOnce;
  }

  /// Calculate the next occurrence of this reminder based on repeat type
  Reminder? getNextOccurrence() {
    if (!isRepeating) {
      return null;
    }

    DateTime nextDateTime;
    final now = DateTime.now();

    switch (repeat) {
      case repeatDaily:
        // Next day, same time
        nextDateTime = DateTime(
          now.year,
          now.month,
          now.day + 1,
          dateTime.hour,
          dateTime.minute,
        );
        break;
      case repeatWeekly:
        // Next week, same day and time
        nextDateTime = DateTime(
          now.year,
          now.month,
          now.day + 7,
          dateTime.hour,
          dateTime.minute,
        );
        break;
      case repeatMonthly:
        // Next month, same day and time
        final nextMonth = now.month == 12 ? 1 : now.month + 1;
        final nextYear = now.month == 12 ? now.year + 1 : now.year;
        // Handle edge case where day doesn't exist in next month
        // Use day 0 of the following month to get last day of target month
        final monthAfter = nextMonth == 12 ? 1 : nextMonth + 1;
        final yearOfMonthAfter = nextMonth == 12 ? nextYear + 1 : nextYear;
        final daysInNextMonth = DateTime(yearOfMonthAfter, monthAfter, 0).day;
        final day = dateTime.day > daysInNextMonth
            ? daysInNextMonth
            : dateTime.day;
        nextDateTime = DateTime(
          nextYear,
          nextMonth,
          day,
          dateTime.hour,
          dateTime.minute,
        );
        break;
      case repeatYearly:
        // Next year, same month, day and time
        // Handle Feb 29 on leap years - clamp to last day of month
        final targetYear = now.year + 1;
        final daysInTargetMonth = DateTime(
          targetYear,
          dateTime.month + 1,
          0,
        ).day;
        final day = dateTime.day > daysInTargetMonth
            ? daysInTargetMonth
            : dateTime.day;
        nextDateTime = DateTime(
          targetYear,
          dateTime.month,
          day,
          dateTime.hour,
          dateTime.minute,
        );
        break;
      default:
        return null;
    }

    return Reminder(dateTime: nextDateTime, repeat: repeat, isAllDay: isAllDay);
  }

  dynamic toJson() {
    return {
      "dateTime": dateTime.toIso8601String(),
      "repeat": repeat,
      "isAllDay": isAllDay,
    };
  }
}
