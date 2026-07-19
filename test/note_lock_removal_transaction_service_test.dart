import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
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
    Note.lockRemovalBeforeCommitOverride = null;
    Note.lockRemovalCommittedNotifierOverride = (_) {};
  });

  tearDown(() async {
    Note.lockFileOperationsOverride = null;
    Note.lockRemovalBeforeCommitOverride = null;
    Note.lockRemovalCommittedNotifierOverride = null;
    await database.close();
  });

  test(
    'stages verified plaintext copies and clears a missing preview',
    () async {
      const password = '1234';
      final imageBytes = Uint8List.fromList([1, 2, 3]);
      final audioBytes = Uint8List.fromList([4, 5, 6]);
      final strokesBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': [
              SketchStroke(
                points: '1,2,0.5;',
                color: Colors.black,
                size: 2,
              ).toString(),
            ],
          }),
        ),
      );
      final files = <String, Uint8List>{
        '/docs/image.jpg': await encryptBytesWithPassword(imageBytes, password),
        '/docs/audio.m4a': audioBytes,
        '/docs/strokes.json': await encryptBytesWithPassword(
          strokesBytes,
          password,
        ),
      };
      final fake = _FakeRemovalFiles(files: files);
      final attachments = [
        NoteAttachment.image(_image('/docs/image.jpg')),
        NoteAttachment.audio(NoteRecording(src: '/docs/audio.m4a')),
        NoteAttachment.sketch(
          SketchData(
            strokesFilePath: '/docs/strokes.json',
            previewImage: '/docs/missing-preview.jpg',
          ),
        ),
      ];
      final journal = NoteLockRemovalJournal(preferences);

      final preparation =
          await NoteLockRemovalTransactionService(fake.operations).prepare(
            noteId: 1,
            attachments: attachments,
            password: password,
            journal: journal,
          );
      preparation.apply(attachments);

      expect(preparation.replacements, hasLength(3));
      expect(attachments[2].sketch!.previewImage, isNull);
      expect(files['/docs/image.jpg'], isNot(imageBytes));
      expect(files['/docs/audio.m4a'], audioBytes);
      expect(files['/docs/strokes.json'], isNot(strokesBytes));
      expect(files[attachments[0].image!.src], imageBytes);
      expect(files[attachments[1].recording!.src], audioBytes);
      expect(files[attachments[2].sketch!.strokesFilePath], strokesBytes);
      for (final replacement in preparation.replacements) {
        expect(isBytesPasswordEncrypted(files[replacement.newPath]!), isFalse);
      }
    },
  );

  test(
    'resolves a stale container path before removing an audio lock',
    () async {
      const stalePath =
          '/old-container/Library/Application Support/protected.wav';
      const currentPath =
          '/current-container/Library/Application Support/protected.wav';
      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final protected = await encryptBytesWithPassword(plaintext, '1234');
      final files = <String, Uint8List>{currentPath: protected};
      final fake = _FakeRemovalFiles(
        files: files,
        resolvedPaths: {stalePath: currentPath},
      );
      final attachments = [NoteAttachment.audio(NoteRecording(src: stalePath))];

      final preparation =
          await NoteLockRemovalTransactionService(fake.operations).prepare(
            noteId: 9,
            attachments: attachments,
            password: '1234',
            journal: NoteLockRemovalJournal(preferences),
          );
      preparation.apply(attachments);

      expect(preparation.replacements.single.oldPath, stalePath);
      expect(files[attachments.single.recording!.src], plaintext);
      expect(
        await NoteLockRemovalTransactionService(
          fake.operations,
        ).cleanupOriginals(preparation.journalRecord),
        isTrue,
      );
      expect(files, isNot(contains(currentPath)));
      expect(files, contains(attachments.single.recording!.src));
    },
  );

  test('missing required sources and malformed strokes fail closed', () async {
    const password = '1234';
    final journal = NoteLockRemovalJournal(preferences);
    final missingFake = _FakeRemovalFiles(files: {});

    await expectLater(
      NoteLockRemovalTransactionService(missingFake.operations).prepare(
        noteId: 2,
        attachments: [NoteAttachment.image(_image('/docs/missing.jpg'))],
        password: password,
        journal: journal,
      ),
      throwsA(isA<NoteLockRemovalPreparationException>()),
    );

    final wrongPinSource = await encryptBytesWithPassword(
      Uint8List.fromList([1, 2, 3]),
      password,
    );
    final wrongPinFake = _FakeRemovalFiles(
      files: {'/docs/image.jpg': wrongPinSource},
    );
    await expectLater(
      NoteLockRemovalTransactionService(wrongPinFake.operations).prepare(
        noteId: 2,
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
        password: '9999',
        journal: journal,
      ),
      throwsA(isA<NoteLockRemovalPreparationException>()),
    );
    expect(wrongPinFake.files.keys, ['/docs/image.jpg']);

    final corrupt = await encryptBytesWithPassword(
      Uint8List.fromList(utf8.encode('not-json')),
      password,
    );
    final corruptFake = _FakeRemovalFiles(
      files: {'/docs/strokes.json': corrupt},
    );
    await expectLater(
      NoteLockRemovalTransactionService(corruptFake.operations).prepare(
        noteId: 2,
        attachments: [
          NoteAttachment.sketch(
            SketchData(strokesFilePath: '/docs/strokes.json'),
          ),
        ],
        password: password,
        journal: journal,
      ),
      throwsA(isA<NoteLockRemovalPreparationException>()),
    );
    expect(corruptFake.files.keys, ['/docs/strokes.json']);
    expect(await journal.load(), isEmpty);
  });

  test('a later staged write failure removes only fresh files', () async {
    const password = '1234';
    final originalImage = await encryptBytesWithPassword(
      Uint8List.fromList([1, 2, 3]),
      password,
    );
    final originalAudio = await encryptBytesWithPassword(
      Uint8List.fromList([4, 5, 6]),
      password,
    );
    final files = <String, Uint8List>{
      '/docs/image.jpg': Uint8List.fromList(originalImage),
      '/docs/audio.m4a': Uint8List.fromList(originalAudio),
    };
    final fake = _FakeRemovalFiles(files: files, failWriteNumber: 2);
    final journal = NoteLockRemovalJournal(preferences);

    await expectLater(
      NoteLockRemovalTransactionService(fake.operations).prepare(
        noteId: 3,
        attachments: [
          NoteAttachment.image(_image('/docs/image.jpg')),
          NoteAttachment.audio(NoteRecording(src: '/docs/audio.m4a')),
        ],
        password: password,
        journal: journal,
      ),
      throwsA(isA<NoteLockRemovalPreparationException>()),
    );

    expect(files.keys.toSet(), {'/docs/image.jpg', '/docs/audio.m4a'});
    expect(files['/docs/image.jpg'], originalImage);
    expect(files['/docs/audio.m4a'], originalAudio);
    expect(await journal.load(), isEmpty);
  });

  test(
    'corrupt read-back fails verification and preserves the source',
    () async {
      const password = '1234';
      final original = await encryptBytesWithPassword(
        Uint8List.fromList([1, 2, 3]),
        password,
      );
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList(original),
      };
      final fake = _FakeRemovalFiles(files: files, corruptWriteNumber: 1);
      final journal = NoteLockRemovalJournal(preferences);

      await expectLater(
        NoteLockRemovalTransactionService(fake.operations).prepare(
          noteId: 4,
          attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
          password: password,
          journal: journal,
        ),
        throwsA(isA<NoteLockRemovalPreparationException>()),
      );

      expect(files.keys, ['/docs/image.jpg']);
      expect(files['/docs/image.jpg'], original);
      expect(await journal.load(), isEmpty);
    },
  );

  test(
    'successful removal commits files, tracking, and sync atomically',
    () async {
      const password = '1234';
      final imagePlaintext = Uint8List.fromList([1, 2, 3, 4]);
      final audioPlaintext = Uint8List.fromList([5, 6, 7]);
      final files = <String, Uint8List>{
        '/docs/image.jpg': await encryptBytesWithPassword(
          imagePlaintext,
          password,
        ),
        '/docs/audio.m4a': audioPlaintext,
      };
      final fake = _FakeRemovalFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = await _lockedNote(
        id: 10,
        password: password,
        attachments: [
          NoteAttachment.image(_image('/docs/image.jpg')),
          NoteAttachment.audio(NoteRecording(src: '/docs/audio.m4a')),
        ],
      );
      await _insertNote(database, note);
      await database.insert('file_sync_track', {
        'note_id': 10,
        'local_path': '/docs/image.jpg',
        'remote_path': 'remote/image',
        'content_hash': 'old-image-hash',
      });
      await database.insert('file_sync_track', {
        'note_id': 10,
        'local_path': '/docs/audio.m4a',
        'remote_path': 'remote/audio',
        'content_hash': 'old-audio-hash',
      });

      await note.removeLock(password);

      expect(note.locked, isFalse);
      expect(note.unlocked, isFalse);
      expect(note.password, isNull);
      expect(note.content, _content('body'));
      final imagePath = note.attachments[0].image!.src;
      final audioPath = note.attachments[1].recording!.src;
      expect(imagePath, isNot('/docs/image.jpg'));
      expect(audioPath, isNot('/docs/audio.m4a'));
      expect(files[imagePath], imagePlaintext);
      expect(files[audioPath], audioPlaintext);
      expect(files, isNot(contains('/docs/image.jpg')));
      expect(files, isNot(contains('/docs/audio.m4a')));

      final row = (await database.query('note', where: 'id = 10')).single;
      expect(row['locked'], 0);
      expect(row['attachments'], contains(imagePath));
      expect(row['attachments'], contains(audioPath));
      final tracks = await database.query(
        'file_sync_track',
        orderBy: 'remote_path',
      );
      expect(tracks.map((track) => track['local_path']).toSet(), {
        imagePath,
        audioPath,
      });
      expect(tracks.every((track) => track['content_hash'] == null), isTrue);
      final sync = (await database.query('sync_track')).single;
      expect(sync['action'], SyncAction.upload.name);
      expect(sync['status'], SyncStatus.pending.name);
      expect(await NoteLockRemovalJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'wrong cached PIN and a missing required file preserve the lock',
    () async {
      const password = '1234';
      final files = <String, Uint8List>{
        '/docs/image.jpg': await encryptBytesWithPassword(
          Uint8List.fromList([1, 2, 3]),
          password,
        ),
      };
      final fake = _FakeRemovalFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = await _lockedNote(
        id: 11,
        password: password,
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);
      await note.unlock(password);

      await expectLater(
        note.removeLock('9999'),
        throwsA(isA<NoteLockRemovalException>()),
      );
      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      expect(note.password, password);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');

      files.remove('/docs/image.jpg');
      await expectLater(
        note.removeLock(password),
        throwsA(isA<NoteLockRemovalException>()),
      );
      expect(note.locked, isTrue);
      expect(note.unlocked, isTrue);
      final row = (await database.query('note', where: 'id = 11')).single;
      expect(row['locked'], 1);
      expect(row['attachments'], contains('/docs/image.jpg'));
      expect(await NoteLockRemovalJournal(preferences).load(), isEmpty);
    },
  );

  test('autosave waits until staged paths commit', () async {
    const password = '1234';
    final files = <String, Uint8List>{
      '/docs/image.jpg': await encryptBytesWithPassword(
        Uint8List.fromList([1, 2, 3]),
        password,
      ),
    };
    final fake = _FakeRemovalFiles(files: files);
    Note.lockFileOperationsOverride = fake.operations;
    final note = await _lockedNote(
      id: 12,
      password: password,
      attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
    );
    await _insertNote(database, note);
    final reachedCommit = Completer<void>();
    final releaseCommit = Completer<void>();
    Note.lockRemovalBeforeCommitOverride = (_) async {
      reachedCommit.complete();
      await releaseCommit.future;
    };

    final removal = note.removeLock(password);
    await reachedCommit.future;
    final stagedPath = files.keys.singleWhere(
      (path) => path != '/docs/image.jpg',
    );
    expect(note.locked, isTrue);
    expect(note.attachments.single.image!.src, '/docs/image.jpg');
    final before = (await database.query('note', where: 'id = 12')).single;
    expect(before['attachments'], isNot(contains(stagedPath)));

    var saveCompleted = false;
    final save = note.save(false).then((value) {
      saveCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(saveCompleted, isFalse);

    releaseCommit.complete();
    await removal;
    expect(await save, 12);
    expect(note.locked, isFalse);
    final committed = (await database.query('note', where: 'id = 12')).single;
    expect(committed['locked'], 0);
    expect(committed['attachments'], contains(stagedPath));
    expect(files, contains(stagedPath));
    expect(files, isNot(contains('/docs/image.jpg')));
  });

  test(
    'database conflict removes staging and retains protected originals',
    () async {
      const password = '1234';
      final protected = await encryptBytesWithPassword(
        Uint8List.fromList([1, 2, 3]),
        password,
      );
      final files = <String, Uint8List>{
        '/docs/image.jpg': Uint8List.fromList(protected),
      };
      final fake = _FakeRemovalFiles(files: files);
      Note.lockFileOperationsOverride = fake.operations;
      final note = await _lockedNote(
        id: 13,
        password: password,
        attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
      );
      await _insertNote(database, note);
      Note.lockRemovalBeforeCommitOverride = (_) async {
        await database.update(
          'note',
          {'title': 'Concurrent title'},
          where: 'id = ?',
          whereArgs: [13],
        );
      };

      await expectLater(
        note.removeLock(password),
        throwsA(isA<NoteLockRemovalException>()),
      );

      expect(note.locked, isTrue);
      expect(note.attachments.single.image!.src, '/docs/image.jpg');
      expect(files.keys, ['/docs/image.jpg']);
      expect(files['/docs/image.jpg'], protected);
      final row = (await database.query('note', where: 'id = 13')).single;
      expect(row['title'], 'Concurrent title');
      expect(row['locked'], 1);
      expect(await NoteLockRemovalJournal(preferences).load(), isEmpty);
    },
  );

  test('live-state mutation aborts before the database path switch', () async {
    const password = '1234';
    final protected = await encryptBytesWithPassword(
      Uint8List.fromList([1, 2, 3]),
      password,
    );
    final files = <String, Uint8List>{
      '/docs/image.jpg': Uint8List.fromList(protected),
    };
    final fake = _FakeRemovalFiles(files: files);
    Note.lockFileOperationsOverride = fake.operations;
    final note = await _lockedNote(
      id: 17,
      password: password,
      attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
    );
    await _insertNote(database, note);
    Note.lockRemovalBeforeCommitOverride = (candidate) async {
      candidate.title = 'Changed outside the queue';
    };

    await expectLater(
      note.removeLock(password),
      throwsA(isA<NoteLockRemovalException>()),
    );

    expect(note.title, 'Changed outside the queue');
    expect(note.locked, isTrue);
    expect(note.attachments.single.image!.src, '/docs/image.jpg');
    expect(files.keys, ['/docs/image.jpg']);
    final row = (await database.query('note', where: 'id = 17')).single;
    expect(row['title'], 'Locked note');
    expect(row['locked'], 1);
    expect(row['attachments'], contains('/docs/image.jpg'));
    expect(await NoteLockRemovalJournal(preferences).load(), isEmpty);
  });

  test('startup recovery removes uncommitted staging', () async {
    const password = '1234';
    final protected = await encryptBytesWithPassword(
      Uint8List.fromList([1, 2, 3]),
      password,
    );
    final files = <String, Uint8List>{
      '/docs/image.jpg': Uint8List.fromList(protected),
    };
    final fake = _FakeRemovalFiles(files: files);
    final journal = NoteLockRemovalJournal(preferences);
    final preparation = await NoteLockRemovalTransactionService(fake.operations)
        .prepare(
          noteId: 14,
          attachments: [NoteAttachment.image(_image('/docs/image.jpg'))],
          password: password,
          journal: journal,
        );
    final stagedPath = preparation.replacements.single.newPath;

    await NoteLockRemovalRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );

    expect(files, contains('/docs/image.jpg'));
    expect(files, isNot(contains(stagedPath)));
    expect(await journal.load(), isEmpty);
  });

  test('startup recovery retries committed original cleanup', () async {
    const original = '/docs/original.jpg';
    const staged = '/docs/staged.jpg';
    final files = <String, Uint8List>{
      original: Uint8List.fromList([9, 9, 9]),
      staged: Uint8List.fromList([1, 2, 3]),
    };
    final fake = _FakeRemovalFiles(files: files, undeletablePaths: {original});
    final serialized = jsonEncode([
      NoteAttachment.image(_image(staged)).toJson(),
    ]);
    await database.insert('note', {
      'id': 15,
      'title': 'Unlocked',
      'content': _content('body'),
      'locked': 0,
      'attachments': serialized,
    });
    final record = NoteLockRemovalJournalRecord(
      transactionId: 'remove-transaction',
      noteId: 15,
      phase: NoteLockRemovalJournalPhase.ready,
      replacements: const [
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
    final journal = NoteLockRemovalJournal(preferences);
    await journal.put(record);

    await NoteLockRemovalRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );
    expect(files, contains(original));
    expect(files, contains(staged));
    expect(await journal.load(), hasLength(1));

    fake.undeletablePaths.clear();
    await NoteLockRemovalRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );
    expect(files, isNot(contains(original)));
    expect(files, contains(staged));
    expect(await journal.load(), isEmpty);
  });

  test('lock-removal journal contains no PIN or plaintext payload', () async {
    const password = 'secret-pin';
    final protected = await encryptBytesWithPassword(
      Uint8List.fromList(utf8.encode('private-audio-payload')),
      password,
    );
    final fake = _FakeRemovalFiles(files: {'/docs/audio.m4a': protected});

    await NoteLockRemovalTransactionService(fake.operations).prepare(
      noteId: 16,
      attachments: [
        NoteAttachment.audio(NoteRecording(src: '/docs/audio.m4a')),
      ],
      password: password,
      journal: NoteLockRemovalJournal(preferences),
    );

    final encoded = preferences.getString(
      NoteLockRemovalJournal.preferenceKey,
    )!;
    expect(encoded, isNot(contains(password)));
    expect(encoded, isNot(contains('private-audio-payload')));
    expect(encoded, contains('audio'));
  });
}

class _FakeRemovalFiles {
  final Map<String, Uint8List> files;
  final int? failWriteNumber;
  final int? corruptWriteNumber;
  final Set<String> undeletablePaths;
  final Map<String, String> resolvedPaths;
  var _writeCount = 0;
  var _id = 0;

  _FakeRemovalFiles({
    required this.files,
    this.failWriteNumber,
    this.corruptWriteNumber,
    this.undeletablePaths = const {},
    this.resolvedPaths = const {},
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
    },
    delete: (filePath) async {
      if (undeletablePaths.contains(filePath)) return false;
      return files.remove(filePath) != null;
    },
    documentDirectory: () async => '/docs',
    encryptWithPassword: encryptBytesWithPassword,
    decryptWithPassword: decryptBytesWithPassword,
    newId: () => 'removal-${++_id}',
    resolvePath: (filePath) async => resolvedPaths[filePath] ?? filePath,
  );
}

Future<Note> _lockedNote({
  required int id,
  required String password,
  required List<NoteAttachment> attachments,
}) async {
  return Note(
    id: id,
    title: 'Locked note',
    content: await encrypt(_content('body'), password),
    plainText: '',
    locked: true,
    createdAt: DateTime.utc(2026, 7, 18),
    updatedAt: DateTime.utc(2026, 7, 19),
    attachments: attachments,
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
