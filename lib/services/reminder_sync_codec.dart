import 'dart:convert';

import 'package:better_keep/models/reminder.dart';

/// Backward-compatible Firestore representation for reminders.
class ReminderSyncCodec {
  static const stateField = 'reminder_state_v3';

  static void encode(Reminder? reminder, Map<String, dynamic> noteData) {
    final source = switch (reminder?.type) {
      ReminderType.notification => 'notification',
      ReminderType.alarm => 'alarm',
      ReminderType.unsupported || null => 'none',
    };
    final updatedAt = noteData['updated_at']?.toString() ?? '';
    final revision = reminder?.revision ?? 0;
    noteData[stateField] = <String, Object?>{
      'version': 3,
      'source': source,
      'generation': '$updatedAt:$revision:$source',
    };
    if (reminder?.type == ReminderType.notification) {
      noteData['reminder'] = null;
      noteData['reminder_v2'] = <String, Object?>{
        'version': 2,
        'data': reminder!.toJson(),
      };
      return;
    }
    if (reminder?.type == ReminderType.unsupported) {
      noteData['reminder'] = null;
    }
    noteData['reminder_v2'] = null;
  }

  static void decode(Map<String, dynamic> noteData) {
    // A non-null legacy value means an older client explicitly selected or
    // changed an alarm. It wins over any stale notification v2 field.
    if (noteData['reminder'] != null) return;

    if (noteData.containsKey(stateField)) {
      final state = noteData[stateField];
      if (state is! Map || state['version'] != 3) {
        noteData['reminder'] = null;
        return;
      }
      switch (state['source']) {
        case 'notification':
          _decodeNotification(noteData);
        case 'alarm':
        case 'none':
        default:
          noteData['reminder'] = null;
      }
      return;
    }

    _decodeNotification(noteData);
  }

  static void _decodeNotification(Map<String, dynamic> noteData) {
    final envelope = noteData['reminder_v2'];
    if (envelope is! Map || envelope['version'] != 2) {
      noteData['reminder'] = null;
      return;
    }
    final data = envelope['data'];
    if (data is! Map) {
      noteData['reminder'] = null;
      return;
    }
    final reminder = Reminder.fromJson(Map<String, Object?>.from(data));
    if (reminder.type != ReminderType.notification) {
      noteData['reminder'] = null;
      return;
    }
    noteData['reminder'] = jsonEncode(reminder.toJson());
  }
}
