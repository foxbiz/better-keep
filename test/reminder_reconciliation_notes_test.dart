import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_schedule_intent.dart';
import 'package:better_keep/services/external_sync/sync_version.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database database;
  final reminder = Reminder(
    dateTime: DateTime(2030, 1, 1, 10),
    type: ReminderType.notification,
    revision: 7,
  );
  final content = jsonEncode([
    {'insert': 'Reminder preview\n'},
  ]);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await Note.createTable(database);
    for (final note in [
      Note(id: 1, title: 'Due', content: content, reminder: reminder),
      Note(id: 2, title: 'No reminder', content: content),
      Note(id: 3, content: content, reminder: reminder, completed: true),
      Note(id: 4, content: content, reminder: reminder, archived: true),
      Note(id: 5, content: content, reminder: reminder, trashed: true),
      Note(id: 6, content: content, reminder: reminder, locked: true),
      Note(
        id: 7,
        content: content,
        reminder: reminder.copyWith(type: ReminderType.alarm),
      ),
    ]) {
      await database.insert(Note.model, note.toJson());
    }
  });
  tearDown(() => database.close());

  test(
    'sweep retains cancellation metadata without reading note content',
    () async {
      final notes = await Note.getForReminderReconciliation();
      expect(notes.map((note) => note.id), unorderedEquals([1, 2, 3, 6, 7]));
      expect(
        notes.every((note) => note.content == '' && note.attachments.isEmpty),
        isTrue,
      );
      expect(notes.singleWhere((note) => note.id == 2).reminder, isNull);
      expect(notes.singleWhere((note) => note.id == 3).completed, isTrue);
      final intent = ReminderScheduleIntent.fromNote(
        notes.singleWhere((note) => note.id == 1),
      );
      expect(intent.matches(await Note.findById(1)), isTrue);
    },
  );

  test(
    'metadata-only notes reject persistence before changing the stored note',
    () async {
      final before = await database.query(Note.model);
      final notes = await Note.getForReminderReconciliation();
      final note = notes.singleWhere((note) => note.id == 1);
      note.title = 'Accidental partial update';
      await expectLater(note.save(false), throwsStateError);
      await expectLater(note.delete(trackSync: false), throwsStateError);
      await expectLater(
        note.writeAttachmentForSession('', Uint8List(1)),
        throwsStateError,
      );
      await expectLater(
        note.generateMissingAttachmentThumbnails(),
        throwsStateError,
      );
      await expectLater(
        note.applyRemoteIfUnchanged(
          database: database,
          expectedRow: before.singleWhere((row) => row['id'] == 1),
          expectedSyncRow: null,
          incoming: const {'sync_id': 'synthetic-remote'},
          incomingVersion: SyncVersion(
            kind: SyncEntityKind.note,
            entityId: 'synthetic-remote',
            revisionId: 'synthetic-revision',
            modifiedAtMicros: 1,
            deleted: false,
          ),
          commitAttachments: (_) async {
            fail('Metadata-only notes must not commit remote attachments');
          },
        ),
        throwsStateError,
      );
      var mutationCalled = false;
      await expectLater(
        note.persistSketchMutation(() async => mutationCalled = true),
        throwsStateError,
      );
      expect(mutationCalled, isFalse);
      expect(await database.query(Note.model), before);
    },
  );

  test(
    'notification planning keeps content and privacy flags only for candidates',
    () async {
      final notes = await Note.getForReminderReconciliation(
        includeNotificationContent: true,
      );
      expect(notes.map((note) => note.id), unorderedEquals([1, 6]));
      final unlocked = notes.singleWhere((note) => note.id == 1);
      expect(unlocked.title, 'Due');
      expect(unlocked.body, contains('Reminder preview'));
      expect(notes.singleWhere((note) => note.id == 6).locked, isTrue);
    },
  );
}
