import 'dart:convert';

import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_sync_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification reminders never populate the legacy alarm field', () {
    final reminder = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.notification,
    );
    final data = <String, dynamic>{'reminder': jsonEncode(reminder.toJson())};

    ReminderSyncCodec.encode(reminder, data);

    expect(data['reminder'], isNull);
    expect(data['reminder_v2'], isA<Map>());
    expect(data['reminder_state_v3'], {
      'version': 3,
      'source': 'notification',
      'generation': ':1:notification',
    });
  });

  test('v2 notification decodes into the local reminder column', () {
    final reminder = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.notification,
    );
    final data = <String, dynamic>{
      'reminder': null,
      'reminder_v2': {'version': 2, 'data': reminder.toJson()},
    };

    ReminderSyncCodec.decode(data);

    final decoded = Reminder.fromJson(
      jsonDecode(data['reminder'] as String) as Map<String, Object?>,
    );
    expect(decoded.type, ReminderType.notification);
  });

  test('explicit legacy alarm wins over stale v2 notification', () {
    final alarm = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.alarm,
    );
    final notification = alarm.copyWith(type: ReminderType.notification);
    final legacy = jsonEncode(alarm.toJson());
    final data = <String, dynamic>{
      'reminder': legacy,
      'reminder_v2': {'version': 2, 'data': notification.toJson()},
    };

    ReminderSyncCodec.decode(data);

    expect(data['reminder'], legacy);
  });

  test('alarm and removal write authoritative v3 state', () {
    final alarm = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.alarm,
      revision: 4,
    );
    final alarmData = <String, dynamic>{
      'reminder': jsonEncode(alarm.toJson()),
      'updated_at': '2026-07-20T10:00:00.000',
    };
    ReminderSyncCodec.encode(alarm, alarmData);
    expect(alarmData['reminder_v2'], isNull);
    expect((alarmData['reminder_state_v3'] as Map)['source'], 'alarm');

    final removedData = <String, dynamic>{
      'reminder': null,
      'updated_at': '2026-07-20T11:00:00.000',
    };
    ReminderSyncCodec.encode(null, removedData);
    expect(removedData['reminder_v2'], isNull);
    expect((removedData['reminder_state_v3'] as Map)['source'], 'none');
  });

  test('v3 none prevents stale v2 notification resurrection', () {
    final notification = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.notification,
    );
    final data = <String, dynamic>{
      'reminder': null,
      'reminder_v2': {'version': 2, 'data': notification.toJson()},
      'reminder_state_v3': {
        'version': 3,
        'source': 'none',
        'generation': 'legacy:remove',
      },
    };

    ReminderSyncCodec.decode(data);

    expect(data['reminder'], isNull);
  });

  test('v3 notification requires a valid v2 notification', () {
    final data = <String, dynamic>{
      'reminder': null,
      'reminder_v2': {'version': 2, 'data': 'broken'},
      'reminder_state_v3': {
        'version': 3,
        'source': 'notification',
        'generation': 'new-client',
      },
    };

    ReminderSyncCodec.decode(data);

    expect(data['reminder'], isNull);
  });

  test('unsupported reminder types fail closed during encoding', () {
    final unsupported = Reminder(
      dateTime: DateTime(2026, 7, 20, 10),
      type: ReminderType.unsupported,
    );
    final data = <String, dynamic>{
      'reminder': jsonEncode(unsupported.toJson()),
    };

    ReminderSyncCodec.encode(unsupported, data);

    expect(data['reminder'], isNull);
    expect(data['reminder_v2'], isNull);
    expect((data['reminder_state_v3'] as Map)['source'], 'none');
  });

  test('malformed v2 data fails closed', () {
    final data = <String, dynamic>{
      'reminder': null,
      'reminder_v2': {'version': 2, 'data': 'broken'},
    };

    ReminderSyncCodec.decode(data);

    expect(data['reminder'], isNull);
  });
}
