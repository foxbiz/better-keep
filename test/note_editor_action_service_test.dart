import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/pages/note_editor/note_editor_action_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
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
    Note.syncTriggerOverride = null;
    await database.close();
  });

  test(
    'duplicates the current note snapshot and deep-copies attachments',
    () async {
      final source = Note(
        id: 12,
        title: 'Tasks',
        content: jsonEncode([
          {'insert': 'Tasks'},
          {
            'insert': '\n',
            'attributes': {'header': 1},
          },
          {'insert': 'Task\n'},
        ]),
        plainText: 'Tasks\nTask',
        labels: 'work,urgent',
        color: const Color(0xfffff8e1),
        pinned: true,
        archived: true,
        readOnly: true,
        attachments: [
          NoteAttachment.audio(NoteRecording(src: '/recordings/task.m4a')),
        ],
      );

      final duplicate = await NoteEditorActionService.duplicate(source);
      await pumpEventQueue(times: 20);

      expect(duplicate.id, isNotNull);
      expect(duplicate.id, isNot(source.id));
      expect(duplicate.title, source.title);
      expect(duplicate.content, source.content);
      expect(duplicate.plainText, 'Task\n');
      expect(duplicate.labels, source.labels);
      expect(duplicate.color, source.color);
      expect(duplicate.pinned, isTrue);
      expect(duplicate.archived, isTrue);
      expect(duplicate.readOnly, isTrue);
      expect(duplicate.attachments, hasLength(1));
      expect(
        duplicate.attachments.single,
        isNot(same(source.attachments.single)),
      );
      expect(
        duplicate.attachments.single.recording?.src,
        '/recordings/task.m4a',
      );
      expect(await database.query(Note.model), hasLength(1));
      expect(await database.query(NoteSyncTrack.model), hasLength(1));
    },
  );
}
