import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter/material.dart';

enum ReminderNotificationPlatform { android, ios, macOS, windows }

enum ReminderNativeRepeat { daily, weekly }

class ReminderNotificationCandidate {
  const ReminderNotificationCandidate({
    required this.noteId,
    required this.reminder,
    required this.title,
    required this.body,
  });

  final int noteId;
  final Reminder reminder;
  final String title;
  final String body;
}

class PlannedReminderNotification {
  const PlannedReminderNotification({
    required this.candidate,
    required this.occurrenceIndex,
    required this.dueAt,
    this.nativeRepeat,
  });

  final ReminderNotificationCandidate candidate;
  final int occurrenceIndex;
  final DateTime dueAt;
  final ReminderNativeRepeat? nativeRepeat;

  int get noteId => candidate.noteId;
  Reminder get reminder => candidate.reminder;
  String get title => candidate.title;
  String get body => candidate.body;
}

class ReminderNotificationPlan {
  const ReminderNotificationPlan({
    required this.notifications,
    required this.capacityExceededNoteIds,
    required this.pastDueNoteIds,
  });

  final List<PlannedReminderNotification> notifications;
  final Set<int> capacityExceededNoteIds;
  final Set<int> pastDueNoteIds;

  bool schedules(int noteId) =>
      notifications.any((notification) => notification.noteId == noteId);
}

/// Builds a bounded desired notification plan without touching platform APIs.
class ReminderNotificationPlanner {
  const ReminderNotificationPlanner._();

  static const int maxOccurrenceSlots = 32;
  static const int _iosCapacity = 60;
  static const int _androidCapacity = 480;
  static const int _calendarRepeatLimit = 12;
  static const Duration _calendarHorizon = Duration(days: 366);
  static const Duration _windowsHorizon = Duration(days: 90);

  static ReminderNotificationPlan build({
    required Iterable<ReminderNotificationCandidate> candidates,
    required ReminderNotificationPlatform platform,
    required TimeOfDay morningTime,
    required DateTime now,
  }) {
    final first = <PlannedReminderNotification>[];
    final extrasByNote = <int, List<PlannedReminderNotification>>{};
    final pastDue = <int>{};

    for (final candidate in candidates) {
      final active = _firstActiveOccurrence(
        candidate.reminder,
        morningTime: morningTime,
        now: now,
      );
      if (active == null) {
        pastDue.add(candidate.noteId);
        continue;
      }

      final shouldMaterialize =
          (platform == ReminderNotificationPlatform.windows &&
              active.isRepeating) ||
          active.repeat == Reminder.repeatMonthly ||
          active.repeat == Reminder.repeatYearly;
      if (!shouldMaterialize) {
        final repeat = switch (active.repeat) {
          Reminder.repeatDaily => ReminderNativeRepeat.daily,
          Reminder.repeatWeekly => ReminderNativeRepeat.weekly,
          _ => null,
        };
        first.add(
          PlannedReminderNotification(
            candidate: _withReminder(candidate, active),
            occurrenceIndex: 0,
            dueAt: effectiveReminderDateTime(active, morningTime: morningTime),
            nativeRepeat: repeat,
          ),
        );
        continue;
      }

      final occurrences = _materializedOccurrences(
        _withReminder(candidate, active),
        platform: platform,
        morningTime: morningTime,
      );
      if (occurrences.isEmpty) {
        pastDue.add(candidate.noteId);
        continue;
      }
      first.add(occurrences.first);
      if (occurrences.length > 1) {
        extrasByNote[candidate.noteId] = occurrences.sublist(1);
      }
    }

    first.sort(_byDueAtThenNoteId);
    final capacity = switch (platform) {
      ReminderNotificationPlatform.ios => _iosCapacity,
      ReminderNotificationPlatform.android => _androidCapacity,
      ReminderNotificationPlatform.macOS ||
      ReminderNotificationPlatform.windows => 0x7fffffff,
    };
    final selected = first.take(capacity).toList();
    final exceeded = first.skip(capacity).map((item) => item.noteId).toSet();
    var remaining = capacity - selected.length;

    // Every eligible reminder receives its nearest occurrence before a second
    // slot is assigned to any reminder. Subsequent rounds retain that fairness.
    var round = 0;
    while (remaining > 0) {
      final roundItems = <PlannedReminderNotification>[];
      for (final items in extrasByNote.values) {
        if (round < items.length) roundItems.add(items[round]);
      }
      if (roundItems.isEmpty) break;
      roundItems.sort(_byDueAtThenNoteId);
      final accepted = roundItems.take(remaining).toList();
      selected.addAll(accepted);
      remaining -= accepted.length;
      round++;
    }

    selected.sort((a, b) {
      final note = a.noteId.compareTo(b.noteId);
      return note != 0 ? note : a.occurrenceIndex.compareTo(b.occurrenceIndex);
    });
    return ReminderNotificationPlan(
      notifications: List.unmodifiable(selected),
      capacityExceededNoteIds: Set.unmodifiable(exceeded),
      pastDueNoteIds: Set.unmodifiable(pastDue),
    );
  }

  static Reminder? _firstActiveOccurrence(
    Reminder reminder, {
    required TimeOfDay morningTime,
    required DateTime now,
  }) {
    if (effectiveReminderDateTime(
      reminder,
      morningTime: morningTime,
    ).isAfter(now)) {
      return reminder;
    }
    return reminder.getNextOccurrence(after: now);
  }

  static List<PlannedReminderNotification> _materializedOccurrences(
    ReminderNotificationCandidate candidate, {
    required ReminderNotificationPlatform platform,
    required TimeOfDay morningTime,
  }) {
    final isWindows = platform == ReminderNotificationPlatform.windows;
    final horizon = effectiveReminderDateTime(
      candidate.reminder,
      morningTime: morningTime,
    ).add(isWindows ? _windowsHorizon : _calendarHorizon);
    final limit = isWindows ? maxOccurrenceSlots : _calendarRepeatLimit;
    final result = <PlannedReminderNotification>[];
    var occurrence = candidate.reminder;

    while (result.length < limit) {
      final dueAt = effectiveReminderDateTime(
        occurrence,
        morningTime: morningTime,
      );
      if (result.length >= 2 && dueAt.isAfter(horizon)) break;
      result.add(
        PlannedReminderNotification(
          candidate: candidate,
          occurrenceIndex: result.length,
          dueAt: dueAt,
        ),
      );
      final next = occurrence.getNextOccurrence(after: occurrence.dateTime);
      if (next == null) break;
      occurrence = next;
    }
    return result;
  }

  static ReminderNotificationCandidate _withReminder(
    ReminderNotificationCandidate candidate,
    Reminder reminder,
  ) => ReminderNotificationCandidate(
    noteId: candidate.noteId,
    reminder: reminder,
    title: candidate.title,
    body: candidate.body,
  );

  static int _byDueAtThenNoteId(
    PlannedReminderNotification a,
    PlannedReminderNotification b,
  ) {
    final due = a.dueAt.compareTo(b.dueAt);
    return due != 0 ? due : a.noteId.compareTo(b.noteId);
  }
}
