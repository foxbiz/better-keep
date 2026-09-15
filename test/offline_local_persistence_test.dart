import 'dart:io';
import 'dart:convert';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late Database database;
  late String databasePath;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'better-keep-offline-test-',
    );
    databasePath = '${directory.path}/notes.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationCacheDirectory') {
              throw MissingPluginException();
            }
            return directory.path;
          },
        );
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    database = await databaseFactoryFfi.openDatabase(databasePath);
    AppState.db = database;
    await Note.createTable(database);
    await FileSyncTrack.createTable(database);
    await Label.createTable(database);
    await NoteSyncTrack.createTable(database);
    await LabelSyncTrack.createTable(database);
    Note.syncTriggerOverride = () {};
  });
  tearDown(() async {
    Note.syncTriggerOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> reopen() async {
    await database.close();
    database = await databaseFactoryFfi.openDatabase(databasePath);
    AppState.db = database;
  }

  test(
    'offline note edits, attachments and pending work survive immediate reopen',
    () async {
      final image = File('${directory.path}/attachment.png');
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
      );
      await image.writeAsBytes(bytes);
      final note = Note(
        id: 101,
        title: 'Offline note',
        content: '[{"insert":"before\\n"}]',
        plainText: 'before',
        attachments: [
          NoteAttachment.image(
            NoteImage(
              src: image.path,
              size: bytes.length,
              index: 0,
              aspectRatio: '1:1',
              lastModified: '',
            ),
          ),
        ],
      );
      expect(await note.save(), 101);
      await FileSyncTrack(
        noteId: 101,
        localPath: image.path,
        remotePath: 'gs://test.invalid/attachment.png',
        contentHash: FileSyncTrack.computeHash(bytes),
      ).save();
      final stableId = note.syncId;
      note.content =
          '[{"insert":"task"},{"insert":"\\n","attributes":{"list":"checked"}}]';
      note.plainText = 'task';
      note.labels = 'Offline';
      expect(await note.save(), 101);
      // No wait for timers or background events before the simulated restart.
      await reopen();
      final restored = await Note.findById(101);
      expect(restored?.content, note.content);
      expect(restored?.labels, 'Offline');
      expect(restored?.syncId, stableId);
      expect(await image.readAsBytes(), bytes);
      final downloaded = await FileSyncTrack.getByLocalPath(image.path);
      expect(downloaded?.contentHash, FileSyncTrack.computeHash(bytes));
      expect(downloaded?.remotePath, isNotNull);
      final pending = await NoteSyncTrack.getByLocalId(101);
      expect(pending?.status, SyncStatus.pending);
      expect(pending?.action, SyncAction.upload);
    },
  );

  test(
    'PIN protection and later edits remain pending across restart',
    () async {
      final note = Note(
        id: 401,
        title: 'Protected',
        content: '[{"insert":"private\\n"}]',
        plainText: 'private',
      );
      await note.save();
      Note.lockCommittedNotifierOverride = (_, _) {};
      Note.unlockPostAuthenticationOverride = (_, _) async {};
      try {
        await note.lock('1234');
        await reopen();
        final protected = (await Note.findById(401))!;
        expect(protected.locked, isTrue);
        expect(protected.unlocked, isFalse);
        expect(
          (await NoteSyncTrack.getByLocalId(401))?.status,
          SyncStatus.pending,
        );
        await protected.unlock('1234');
        expect(protected.content, note.content);
        final uploading = (await NoteSyncTrack.getByLocalId(401))!;
        protected.title = 'New offline title';
        await protected.save();
        await uploading.markSyncedIfUnchanged(DateTime.now());
        await reopen();
        expect(
          (await NoteSyncTrack.getByLocalId(401))?.status,
          SyncStatus.pending,
        );
      } finally {
        Note.lockCommittedNotifierOverride = null;
        Note.unlockPostAuthenticationOverride = null;
      }
    },
  );

  test('deleting a note persists the deletion before a restart', () async {
    final note = Note(
      id: 402,
      title: 'Delete offline',
      content: '[{"insert":"text\\n"}]',
      plainText: 'text',
    );
    await note.save();
    await note.delete();
    await reopen();
    expect(await Note.findById(402), isNull);
    expect((await NoteSyncTrack.getByLocalId(402))?.action, SyncAction.delete);
  });

  test('labels and deletion markers persist without a cloud session', () async {
    final label = Label(name: 'Before');
    await label.save();
    label.name = 'Offline label';
    await label.save();
    await reopen();
    expect((await Label.get()).single.name, 'Offline label');
    expect(
      (await LabelSyncTrack.getByLocalId(label.id!))?.status,
      LabelSyncStatus.pending,
    );
    await label.delete();
    await reopen();
    expect(await Label.get(), isEmpty);
    expect(
      (await LabelSyncTrack.getByLocalId(label.id!))?.action,
      LabelSyncAction.delete,
    );
  });

  test(
    'note and queue roll back together if pending work cannot be stored',
    () async {
      await database.execute('DROP TABLE sync_track');
      final note = Note(
        id: 303,
        title: 'Must not half-save',
        content: '[{"insert":"text\\n"}]',
        plainText: 'text',
      );
      expect(await note.save(), -1);
      expect(await database.query(Note.model), isEmpty);
    },
  );
}
