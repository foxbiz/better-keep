import 'dart:async';
import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await NoteSyncTrack.createTable(database);
    AppState.db = database;
    Note.syncTriggerOverride = () {};
  });

  tearDown(() async {
    await database.close();
    Note.syncTriggerOverride = null;
  });

  test('returns separate persistence and delivery outcomes', () async {
    final note = Note(title: 'Persisted reminder', content: '[]');
    final reminder = Reminder(dateTime: DateTime(2026, 7, 20, 10));
    var scheduleCalls = 0;
    final syncTriggered = Completer<void>();
    Note.syncTriggerOverride = () {
      if (!syncTriggered.isCompleted) syncTriggered.complete();
    };

    final result = await note.setReminder(
      reminder,
      schedule: (scheduledNote) async {
        scheduleCalls++;
        expect(scheduledNote.id, isNotNull);
        expect(scheduledNote.reminder?.revision, 1);
        return const ReminderScheduleResult(
          ReminderDeliveryState.permissionDenied,
        );
      },
    );

    expect(result.persisted, isTrue);
    expect(result.rowId, note.id);
    expect(result.savedReminder, note.reminder);
    expect(result.delivery?.state, ReminderDeliveryState.permissionDenied);
    expect(scheduleCalls, 1);
    await syncTriggered.future;
    expect(await database.query(Note.model), hasLength(1));
  });

  test(
    'restores state and never schedules after persistence failure',
    () async {
      final previous = Reminder(dateTime: DateTime(2026, 7, 20, 9));
      final note = Note(reminder: previous, completed: true);
      var scheduleCalls = 0;

      final result = await note.setReminder(
        Reminder(dateTime: DateTime(2026, 7, 21, 10)),
        schedule: (_) async {
          scheduleCalls++;
          return const ReminderScheduleResult(ReminderDeliveryState.scheduled);
        },
      );

      expect(result.persisted, isFalse);
      expect(result.delivery, isNull);
      expect(note.reminder, same(previous));
      expect(note.completed, isTrue);
      expect(scheduleCalls, 0);
      expect(await database.query(Note.model), isEmpty);
    },
  );

  test('remote note persistence is independent from reminder delivery', () async {
    final reminder = Reminder(dateTime: DateTime(2026, 8, 14, 9));
    final note = Note(id: 42);

    await note.updateFromJson({
      'sync_id': 'remote-note-42',
      'pinned': 0,
      'locked': 0,
      'trashed': 0,
      'archived': 0,
      'read_only': 0,
      'completed': 0,
      'title': 'Remote reminder',
      'content': '[]',
      'plain_text': '',
      'updated_at': DateTime(2026, 8, 12).toIso8601String(),
      'reminder': jsonEncode(reminder.toJson()),
      'attachments': <dynamic>[],
    });

    expect(note.id, 42);
    expect(note.reminder?.dateTime, reminder.dateTime);
    expect(await Note.findById(42), isNotNull);
  });
}
