import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  var triggers = 0;
  final body = jsonEncode([
    {
      'insert': 'A formatted task',
      'attributes': {'bold': true},
    },
    {
      'insert': '\n',
      'attributes': {'list': 'unchecked'},
    },
  ]);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(db);
    await NoteSyncTrack.createTable(db);
    await SyncReplicaStore.createTables(db);
    await SyncMutationJournal.install(db);
    AppState.db = db;
    triggers = 0;
    Note.syncTriggerOverride = () => triggers++;
    Note.unlockPostAuthenticationOverride = (_, _) async {};
  });
  tearDown(() async {
    Note.syncTriggerOverride = null;
    Note.unlockPostAuthenticationOverride = null;
    LocalDataEncryption.resetScopedPreferenceCache();
    await db.close();
  });
  Future<SyncLocalVersion> version(Note note) async =>
      (await SyncMutationJournal.current(
        db,
        SyncEntityKind.note,
        note.syncId!,
      ))!;

  test('unchanged saves retain timestamp and both sync queues', () async {
    final note = Note(title: 'Task', content: body);
    await note.save();
    final original = await version(note);
    final timestamp = note.updatedAt;
    final rows = await db.query('note');
    final tracks = await db.query('sync_track');
    await note.save();
    await note.saveEditorSnapshot(
      title: 'Task',
      content: body,
      plainText: 'Task',
    );
    expect((await version(note)).revisionId, original.revisionId);
    expect(note.updatedAt, timestamp);
    expect(await db.query('note'), rows);
    expect(await db.query('sync_track'), tracks);
    expect(triggers, 1);

    note.pinned = true;
    await note.save();
    final edited = await version(note);
    expect(edited.compareTo(original), greaterThan(0));
    // A real revert remains an edit, even though it matches an older upload.
    note.pinned = false;
    await note.save();
    expect((await version(note)).compareTo(edited), greaterThan(0));
    expect(triggers, 3);
  });

  test(
    'unchanged media metadata stays clean and replacement media queues an edit',
    () async {
      final image = NoteImage(
        src: '/test/image.png',
        size: 4,
        index: 0,
        aspectRatio: '1:1',
        lastModified: 'first',
      );
      final note = Note(
        title: 'Media',
        content: body,
        attachments: [NoteAttachment.image(image)],
      );
      await note.save();
      final original = await version(note);
      await note.save();
      expect((await version(note)).revisionId, original.revisionId);
      image.src = '/test/replacement.png';
      image.lastModified = 'second';
      await note.save();
      expect((await version(note)).compareTo(original), greaterThan(0));
      expect(triggers, 2);
    },
  );

  test('local encryption is persisted but repeated randomized encryption is not an edit', () async {
    // This test is also run with a synthetic LOCAL_DATA_KEY to exercise AEAD.
    final note = Note(title: 'Encrypted locally', content: body);
    LocalDataEncryption.primeScopedPreferenceCacheForTesting(
      notesEnabled: false,
    );
    await note.save();
    LocalDataEncryption.primeScopedPreferenceCacheForTesting(
      notesEnabled: true,
    );
    await note.save();
    final original = await version(note);
    final stored = (await db.query('note')).single['content'];
    expect(
      LocalDataEncryption.isEncrypted(stored as String),
      LocalDataEncryption.isAvailable,
    );
    await note.save();
    expect((await version(note)).revisionId, original.revisionId);
    expect((await db.query('note')).single['content'], stored);
  });

  test(
    'random PIN encryption does not turn an unchanged save into an edit',
    () async {
      final note = Note(
        title: 'Private',
        locked: true,
        content: await encryptAsync(body, '2468'),
      );
      await note.save();
      final original = await version(note);
      final stored = (await db.query('note')).single['content'];
      await note.unlock('2468');
      await note.save();
      expect((await version(note)).revisionId, original.revisionId);
      expect((await db.query('note')).single['content'], stored);
      expect(triggers, 1);
      note.content = body.replaceFirst('formatted', 'updated');
      await note.save();
      expect((await version(note)).compareTo(original), greaterThan(0));
      expect((await db.query('note')).single['content'], isNot(note.content));
    },
  );

  test(
    'comparison uses the current database snapshot after incoming sync',
    () async {
      final note = Note(title: 'Before', content: body);
      await note.save();
      await db.update(
        'note',
        {'title': 'Incoming'},
        where: 'id = ?',
        whereArgs: [note.id],
      );
      final incoming = await version(note);
      // Saving the old in-memory value is an explicit later local edit.
      await note.save();
      expect((await db.query('note')).single['title'], 'Before');
      expect((await version(note)).compareTo(incoming), greaterThan(0));
    },
  );
}
