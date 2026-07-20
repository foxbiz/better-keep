import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';

/// Immutable delivery identity captured when a reminder mutation is queued.
class ReminderScheduleIntent {
  const ReminderScheduleIntent({
    required this.noteId,
    required this.type,
    required this.dateTime,
    required this.repeat,
    required this.isAllDay,
    required this.recurrenceAnchor,
    required this.revision,
  });

  factory ReminderScheduleIntent.fromNote(Note note) {
    final reminder = note.reminder!;
    return ReminderScheduleIntent(
      noteId: note.id!,
      type: reminder.type,
      dateTime: reminder.dateTime,
      repeat: reminder.repeat,
      isAllDay: reminder.isAllDay,
      recurrenceAnchor: reminder.recurrenceAnchor,
      revision: reminder.revision,
    );
  }

  final int noteId;
  final ReminderType type;
  final DateTime dateTime;
  final String repeat;
  final bool isAllDay;
  final DateTime recurrenceAnchor;
  final int revision;

  bool matches(Note? note) {
    final reminder = note?.reminder;
    return note?.id == noteId &&
        note != null &&
        !note.completed &&
        !note.trashed &&
        reminder != null &&
        reminder.type == type &&
        reminder.dateTime == dateTime &&
        reminder.repeat == repeat &&
        reminder.isAllDay == isAllDay &&
        reminder.recurrenceAnchor == recurrenceAnchor &&
        reminder.revision == revision;
  }
}
