import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;
  late SharedPreferences preferences;
  late _FakeAttachmentFiles files;
  late NewAttachmentTransactionJournal journal;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    await AppState.init(prefs: preferences);
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await FileSyncTrack.createTable(database);
    await NoteSyncTrack.createTable(database);
    AppState.db = database;

    files = _FakeAttachmentFiles();
    journal = NewAttachmentTransactionJournal(preferences);
    Note.lockFileOperationsOverride = files.operations;
    Note.newAttachmentJournalOverride = journal;
    Note.newAttachmentReadOverride = files.readForSession;
    Note.newAttachmentWriteOverride = files.writeForSession;
    Note.unlockPostAuthenticationOverride = (_, _) async {};
    Note.syncTriggerOverride = () {};
  });

  tearDown(() async {
    Note.lockFileOperationsOverride = null;
    Note.newAttachmentJournalOverride = null;
    Note.newAttachmentReadOverride = null;
    Note.newAttachmentWriteOverride = null;
    Note.unlockPostAuthenticationOverride = null;
    Note.syncTriggerOverride = null;
    await database.close();
  });

  test('locked image commits only a verified protected staged file', () async {
    const originalPath = '/docs/original.jpg';
    final originalBytes = Uint8List.fromList([1, 2, 3, 4]);
    files.data[originalPath] = originalBytes;
    final note = await _lockedNote(database, id: 1);
    final image = _image(originalPath);

    await note.addImage(image);

    expect(note.attachments, hasLength(1));
    expect(note.attachments.single.image, same(image));
    expect(image.src, '/docs/generated-2.jpg');
    expect(files.data.containsKey(originalPath), isFalse);
    expect(isBytesPasswordEncrypted(files.data[image.src]!), isTrue);
    expect(await files.readForSession(image.src), originalBytes);
    expect(await journal.load(), isEmpty);
    final row = (await database.query('note', where: 'id = 1')).single;
    expect(row['attachments'], contains(image.src));
    expect(row['attachments'], isNot(contains(originalPath)));
  });

  test(
    'database failure rolls back audio and preserves the retry source',
    () async {
      const originalPath = '/docs/recording.wav';
      final originalBytes = Uint8List.fromList([9, 8, 7, 6]);
      files.data[originalPath] = originalBytes;
      final note = await _lockedNote(database, id: 2);
      final originalUpdatedAt = note.updatedAt;
      final recording = NoteRecording(src: originalPath, title: 'memo');
      await database.execute('''
        CREATE TRIGGER fail_note_attachment_update
        BEFORE UPDATE ON note
        BEGIN
          SELECT RAISE(FAIL, 'injected update failure');
        END
      ''');

      await expectLater(
        note.addRecording(recording),
        throwsA(
          isA<NoteAttachmentCommitException>().having(
            (error) => error.failure,
            'failure',
            NoteAttachmentCommitFailure.persistence,
          ),
        ),
      );

      expect(note.attachments, isEmpty);
      expect(note.updatedAt, originalUpdatedAt);
      expect(recording.src, originalPath);
      expect(files.data, {originalPath: originalBytes});
      expect(await journal.load(), isEmpty);
      final row = (await database.query('note', where: 'id = 2')).single;
      expect(row['attachments'], isNot(contains('recording.wav')));
      expect(row['attachments'], isNot(contains('generated-2.wav')));
    },
  );

  test('startup recovery retains a committed staged path', () async {
    const original = '/docs/original.m4a';
    const staged = '/docs/staged.m4a';
    files.data[original] = Uint8List.fromList([1]);
    files.data[staged] = Uint8List.fromList([2]);
    final note = Note(
      id: 3,
      title: 'Audio',
      content: _content('audio'),
      attachments: [NoteAttachment.audio(NoteRecording(src: staged))],
    );
    await _insertNote(database, note);
    await journal.put(
      const NewAttachmentTransactionRecord(
        transactionId: 'tx-committed',
        originalPath: original,
        stagedPath: staged,
      ),
    );

    await NewAttachmentTransactionRecoveryService.recoverPending(
      database: database,
      operations: files.operations,
      journal: journal,
    );

    expect(files.data.containsKey(original), isFalse);
    expect(files.data.containsKey(staged), isTrue);
    expect(await journal.load(), isEmpty);
  });

  test('startup recovery removes an uncommitted staged path', () async {
    const original = '/docs/original.m4a';
    const staged = '/docs/staged.m4a';
    files.data[original] = Uint8List.fromList([1]);
    files.data[staged] = Uint8List.fromList([2]);
    await journal.put(
      const NewAttachmentTransactionRecord(
        transactionId: 'tx-uncommitted',
        originalPath: original,
        stagedPath: staged,
      ),
    );

    await NewAttachmentTransactionRecoveryService.recoverPending(
      database: database,
      operations: files.operations,
      journal: journal,
    );

    expect(files.data.containsKey(original), isTrue);
    expect(files.data.containsKey(staged), isFalse);
    expect(await journal.load(), isEmpty);
  });

  test(
    'startup recovery uses resolved paths for a committed attachment',
    () async {
      const staleOriginal = '/old/Library/Application Support/original.m4a';
      const staleStaged = '/old/Library/Application Support/staged.m4a';
      const currentOriginal =
          '/current/Library/Application Support/original.m4a';
      const currentStaged = '/current/Library/Application Support/staged.m4a';
      final aliasFiles = _FakeAttachmentFiles(
        pathAliases: {
          staleOriginal: currentOriginal,
          staleStaged: currentStaged,
        },
      );
      aliasFiles.data[currentOriginal] = Uint8List.fromList([1]);
      aliasFiles.data[currentStaged] = Uint8List.fromList([2]);
      final note = Note(
        id: 6,
        title: 'Moved container',
        content: _content('audio'),
        attachments: [NoteAttachment.audio(NoteRecording(src: staleStaged))],
      );
      await _insertNote(database, note);
      await journal.put(
        const NewAttachmentTransactionRecord(
          transactionId: 'tx-stale-committed',
          originalPath: staleOriginal,
          stagedPath: staleStaged,
        ),
      );

      await NewAttachmentTransactionRecoveryService.recoverPending(
        database: database,
        operations: aliasFiles.operations,
        journal: journal,
      );

      expect(aliasFiles.data.containsKey(currentOriginal), isFalse);
      expect(aliasFiles.data.containsKey(currentStaged), isTrue);
      expect(await journal.load(), isEmpty);
    },
  );

  test(
    'startup recovery retains its journal when resolved staging cannot delete',
    () async {
      const staleOriginal = '/old/Library/Application Support/original.jpg';
      const staleStaged = '/old/Library/Application Support/staged.jpg';
      const currentOriginal =
          '/current/Library/Application Support/original.jpg';
      const currentStaged = '/current/Library/Application Support/staged.jpg';
      final undeletable = <String>{currentStaged};
      final aliasFiles = _FakeAttachmentFiles(
        pathAliases: {
          staleOriginal: currentOriginal,
          staleStaged: currentStaged,
        },
        undeletablePaths: undeletable,
      );
      aliasFiles.data[currentOriginal] = Uint8List.fromList([1]);
      aliasFiles.data[currentStaged] = Uint8List.fromList([2]);
      await journal.put(
        const NewAttachmentTransactionRecord(
          transactionId: 'tx-stale-uncommitted',
          originalPath: staleOriginal,
          stagedPath: staleStaged,
        ),
      );

      await NewAttachmentTransactionRecoveryService.recoverPending(
        database: database,
        operations: aliasFiles.operations,
        journal: journal,
      );

      expect(aliasFiles.data.containsKey(currentOriginal), isTrue);
      expect(aliasFiles.data.containsKey(currentStaged), isTrue);
      expect(await journal.load(), hasLength(1));

      undeletable.clear();
      await NewAttachmentTransactionRecoveryService.recoverPending(
        database: database,
        operations: aliasFiles.operations,
        journal: journal,
      );
      expect(aliasFiles.data.containsKey(currentStaged), isFalse);
      expect(await journal.load(), isEmpty);
    },
  );

  test('immediate cleanup and rollback operate on resolved paths', () async {
    const staleOriginal = '/old/Library/Application Support/source.wav';
    const staleStaged = '/old/Library/Application Support/protected.wav';
    const currentOriginal = '/current/Library/Application Support/source.wav';
    const currentStaged = '/current/Library/Application Support/protected.wav';
    final aliasFiles = _FakeAttachmentFiles(
      pathAliases: {staleOriginal: currentOriginal, staleStaged: currentStaged},
    );
    final service = NewAttachmentTransactionService(
      operations: aliasFiles.operations,
      journal: journal,
    );
    const committedRecord = NewAttachmentTransactionRecord(
      transactionId: 'tx-finish-stale',
      originalPath: staleOriginal,
      stagedPath: staleStaged,
    );
    aliasFiles.data[currentOriginal] = Uint8List.fromList([1]);
    aliasFiles.data[currentStaged] = Uint8List.fromList([2]);
    await _insertNote(
      database,
      Note(
        id: 7,
        title: 'Committed',
        content: _content('audio'),
        attachments: [NoteAttachment.audio(NoteRecording(src: staleStaged))],
      ),
    );
    await journal.put(committedRecord);

    expect(
      await service.finishCommitted(
        const PreparedNewAttachmentFile(record: committedRecord),
        database,
      ),
      isTrue,
    );
    expect(aliasFiles.data.containsKey(currentOriginal), isFalse);
    expect(aliasFiles.data.containsKey(currentStaged), isTrue);

    const rollbackRecord = NewAttachmentTransactionRecord(
      transactionId: 'tx-rollback-stale',
      originalPath: staleOriginal,
      stagedPath: staleStaged,
    );
    await journal.put(rollbackRecord);
    await service.rollback(
      const PreparedNewAttachmentFile(record: rollbackRecord),
    );
    expect(aliasFiles.data.containsKey(currentStaged), isFalse);
    expect(await journal.load(), isEmpty);
  });

  test(
    'deferred source cleanup resolves stale paths and retries deletion',
    () async {
      const staleSource = '/old/Library/Application Support/uncommitted.jpg';
      const currentSource =
          '/current/Library/Application Support/uncommitted.jpg';
      final undeletable = <String>{currentSource};
      final aliasFiles = _FakeAttachmentFiles(
        pathAliases: {staleSource: currentSource},
        undeletablePaths: undeletable,
      );
      aliasFiles.data[currentSource] = Uint8List.fromList([4, 5, 6]);
      final cleanupJournal = PendingAttachmentSourceCleanupJournal(preferences);
      final cleanupService = PendingAttachmentSourceCleanupService(
        operations: aliasFiles.operations,
        journal: cleanupJournal,
      );

      expect(
        await cleanupService.scheduleAndCleanup(
          sourcePath: staleSource,
          database: database,
        ),
        isFalse,
      );
      expect(aliasFiles.data.containsKey(currentSource), isTrue);
      expect(await cleanupJournal.load(), hasLength(1));

      undeletable.clear();
      await PendingAttachmentSourceCleanupRecoveryService.recoverPending(
        database: database,
        operations: aliasFiles.operations,
        journal: cleanupJournal,
      );
      expect(aliasFiles.data.containsKey(currentSource), isFalse);
      expect(await cleanupJournal.load(), isEmpty);
    },
  );

  test('deferred cleanup preserves a resolved database reference', () async {
    const staleSource = '/old/Library/Application Support/shared.jpg';
    const currentSource = '/current/Library/Application Support/shared.jpg';
    final aliasFiles = _FakeAttachmentFiles(
      pathAliases: {staleSource: currentSource},
    );
    aliasFiles.data[currentSource] = Uint8List.fromList([7, 8]);
    await _insertNote(
      database,
      Note(
        id: 8,
        title: 'Referenced',
        content: _content('image'),
        attachments: [NoteAttachment.image(_image(staleSource))],
      ),
    );
    final cleanupJournal = PendingAttachmentSourceCleanupJournal(preferences);
    final cleanupService = PendingAttachmentSourceCleanupService(
      operations: aliasFiles.operations,
      journal: cleanupJournal,
    );

    expect(
      await cleanupService.scheduleAndCleanup(
        sourcePath: staleSource,
        database: database,
      ),
      isTrue,
    );
    expect(aliasFiles.data.containsKey(currentSource), isTrue);
    expect(await cleanupJournal.load(), isEmpty);
  });

  test(
    'verification failure preserves the source and removes staging',
    () async {
      const original = '/docs/original.jpg';
      final originalBytes = Uint8List.fromList([4, 3, 2, 1]);
      files.data[original] = originalBytes;
      files.corruptSessionWrites = true;
      final service = NewAttachmentTransactionService(
        operations: files.operations,
        journal: journal,
      );

      await expectLater(
        service.prepare(
          sourcePath: original,
          readForSession: files.readForSession,
          writeForSession: files.writeForSession,
        ),
        throwsA(
          isA<NewAttachmentPreparationException>().having(
            (error) => error.failure,
            'failure',
            NewAttachmentPreparationFailure.verification,
          ),
        ),
      );

      expect(files.data, {original: originalBytes});
      expect(await journal.load(), isEmpty);
    },
  );

  test(
    'discard cleanup preserves a source referenced by another note',
    () async {
      const shared = '/docs/shared.jpg';
      files.data[shared] = Uint8List.fromList([1, 2]);
      await _insertNote(
        database,
        Note(
          id: 5,
          title: 'Shared',
          content: _content('shared'),
          attachments: [NoteAttachment.image(_image(shared))],
        ),
      );

      final deleted =
          await NewAttachmentTransactionService.deleteSourceIfUnreferenced(
            sourcePath: shared,
            database: database,
            operations: files.operations,
          );

      expect(deleted, isFalse);
      expect(files.data.containsKey(shared), isTrue);
    },
  );

  test(
    'failed sketch deletion restores the attachment before returning',
    () async {
      final sketch = SketchData(
        strokes: [
          SketchStroke(points: '1,1,0.5;2,2,0.5', color: Colors.black, size: 2),
        ],
        previewImage: '/docs/preview.jpg',
        strokesFilePath: '/docs/strokes.json',
      );
      final note = Note(
        id: 4,
        title: 'Sketch',
        content: _content('drawing'),
        attachments: [NoteAttachment.sketch(sketch)],
      );
      await _insertNote(database, note);
      await database.execute('''
      CREATE TRIGGER fail_sketch_delete_update
      BEFORE UPDATE ON note
      BEGIN
        SELECT RAISE(FAIL, 'injected sketch delete failure');
      END
    ''');

      await expectLater(
        note.removeSketch(sketch),
        throwsA(isA<NoteSketchSaveException>()),
      );

      expect(note.hasSketch(sketch), isTrue);
      final row = (await database.query('note', where: 'id = 4')).single;
      expect(row['attachments'], contains('/docs/strokes.json'));
    },
  );
}

class _FakeAttachmentFiles {
  final Map<String, Uint8List> data = {};
  final Map<String, String> pathAliases;
  final Set<String> undeletablePaths;
  bool corruptSessionWrites = false;
  var _id = 0;

  _FakeAttachmentFiles({
    this.pathAliases = const {},
    this.undeletablePaths = const {},
  });

  late final NoteLockFileOperations operations = NoteLockFileOperations(
    exists: (filePath) async => data.containsKey(filePath),
    read: (filePath) async => Uint8List.fromList(data[filePath]!),
    write: (filePath, bytes) async {
      data[filePath] = Uint8List.fromList(bytes);
    },
    delete: (filePath) async {
      if (undeletablePaths.contains(filePath)) return false;
      return data.remove(filePath) != null;
    },
    documentDirectory: () async => '/docs',
    encryptWithPassword: encryptBytesWithPassword,
    decryptWithPassword: decryptBytesWithPassword,
    newId: () => 'generated-${++_id}',
    resolvePath: (filePath) async => pathAliases[filePath] ?? filePath,
  );

  Future<Uint8List> readForSession(String filePath) async {
    final bytes = data[filePath];
    if (bytes == null) throw StateError('Missing $filePath');
    if (isBytesPasswordEncrypted(bytes)) {
      return decryptBytesWithPassword(bytes, '1234');
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> writeForSession(String filePath, Uint8List plaintext) async {
    final bytes = corruptSessionWrites
        ? Uint8List.fromList([...plaintext, 0xff])
        : plaintext;
    data[filePath] = await encryptBytesWithPassword(bytes, '1234');
  }
}

Future<Note> _lockedNote(Database database, {required int id}) async {
  final note = Note(
    id: id,
    locked: true,
    title: 'Locked',
    content: await encrypt(_content('secret'), '1234'),
    createdAt: DateTime.utc(2026, 7, 20),
    updatedAt: DateTime.utc(2026, 7, 20),
  );
  await _insertNote(database, note);
  await note.unlock('1234');
  return note;
}

NoteImage _image(String source) => NoteImage(
  src: source,
  size: 4,
  index: 0,
  aspectRatio: '1:1',
  lastModified: '2026-07-20T00:00:00.000Z',
);

String _content(String text) => jsonEncode([
  {'insert': '$text\n'},
]);

Future<void> _insertNote(Database database, Note note) async {
  final row = await note.toJsonAsync();
  row['id'] = note.id;
  await database.insert('note', row);
}
