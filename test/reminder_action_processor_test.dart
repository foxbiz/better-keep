import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_action_processor.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database database;
  const noteId = 42;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await NoteSyncTrack.createTable(database);
    await ReminderActionReceiptService.createTable(database);
  });

  tearDown(() => database.close());

  Reminder reminder({String repeat = Reminder.repeatNever, int revision = 3}) {
    final dueAt = DateTime(2026, 7, 20, 10, 15);
    return Reminder(
      dateTime: dueAt,
      recurrenceAnchor: dueAt,
      repeat: repeat,
      type: ReminderType.notification,
      revision: revision,
    );
  }

  Map<String, dynamic> payloadFor(Reminder value) {
    return decodeReminderNotificationPayload(
      encodeReminderNotificationPayload(noteId, value, value.dateTime),
    )!;
  }

  Future<void> insertNote(Reminder value, {bool trashed = false}) {
    return database.insert(Note.model, {
      'id': noteId,
      'title': 'Action test',
      'reminder': jsonEncode(value.toJson()),
      'completed': 0,
      'trashed': trashed ? 1 : 0,
    });
  }

  test('one-time action completes note and queues sync atomically', () async {
    final value = reminder();
    await insertNote(value);

    final result = await ReminderActionProcessor.instance.markDone(
      payloadFor(value),
      database: database,
      now: value.dateTime,
    );

    expect(result.state, ReminderActionState.applied);
    expect(result.shouldRefreshUi, isTrue);
    expect(result.activeReminder, isNull);
    final note = (await database.query(Note.model)).single;
    expect(note['completed'], 1);

    final receipts = await ReminderActionReceiptService.pendingUiUpdates(
      database,
    );
    expect(receipts, hasLength(1));
    expect(receipts.single.noteId, noteId);
    expect(receipts.single.action, ReminderActionProcessor.markDoneAction);

    final sync = (await database.query(NoteSyncTrack.model)).single;
    expect(sync['local_id'], noteId);
    expect(sync['action'], 'upload');
    expect(sync['status'], 'pending');
  });

  test(
    'repeating action advances the anchored occurrence and revision',
    () async {
      final value = reminder(repeat: Reminder.repeatDaily);
      await insertNote(value);

      final result = await ReminderActionProcessor.instance.markDone(
        payloadFor(value),
        database: database,
        now: value.dateTime,
      );

      expect(result.state, ReminderActionState.applied);
      expect(result.activeReminder, isNotNull);
      expect(result.activeReminder!.dateTime, DateTime(2026, 7, 21, 10, 15));
      expect(result.activeReminder!.revision, value.revision + 1);
      final note = (await database.query(Note.model)).single;
      expect(note['completed'], 0);
      final stored = Reminder.fromJson(
        jsonDecode(note['reminder']! as String) as Map<String, Object?>,
      );
      expect(stored.dateTime, result.activeReminder!.dateTime);
      expect(stored.recurrenceAnchor, value.recurrenceAnchor);
    },
  );

  test('duplicate action is idempotent', () async {
    final value = reminder(repeat: Reminder.repeatDaily);
    await insertNote(value);
    final payload = payloadFor(value);

    final first = await ReminderActionProcessor.instance.markDone(
      payload,
      database: database,
      now: value.dateTime,
    );
    final duplicate = await ReminderActionProcessor.instance.markDone(
      payload,
      database: database,
      now: value.dateTime,
    );

    expect(first.state, ReminderActionState.applied);
    expect(duplicate.state, ReminderActionState.alreadyApplied);
    expect(duplicate.shouldRefreshUi, isTrue);
    expect(duplicate.activeReminder?.dateTime, first.activeReminder?.dateTime);
    expect(
      await database.query(ReminderActionReceiptService.table),
      hasLength(1),
    );
  });

  test('stale revision cannot update the note', () async {
    final stored = reminder(revision: 4);
    await insertNote(stored);
    final stale = reminder(revision: 3);

    final result = await ReminderActionProcessor.instance.markDone(
      payloadFor(stale),
      database: database,
      now: stale.dateTime,
    );

    expect(result.state, ReminderActionState.stale);
    expect(result.shouldRefreshUi, isFalse);
    expect((await database.query(Note.model)).single['completed'], 0);
    expect(await database.query(ReminderActionReceiptService.table), isEmpty);
  });

  test('missing and trashed notes are rejected safely', () async {
    final value = reminder();
    final missing = await ReminderActionProcessor.instance.markDone(
      payloadFor(value),
      database: database,
      now: value.dateTime,
    );
    expect(missing.state, ReminderActionState.missing);
    expect(missing.shouldRefreshUi, isFalse);

    await insertNote(value, trashed: true);
    final trashed = await ReminderActionProcessor.instance.markDone(
      payloadFor(value),
      database: database,
      now: value.dateTime,
    );
    expect(trashed.state, ReminderActionState.stale);
  });

  test('processing failure rolls back note and receipt', () async {
    final value = reminder();
    await insertNote(value);
    await database.execute('DROP TABLE ${NoteSyncTrack.model}');

    final result = await ReminderActionProcessor.instance.markDone(
      payloadFor(value),
      database: database,
      now: value.dateTime,
    );

    expect(result.state, ReminderActionState.failed);
    expect(result.shouldRefreshUi, isFalse);
    expect((await database.query(Note.model)).single['completed'], 0);
    expect(await database.query(ReminderActionReceiptService.table), isEmpty);
  });

  test(
    'overdue repeat advances to the first occurrence after action',
    () async {
      final value = reminder(repeat: Reminder.repeatDaily);
      await insertNote(value);

      final result = await ReminderActionProcessor.instance.markDone(
        payloadFor(value),
        database: database,
        now: DateTime(2026, 7, 25, 11),
      );

      expect(result.state, ReminderActionState.applied);
      expect(result.activeReminder!.dateTime, DateTime(2026, 7, 26, 10, 15));
      expect(result.activeReminder!.revision, value.revision + 1);
    },
  );
}
