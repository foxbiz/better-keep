import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    await AppState.init(prefs: preferences);
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await FileSyncTrack.createTable(database);
    await NoteSyncTrack.createTable(database);
    AppState.db = database;
    Note.lockFileOperationsOverride = null;
    Note.lockCommittedNotifierOverride = (_, _) {};
    Note.lockBeforeCommitOverride = null;
    Note.protectedAttachmentRepairSyncTriggerOverride = () async {};
  });

  tearDown(() async {
    Note.lockFileOperationsOverride = null;
    Note.lockCommittedNotifierOverride = null;
    Note.lockBeforeCommitOverride = null;
    Note.protectedAttachmentRepairSyncTriggerOverride = null;
    await database.close();
  });

  test('failed strokes staging preserves newer in-memory drawing', () async {
    final originalBytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'strokes': <String>[]})),
    );
    final files = <String, Uint8List>{'/docs/original.json': originalBytes};
    final fake = _FakeLockFiles(files: files, failWriteNumber: 1);
    Note.lockFileOperationsOverride = fake.operations;

    final stroke = SketchStroke(
      points: '1,2,0.5;3,4,0.5;',
      color: Colors.black,
      size: 5,
    );
    final sketch = SketchData(
      strokesFilePath: '/docs/original.json',
      strokes: [stroke],
    );
    final note = Note(
      id: 1,
      title: 'Drawing',
      content: _content('current'),
      plainText: 'current',
      updatedAt: DateTime.utc(2026, 7, 19),
      createdAt: DateTime.utc(2026, 7, 18),
      attachments: [NoteAttachment.sketch(sketch)],
    );
    await _insertNote(database, note);
    var updateEvents = 0;
    void listener(NoteEvent event) => updateEvents++;
    Note.on('updated', listener);

    await expectLater(note.lock('1234'), throwsA(isA<NoteLockException>()));

    Note.off('updated', listener);
    expect(note.locked, isFalse);
    expect(note.password, isNull);
    expect(sketch.strokes, [stroke]);
    expect(sketch.strokesFilePath, '/docs/original.json');
    expect(files['/docs/original.json'], originalBytes);
    expect(files.keys, ['/docs/original.json']);
    expect(updateEvents, 0);
    final row = (await database.query('note')).single;
    expect(row['locked'], 0);
    expect(row['attachments'], contains('/docs/original.json'));
    expect(await NoteLockJournal(preferences).load(), isEmpty);
  });

  test(
    'failure after one staged attachment removes only staged files',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
        '/docs/audio.m4a': Uint8List.fromList([4, 5, 6]),
      };
      final originalImage = Uint8List.fromList(files['/docs/image.jpg']!);
      final originalAudio = Uint8List.fromList(files['/docs/audio.m4a']!);
      final fake = _FakeLockFiles(files: files, failWriteNumber: 2);
      final service = NoteLockTransactionService(fake.operations);
      final attachments = [
        NoteAttachment.image(_image('/docs/image.jpg')),
        NoteAttachment.audio(NoteRecording(src: '/docs/audio.m4a')),
      ];

      await expectLater(
        service.prepare(
          noteId: 1,
          attachments: attachments,
          password: '1234',
          journal: NoteLockJournal(preferences),
        ),
        throwsA(isA<StateError>()),
      );

      expect(attachments[0].image!.src, '/docs/image.jpg');
      expect(attachments[1].recording!.src, '/docs/audio.m4a');
      expect(files['/docs/image.jpg'], originalImage);
      expect(files['/docs/audio.m4a'], originalAudio);
      expect(files.keys.toSet(), {'/docs/image.jpg', '/docs/audio.m4a'});
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'successful lock commits verified files and file tracking together',
    () async {
      final files = <String, Uint8List>{
        '/docs/strokes.json': Uint8List.fromList(
          utf8.encode(jsonEncode({'strokes': <String>[]})),
        ),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final stroke = SketchStroke(
        points: '10,20,0.7;',
        color: Colors.red,
        size: 3,
      );
      final sketch = SketchData(
        strokesFilePath: '/docs/strokes.json',
        strokes: [stroke],
        backgroundColor: Colors.blue,
        pagePattern: PagePattern.grid,
        aspectRatio: 2,
      );
      final note = Note(
        id: 2,
        title: 'Drawing',
        content: _content('secret'),
        plainText: 'secret',
        updatedAt: DateTime.utc(2026, 7, 19),
        createdAt: DateTime.utc(2026, 7, 18),
        attachments: [NoteAttachment.sketch(sketch)],
      );
      await _insertNote(database, note);
      await database.insert('file_sync_track', {
        'note_id': 2,
        'local_path': '/docs/strokes.json',
        'remote_path': 'https://example.com/old',
        'content_hash': 'old-hash',
      });

      await note.lock('1234');

      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      expect(note.password, '1234');
      expect(note.content, _content('secret'));
      expect(sketch.strokes, isEmpty);
      expect(sketch.hasHydratedStrokeSource, isFalse);
      expect(sketch.strokesFilePath, isNot('/docs/strokes.json'));
      expect(files.containsKey('/docs/strokes.json'), isFalse);
      final protected = files[sketch.strokesFilePath]!;
      expect(isBytesPasswordEncrypted(protected), isTrue);
      final decoded =
          jsonDecode(
                utf8.decode(await decryptBytesWithPassword(protected, '1234')),
              )
              as Map<String, dynamic>;
      expect(decoded['strokes'], [stroke.toString()]);
      expect(decoded['bgColor'], Colors.blue.toARGB32());
      expect(decoded['pagePattern'], PagePattern.grid.name);
      expect(decoded['aspectRatio'], 2.0);

      final row = (await database.query('note', where: 'id = 2')).single;
      expect(row['locked'], 1);
      expect(row['attachments'], contains(sketch.strokesFilePath!));
      final tracked = (await database.query('file_sync_track')).single;
      expect(tracked['local_path'], sketch.strokesFilePath);
      expect(tracked['content_hash'], isNull);
      expect(await NoteLockJournal(preferences).load(), isEmpty);

      expect(
        await SketchStrokesFileService.hydrate(
          sketch,
          pathExists: fake.operations.exists,
          readBytes: fake.operations.read,
          passwordProtectedDecoder: note.decryptAttachmentForSession,
        ),
        SketchStrokesLoadResult.loaded,
      );
      expect(sketch.strokes.single.toString(), stroke.toString());

      await note.clearPassword();
      expect(note.unlocked, isFalse);
      expect(sketch.strokes, isEmpty);
      expect(sketch.hasHydratedStrokeSource, isFalse);
      expect(isBytesPasswordEncrypted(files[sketch.strokesFilePath]!), isTrue);
    },
  );

  test(
    'authenticated unlock replaces an exposed canonical file atomically',
    () async {
      final originalBytes = Uint8List.fromList([1, 2, 3, 4]);
      final files = <String, Uint8List>{
        '/docs/exposed.jpg': Uint8List.fromList(originalBytes),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final protectedContent = await encrypt(_content('body'), '2468');
      final image = _image('/docs/exposed.jpg');
      final note = Note(
        id: 31,
        title: 'Previously exposed',
        content: protectedContent,
        locked: true,
        updatedAt: DateTime.utc(2026, 7, 19),
        attachments: [NoteAttachment.image(image)],
      );
      await _insertNote(database, note);

      await note.unlock('2468');

      expect(note.unlocked, isTrue);
      expect(image.src, isNot('/docs/exposed.jpg'));
      expect(files.containsKey('/docs/exposed.jpg'), isFalse);
      final protectedBytes = files[image.src]!;
      expect(isBytesPasswordEncrypted(protectedBytes), isTrue);
      expect(
        await note.decryptAttachmentForSession(protectedBytes),
        originalBytes,
      );
      final row = (await database.query('note', where: 'id = 31')).single;
      expect(row['locked'], 1);
      expect(row['attachments'], contains(image.src));
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'authenticated unlock moves an inline source behind the PIN boundary',
    () async {
      final originalBytes = Uint8List.fromList([9, 8, 7, 6]);
      final inlineSource =
          'data:image/jpeg;base64,${base64Encode(originalBytes)}';
      final files = <String, Uint8List>{};
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final image = _image(inlineSource);
      final note = Note(
        id: 33,
        title: 'Legacy web attachment',
        content: await encrypt(_content('body'), '2468'),
        locked: true,
        updatedAt: DateTime.utc(2026, 7, 19),
        attachments: [NoteAttachment.image(image)],
      );
      await _insertNote(database, note);

      await note.unlock('2468');

      expect(note.unlocked, isTrue);
      expect(image.src, isNot(startsWith('data:')));
      final protectedBytes = files[image.src]!;
      expect(isBytesPasswordEncrypted(protectedBytes), isTrue);
      expect(
        await note.decryptAttachmentForSession(protectedBytes),
        originalBytes,
      );
      final row = (await database.query('note', where: 'id = 33')).single;
      expect(row['attachments'], isNot(contains('data:image')));
      expect(row['attachments'], contains(image.src));
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'deferred inline repair remains readable only in the authenticated session',
    () async {
      final originalBytes = Uint8List.fromList([4, 3, 2, 1]);
      final inlineSource =
          'data:image/jpeg;base64,${base64Encode(originalBytes)}';
      final fake = _FakeLockFiles(files: {}, failWriteNumber: 1);
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        id: 34,
        title: 'Deferred inline attachment',
        content: await encrypt(_content('body'), '2468'),
        locked: true,
        updatedAt: DateTime.utc(2026, 7, 19),
        attachments: [NoteAttachment.image(_image(inlineSource))],
      );
      await _insertNote(database, note);

      await note.unlock('2468');

      expect(await note.readAttachmentForSession(inlineSource), originalBytes);
      await note.clearPassword();
      await expectLater(
        note.readAttachmentForSession(inlineSource),
        throwsA(isA<NoteUnlockException>()),
      );
    },
  );

  test(
    'queued sketch persistence completes before locking snapshots strokes',
    () async {
      final oldBytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'strokes': <String>[]})),
      );
      final files = <String, Uint8List>{'/docs/queued.json': oldBytes};
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final initial = SketchStroke(
        points: '1,1,0.5;2,2,0.5',
        color: Colors.black,
        size: 3,
      );
      final latest = SketchStroke(
        points: '10,20,0.5;30,40,0.5',
        color: Colors.blue,
        size: 7,
      );
      final sketch = SketchData(
        strokesFilePath: '/docs/queued.json',
        strokes: [initial],
      );
      final note = Note(
        id: 35,
        title: 'Queued drawing',
        content: _content('body'),
        plainText: 'body',
        updatedAt: DateTime.utc(2026, 7, 19),
        attachments: [NoteAttachment.sketch(sketch)],
      );
      await _insertNote(database, note);
      final saveStarted = Completer<void>();
      final releaseSave = Completer<void>();

      final saving = note.persistSketchMutation(() async {
        saveStarted.complete();
        await releaseSave.future;
        sketch.strokes = [latest];
        sketch.markStrokesHydrated();
      }, trackSync: false);
      await saveStarted.future;
      final locking = note.lock('2468');
      await Future<void>.delayed(Duration.zero);
      expect(note.locked, isFalse);

      releaseSave.complete();
      await saving;
      await locking;

      expect(note.locked, isTrue);
      final protectedStrokes = files[sketch.strokesFilePath]!;
      final plaintext = await decryptBytesWithPassword(
        protectedStrokes,
        '2468',
      );
      final decoded =
          jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      expect(decoded['strokes'], [latest.toString()]);
    },
  );

  test('failed exposed-file repair preserves authenticated access', () async {
    final originalBytes = Uint8List.fromList([5, 6, 7]);
    final files = <String, Uint8List>{
      '/docs/exposed.jpg': Uint8List.fromList(originalBytes),
    };
    final fake = _FakeLockFiles(files: files, failWriteNumber: 1);
    Note.lockFileOperationsOverride = fake.operations;
    final protectedContent = await encrypt(_content('body'), '2468');
    final image = _image('/docs/exposed.jpg');
    final note = Note(
      id: 32,
      title: 'Retry repair',
      content: protectedContent,
      locked: true,
      updatedAt: DateTime.utc(2026, 7, 19),
      attachments: [NoteAttachment.image(image)],
    );
    await _insertNote(database, note);

    await note.unlock('2468');

    expect(note.unlocked, isTrue);
    expect(note.content, _content('body'));
    expect(image.src, '/docs/exposed.jpg');
    expect(files['/docs/exposed.jpg'], originalBytes);
    expect(files.keys, ['/docs/exposed.jpg']);
    expect(await NoteLockJournal(preferences).load(), isEmpty);
  });

  test('cleanup retains aliases of a still-referenced original path', () async {
    final files = <String, Uint8List>{
      '/physical/shared.jpg': Uint8List.fromList([1]),
    };
    final fake = _FakeLockFiles(
      files: files,
      pathAliases: {
        '/container-a/shared.jpg': '/physical/shared.jpg',
        '/container-b/shared.jpg': '/physical/shared.jpg',
      },
    );
    final record = NoteLockJournalRecord(
      transactionId: 'shared-path',
      noteId: 40,
      phase: NoteLockJournalPhase.ready,
      replacements: const [
        NoteLockFileReplacement(
          attachmentIndex: 0,
          kind: NoteLockAssetKind.image,
          oldPath: '/container-a/shared.jpg',
          newPath: '/docs/protected.jpg',
        ),
      ],
    );

    expect(
      await NoteLockTransactionService(fake.operations).cleanupOriginals(
        record,
        retainedPaths: const {'/container-b/shared.jpg'},
      ),
      isTrue,
    );
    expect(files, contains('/physical/shared.jpg'));
  });

  test(
    'locking keeps audio protected while authenticating the live session',
    () async {
      final audioBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final files = <String, Uint8List>{
        '/docs/audio.wav': Uint8List.fromList(audioBytes),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final recording = NoteRecording(src: '/docs/audio.wav');
      final note = Note(
        id: 24,
        title: 'Audio',
        content: _content('body'),
        plainText: 'body',
        attachments: [NoteAttachment.audio(recording)],
      );
      await _insertNote(database, note);

      await note.lock('2468');

      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      expect(note.password, '2468');
      expect(recording.src, isNot('/docs/audio.wav'));
      final canonicalBytes = files[recording.src]!;
      expect(isBytesPasswordEncrypted(canonicalBytes), isTrue);
      expect(
        await note.decryptAttachmentForSession(canonicalBytes),
        audioBytes,
      );
      expect(files[recording.src], canonicalBytes);

      final row = (await database.query('note', where: 'id = 24')).single;
      expect(row['locked'], 1);
      expect(
        await decrypt(row['content']! as String, '2468'),
        _content('body'),
      );
      expect(row['attachments'], contains(recording.src));

      final restartedNote = await Note.findById(24);
      expect(restartedNote, isNotNull);
      expect(restartedNote!.unlocked, isFalse);
      expect(restartedNote.password, isNull);
      await restartedNote.unlock('2468');
      expect(restartedNote.unlocked, isTrue);
      expect(
        await restartedNote.decryptAttachmentForSession(canonicalBytes),
        audioBytes,
      );
      expect(files[recording.src], canonicalBytes);
    },
  );

  test(
    'newly locked sketch preview remains visible only through its session decoder',
    () async {
      final previewBytes = Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        1,
        2,
        3,
      ]);
      final files = <String, Uint8List>{
        '/docs/preview.jpg': Uint8List.fromList(previewBytes),
        '/docs/strokes.json': Uint8List.fromList(
          utf8.encode(jsonEncode({'strokes': <String>[]})),
        ),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final sketch = SketchData(
        previewImage: '/docs/preview.jpg',
        blurredThumbnail: 'existing-local-thumbnail',
        strokesFilePath: '/docs/strokes.json',
        strokes: [
          SketchStroke(points: '1,2,0.5;', color: Colors.black, size: 2),
        ],
      );
      final note = Note(
        id: 25,
        title: 'Sketch',
        content: _content('body'),
        plainText: 'body',
        attachments: [NoteAttachment.sketch(sketch)],
      );
      await _insertNote(database, note);

      await note.lock('2468');

      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      expect(sketch.previewImage, isNot('/docs/preview.jpg'));
      final canonicalPreview = files[sketch.previewImage]!;
      expect(isBytesPasswordEncrypted(canonicalPreview), isTrue);

      final displayBytes = await UniversalImage.prepareImageBytes(
        canonicalPreview,
        passwordProtectedDecoder: note.decryptAttachmentForSession,
      );
      expect(displayBytes, previewBytes);
      expect(isBytesPasswordEncrypted(files[sketch.previewImage]!), isTrue);
      expect(files, isNot(contains('/docs/preview.jpg')));
    },
  );

  test(
    'save waits for detached lock commit and never publishes staged paths early',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        id: 20,
        title: 'Concurrent save',
        content: _content('body'),
        plainText: 'body',
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);

      final reachedCommit = Completer<void>();
      final releaseCommit = Completer<void>();
      Note.lockBeforeCommitOverride = (_) async {
        reachedCommit.complete();
        await releaseCommit.future;
      };

      final lockFuture = note.lock('1234');
      await reachedCommit.future;
      final stagedPath = files.keys.singleWhere(
        (path) => path != '/docs/image.jpg',
      );

      expect(note.locked, isFalse);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');
      final beforeCommit = (await database.query(
        'note',
        where: 'id = 20',
      )).single;
      expect(beforeCommit['attachments'], contains('/docs/image.jpg'));
      expect(beforeCommit['attachments'], isNot(contains(stagedPath)));

      var saveCompleted = false;
      final saveFuture = note.save(false).then((value) {
        saveCompleted = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(saveCompleted, isFalse);

      releaseCommit.complete();
      await lockFuture;
      expect(await saveFuture, 20);

      final committed = (await database.query('note', where: 'id = 20')).single;
      expect(committed['locked'], 1);
      expect(committed['attachments'], contains(stagedPath));
      expect(files, contains(stagedPath));
      expect(files, isNot(contains('/docs/image.jpg')));
    },
  );

  test('failed lock releases queued save with original paths intact', () async {
    final files = <String, Uint8List>{
      '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
    };
    final fake = _FakeLockFiles(files: files);
    Note.lockFileOperationsOverride = fake.operations;
    final note = Note(
      id: 21,
      title: 'Rollback save',
      content: _content('body'),
      plainText: 'body',
      attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
    );
    await _insertNote(database, note);
    await database.execute('''
        CREATE TRIGGER fail_concurrent_note_lock
        BEFORE UPDATE ON note
        WHEN NEW.locked = 1 AND NEW.id = 21
        BEGIN
          SELECT RAISE(ABORT, 'injected concurrent lock failure');
        END
      ''');

    final reachedCommit = Completer<void>();
    final releaseCommit = Completer<void>();
    Note.lockBeforeCommitOverride = (_) async {
      reachedCommit.complete();
      await releaseCommit.future;
    };

    final lockFuture = note.lock('1234');
    await reachedCommit.future;
    final saveFuture = note.save(false);
    releaseCommit.complete();

    await expectLater(lockFuture, throwsA(isA<NoteLockException>()));
    expect(await saveFuture, 21);
    expect(note.locked, isFalse);
    expect(note.attachments.single.image!.src, '/docs/image.jpg');
    expect(files.keys, ['/docs/image.jpg']);
    final row = (await database.query('note', where: 'id = 21')).single;
    expect(row['locked'], 0);
    expect(row['attachments'], contains('/docs/image.jpg'));
    expect(await NoteLockJournal(preferences).load(), isEmpty);
  });

  test(
    'newer editor snapshot is saved after locking with protected paths',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        id: 22,
        title: 'Before lock',
        content: _content('before lock'),
        plainText: 'before lock',
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);

      final reachedCommit = Completer<void>();
      final releaseCommit = Completer<void>();
      Note.lockBeforeCommitOverride = (_) async {
        reachedCommit.complete();
        await releaseCommit.future;
      };

      final lockFuture = note.lock('2468');
      await reachedCommit.future;
      final newerContent = _content('typed while locking');
      final editFuture = note.saveEditorSnapshot(
        title: 'Newer title',
        content: newerContent,
        plainText: 'typed while locking',
        trackSync: false,
      );

      await Future<void>.delayed(Duration.zero);
      expect(note.locked, isFalse);
      expect(note.title, 'Before lock');
      expect(note.content, _content('before lock'));
      expect(note.attachments.single.image!.src, '/docs/image.jpg');

      releaseCommit.complete();
      await lockFuture;
      expect(await editFuture, 22);

      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      expect(note.password, '2468');
      expect(note.title, 'Newer title');
      expect(note.content, newerContent);
      expect(note.attachments.single.image!.src, isNot('/docs/image.jpg'));

      final row = (await database.query('note', where: 'id = 22')).single;
      expect(row['locked'], 1);
      expect(row['title'], 'Newer title');
      expect(await decrypt(row['content']! as String, '2468'), newerContent);
      expect(row['attachments'], contains(note.attachments.single.image!.src));
      expect(files, contains(note.attachments.single.image!.src));
      expect(files, isNot(contains('/docs/image.jpg')));
    },
  );

  test(
    'uncoordinated in-memory changes abort detached locking safely',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        id: 23,
        title: 'Original title',
        content: _content('body'),
        plainText: 'body',
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);
      Note.lockBeforeCommitOverride = (candidate) async {
        candidate.title = 'Changed outside the queue';
      };

      await expectLater(note.lock('1234'), throwsA(isA<NoteLockException>()));

      expect(note.title, 'Changed outside the queue');
      expect(note.locked, isFalse);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');
      expect(files.keys, ['/docs/image.jpg']);
      final row = (await database.query('note', where: 'id = 23')).single;
      expect(row['title'], 'Original title');
      expect(row['locked'], 0);
      expect(row['attachments'], contains('/docs/image.jpg'));
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'new-note lock failure does not publish an ID or staged paths',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        title: 'Unsaved note',
        content: _content('body'),
        plainText: 'body',
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await database.execute('''
      CREATE TRIGGER fail_new_note_lock
      BEFORE INSERT ON note
      WHEN NEW.locked = 1
      BEGIN
        SELECT RAISE(ABORT, 'injected new-note lock failure');
      END
    ''');

      await expectLater(note.lock('1234'), throwsA(isA<NoteLockException>()));

      expect(note.id, isNull);
      expect(note.locked, isFalse);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');
      expect(files.keys, ['/docs/image.jpg']);
      expect(await database.query('note'), isEmpty);
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'corrupted staged write fails verification without changing source',
    () async {
      final original = Uint8List.fromList([1, 2, 3, 4]);
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList(original),
      };
      final fake = _FakeLockFiles(files: files, corruptWriteNumber: 1);

      await expectLater(
        NoteLockTransactionService(fake.operations).prepare(
          noteId: 1,
          attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
          password: '1234',
          journal: NoteLockJournal(preferences),
        ),
        throwsA(isA<NoteLockPreparationException>()),
      );

      expect(files['/docs/image.jpg'], original);
      expect(files.keys, ['/docs/image.jpg']);
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'concurrent database edit aborts commit and preserves that edit',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      late _FakeLockFiles fake;
      fake = _FakeLockFiles(
        files: files,
        onWrite: (_, _) async {
          await database.update(
            'note',
            {'title': 'Synced title'},
            where: 'id = ?',
            whereArgs: [3],
          );
          fake.onWrite = null;
        },
      );
      Note.lockFileOperationsOverride = fake.operations;
      final note = Note(
        id: 3,
        title: 'Original title',
        content: _content('body'),
        plainText: 'body',
        updatedAt: DateTime.utc(2026, 7, 19),
        createdAt: DateTime.utc(2026, 7, 18),
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);

      await expectLater(note.lock('1234'), throwsA(isA<NoteLockException>()));

      expect(note.locked, isFalse);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');
      expect(files.keys, ['/docs/image.jpg']);
      final row = (await database.query('note', where: 'id = 3')).single;
      expect(row['title'], 'Synced title');
      expect(row['locked'], 0);
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'required missing or remote sources abort but preview is optional',
    () async {
      final fake = _FakeLockFiles(files: {});
      final service = NoteLockTransactionService(fake.operations);
      final journal = NoteLockJournal(preferences);

      await expectLater(
        service.prepare(
          noteId: 1,
          attachments: [NoteAttachment.image(_image('/missing.jpg'))],
          password: '1234',
          journal: journal,
        ),
        throwsA(isA<NoteLockPreparationException>()),
      );
      await expectLater(
        service.prepare(
          noteId: 1,
          attachments: [
            NoteAttachment.audio(
              NoteRecording(src: 'https://example.com/audio.m4a'),
            ),
          ],
          password: '1234',
          journal: journal,
        ),
        throwsA(isA<NoteLockPreparationException>()),
      );

      final sketch = SketchData(
        strokesFilePath: '/missing-old.json',
        strokes: [
          SketchStroke(points: '1,2,0.5;', color: Colors.black, size: 2),
        ],
        previewImage: '/missing-preview.jpg',
      );
      final preparation = await service.prepare(
        noteId: 1,
        attachments: [NoteAttachment.sketch(sketch)],
        password: '1234',
        journal: journal,
      );
      preparation.apply([NoteAttachment.sketch(sketch)]);
      expect(sketch.previewImage, isNull);
      expect(sketch.strokesFilePath, startsWith('/docs/'));
    },
  );

  test(
    'database write failure rolls back paths, strokes, and lock state',
    () async {
      final files = <String, Uint8List>{
        '/docs/strokes.json': Uint8List.fromList(
          utf8.encode(jsonEncode({'strokes': <String>[]})),
        ),
      };
      final fake = _FakeLockFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final stroke = SketchStroke(
        points: '5,6,0.5;',
        color: Colors.black,
        size: 2,
      );
      final sketch = SketchData(
        strokesFilePath: '/docs/strokes.json',
        strokes: [stroke],
      );
      final note = Note(
        id: 7,
        title: 'Drawing',
        content: _content('body'),
        plainText: 'body',
        updatedAt: DateTime.utc(2026, 7, 19),
        createdAt: DateTime.utc(2026, 7, 18),
        attachments: [NoteAttachment.sketch(sketch)],
      );
      await _insertNote(database, note);
      await database.execute('''
        CREATE TRIGGER fail_note_lock
        BEFORE UPDATE ON note
        WHEN NEW.locked = 1
        BEGIN
          SELECT RAISE(ABORT, 'injected database failure');
        END
      ''');

      await expectLater(note.lock('1234'), throwsA(isA<NoteLockException>()));

      expect(note.locked, isFalse);
      expect(sketch.strokes, [stroke]);
      expect(sketch.strokesFilePath, '/docs/strokes.json');
      expect(files.keys, ['/docs/strokes.json']);
      final row = (await database.query('note', where: 'id = 7')).single;
      expect(row['locked'], 0);
      expect(row['attachments'], contains('/docs/strokes.json'));
      expect(await NoteLockJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'startup recovery removes precommit staging and keeps originals',
    () async {
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList([1, 2, 3]),
      };
      final fake = _FakeLockFiles(files: files);
      final journal = NoteLockJournal(preferences);
      final service = NoteLockTransactionService(fake.operations);
      final attachment = NoteAttachment.image(_image('/docs/image.jpg'));
      final preparation = await service.prepare(
        noteId: 4,
        attachments: [attachment],
        password: '1234',
        journal: journal,
      );
      final stagedPath = preparation.replacements.single.newPath;
      expect(files.containsKey(stagedPath), isTrue);

      await NoteLockRecoveryService.recoverPending(
        database: database,
        fileOperations: fake.operations,
        journal: journal,
      );

      expect(files.containsKey('/docs/image.jpg'), isTrue);
      expect(files.containsKey(stagedPath), isFalse);
      expect(await journal.load(), isEmpty);
    },
  );

  test('malformed file-backed strokes abort before committing', () async {
    final files = <String, Uint8List>{
      '/docs/strokes.json': Uint8List.fromList(utf8.encode('not-json')),
    };
    final fake = _FakeLockFiles(files: files);

    await expectLater(
      NoteLockTransactionService(fake.operations).prepare(
        noteId: 1,
        attachments: [
          NoteAttachment.sketch(
            SketchData(strokesFilePath: '/docs/strokes.json'),
          ),
        ],
        password: '1234',
        journal: NoteLockJournal(preferences),
      ),
      throwsA(isA<NoteLockPreparationException>()),
    );

    expect(files.keys, ['/docs/strokes.json']);
    expect(await NoteLockJournal(preferences).load(), isEmpty);
  });

  test(
    'startup recovery completes committed cleanup and retries deletion',
    () async {
      final original = '/docs/original.jpg';
      final staged = '/docs/staged.jpg';
      final encrypted = await encryptBytesWithPassword(
        Uint8List.fromList([1, 2, 3]),
        '1234',
      );
      final files = <String, Uint8List>{
        original: Uint8List.fromList([1, 2, 3]),
        staged: encrypted,
      };
      final fake = _FakeLockFiles(files: files, undeletablePaths: {original});
      final serialized = jsonEncode([
        NoteAttachment.image(_image(staged)).toJson(),
      ]);
      await database.insert('note', {
        'id': 5,
        'title': 'Locked',
        'content': 'encrypted',
        'locked': 1,
        'attachments': serialized,
      });
      final record = NoteLockJournalRecord(
        transactionId: 'transaction-1',
        noteId: 5,
        phase: NoteLockJournalPhase.ready,
        replacements: [
          NoteLockFileReplacement(
            attachmentIndex: 0,
            kind: NoteLockAssetKind.image,
            oldPath: original,
            newPath: staged,
          ),
        ],
        expectedAttachmentsDigest: NoteLockJournalRecord.attachmentsDigest(
          serialized,
        ),
      );
      final journal = NoteLockJournal(preferences);
      await journal.put(record);

      await NoteLockRecoveryService.recoverPending(
        database: database,
        fileOperations: fake.operations,
        journal: journal,
      );
      expect(files.containsKey(original), isTrue);
      expect(files.containsKey(staged), isTrue);
      expect(await journal.load(), hasLength(1));

      fake.undeletablePaths.clear();
      await NoteLockRecoveryService.recoverPending(
        database: database,
        fileOperations: fake.operations,
        journal: journal,
      );
      expect(files.containsKey(original), isFalse);
      expect(files.containsKey(staged), isTrue);
      expect(await journal.load(), isEmpty);
    },
  );

  test(
    'journal stores paths and digests but no secrets or stroke payloads',
    () async {
      final fake = _FakeLockFiles(files: {});
      final sketch = SketchData(
        strokes: [
          SketchStroke(points: '987,654,0.5;', color: Colors.black, size: 2),
        ],
      );
      await NoteLockTransactionService(fake.operations).prepare(
        noteId: 6,
        attachments: [NoteAttachment.sketch(sketch)],
        password: 'secret-pin',
        journal: NoteLockJournal(preferences),
      );

      final encoded = preferences.getString(NoteLockJournal.preferenceKey)!;
      expect(encoded, isNot(contains('secret-pin')));
      expect(encoded, isNot(contains('987,654')));
      expect(encoded, isNot(contains('"strokes"')));
      expect(encoded, contains('sketchStrokes'));
    },
  );
}

class _FakeLockFiles {
  final Map<String, Uint8List> files;
  final int? failWriteNumber;
  final int? corruptWriteNumber;
  final Set<String> undeletablePaths;
  final Map<String, String> pathAliases;
  Future<void> Function(String path, Uint8List bytes)? onWrite;
  var _writeCount = 0;
  var _id = 0;

  _FakeLockFiles({
    required this.files,
    this.failWriteNumber,
    this.corruptWriteNumber,
    this.undeletablePaths = const {},
    this.pathAliases = const {},
    this.onWrite,
  });

  late final NoteLockFileOperations operations = NoteLockFileOperations(
    exists: (filePath) async => files.containsKey(filePath),
    read: (filePath) async {
      final bytes = files[filePath];
      if (bytes == null) throw StateError('Missing $filePath');
      return Uint8List.fromList(bytes);
    },
    write: (filePath, bytes) async {
      _writeCount++;
      if (_writeCount == failWriteNumber) {
        throw StateError('Injected write failure');
      }
      files[filePath] = _writeCount == corruptWriteNumber
          ? Uint8List.fromList([...bytes, 0xff])
          : Uint8List.fromList(bytes);
      await onWrite?.call(filePath, bytes);
    },
    delete: (filePath) async {
      if (undeletablePaths.contains(filePath)) return false;
      return files.remove(filePath) != null;
    },
    documentDirectory: () async => '/docs',
    encryptWithPassword: encryptBytesWithPassword,
    decryptWithPassword: decryptBytesWithPassword,
    newId: () => 'generated-${++_id}',
    resolvePath: (filePath) async => pathAliases[filePath] ?? filePath,
  );
}

NoteImage _image(String source) {
  return NoteImage(
    src: source,
    size: 3,
    index: 0,
    aspectRatio: '1:1',
    lastModified: '2026-07-19T00:00:00.000Z',
  );
}

String _content(String text) => jsonEncode([
  {'insert': '$text\n'},
]);

Future<void> _insertNote(Database database, Note note) async {
  final row = await note.toJsonAsync();
  row['id'] = note.id;
  await database.insert('note', row);
}
