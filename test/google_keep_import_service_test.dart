import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/import/google_keep_import_service.dart';
import 'package:better_keep/services/import/google_keep_takeout_parser.dart';
import 'package:better_keep/services/import/import_fingerprint_store.dart';
import 'package:better_keep/services/import/keep_archive_input.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const parser = GoogleKeepTakeoutParser();

  setUpAll(sqfliteFfiInit);

  group('GoogleKeepTakeoutParser', () {
    test(
      'parses text, checklist, metadata, labels, and lazy attachments',
      () async {
        final result = await parser.parseEntries([
          _jsonEntry('Takeout/Keep/Text note.json', {
            'title': 'Private idea',
            'textContent': 'First line\nSecond line',
            'color': 'BLUE',
            'isPinned': true,
            'isArchived': false,
            'isTrashed': false,
            'createdTimestampUsec': '1700000000000000',
            'userEditedTimestampUsec': '1700000100000000',
            'labels': [
              {'name': 'Ideas'},
            ],
            'attachments': [
              {'filePath': 'photo.png', 'mimetype': 'image/png'},
            ],
          }),
          _jsonEntry('Takeout/Keep/Checklist.json', {
            'title': 'Morning',
            'listContent': [
              {'text': 'Stretch', 'isChecked': true},
              {'text': 'Journal', 'isChecked': false},
            ],
            'isPinned': false,
            'isArchived': true,
            'isTrashed': false,
          }),
          KeepArchiveEntry(
            path: 'Takeout/Keep/photo.png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ]);

        expect(result.discovered, 2);
        expect(result.notes, hasLength(2));
        final text = result.notes.singleWhere(
          (note) => note.title == 'Private idea',
        );
        expect(text.plainText, 'First line\nSecond line');
        expect(text.labels, ['Ideas']);
        expect(text.color, 'BLUE');
        expect(text.pinned, isTrue);
        expect(text.attachments.single.archivePath, 'Takeout/Keep/photo.png');
        expect(text.attachments.single.source.byteLength, 3);
        expect(
          await text.attachments.single.source.read(),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(text.createdAt.toUtc().microsecondsSinceEpoch, 1700000000000000);

        final checklist = result.notes.singleWhere(
          (note) => note.title == 'Morning',
        );
        expect(checklist.archived, isTrue);
        expect(checklist.plainText, 'Stretch\nJournal');
        expect(checklist.delta[1]['attributes'], {'list': 'checked'});
        expect(checklist.delta[3]['attributes'], {'list': 'unchecked'});

        await result.dispose();
        await result.dispose();
        expect(() => text.attachments.single.source.read(), throwsStateError);
      },
    );

    test(
      'reports missing and unsupported attachments without losing note',
      () async {
        final result = await parser.parseEntries([
          _jsonEntry('Keep/Attachments.json', {
            'title': 'Attachments',
            'textContent': 'Body',
            'isPinned': false,
            'attachments': [
              {'filePath': 'missing.jpg', 'mimetype': 'image/jpeg'},
              {
                'filePath': 'drawing.bin',
                'mimetype': 'application/vnd.google-apps.drawing',
              },
            ],
          }),
          KeepArchiveEntry(
            path: 'Keep/drawing.bin',
            bytes: Uint8List.fromList([4, 5, 6]),
          ),
        ]);

        expect(result.notes, hasLength(1));
        expect(result.notes.single.attachments, isEmpty);
        expect(
          result.issues.map((issue) => issue.kind),
          containsAll([
            KeepImportIssueKind.warning,
            KeepImportIssueKind.unsupported,
          ]),
        );
        await result.dispose();
      },
    );

    test(
      'produces a stable fingerprint when JSON keys are reordered',
      () async {
        final first = await parser.parseEntries([
          _jsonEntry('Keep/First.json', {
            'title': 'Same',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ]);
        final second = await parser.parseEntries([
          _jsonEntry('Keep/Second.json', {
            'isPinned': false,
            'textContent': 'Body',
            'title': 'Same',
          }),
        ]);

        expect(first.notes.single.fingerprint, second.notes.single.fingerprint);
        await first.dispose();
        await second.dispose();
      },
    );

    test('rejects unsafe archive paths and expanded-size overflow', () async {
      await expectLater(
        parser.parseEntries([
          _jsonEntry('../Keep/unsafe.json', {
            'title': 'Unsafe',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ]),
        throwsA(isA<KeepImportValidationException>()),
      );
      await expectLater(
        parser.parseEntries([
          KeepArchiveEntry(path: 'Keep/large.json', bytes: Uint8List(20)),
        ], options: const KeepImportOptions(maxUncompressedBytes: 10)),
        throwsA(isA<KeepImportValidationException>()),
      );
    });

    test('checks cancellation between JSON records', () async {
      final token = KeepImportCancellationToken();
      var yields = 0;
      final cancellableParser = GoogleKeepTakeoutParser(
        yieldControl: () async {
          yields++;
          if (yields == 2) token.cancel();
        },
      );

      await expectLater(
        cancellableParser.parseEntries([
          _jsonEntry('Keep/One.json', {
            'title': 'One',
            'textContent': 'Body',
            'isPinned': false,
          }),
          _jsonEntry('Keep/Two.json', {
            'title': 'Two',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ], cancellationToken: token),
        throwsA(isA<KeepImportCancelled>()),
      );
      expect(yields, 2);
    });

    test('rejects a ZIP containing a traversal entry', () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            '../escape.json',
            jsonEncode({
              'title': 'Unsafe',
              'textContent': 'Body',
              'isPinned': false,
            }),
          ),
        );

      await expectLater(
        parser.parseZipBytes(ZipEncoder().encodeBytes(archive)),
        throwsA(isA<KeepImportValidationException>()),
      );
    });

    test(
      'rejects decompressed bytes that disagree with ZIP metadata',
      () async {
        final archive = _zip([
          _jsonEntry('Keep/Size mismatch.json', {
            'title': 'Size mismatch',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ]);
        _setFirstCentralDirectoryUncompressedSize(archive, 1);

        await expectLater(
          parser.parseZipBytes(archive),
          throwsA(isA<KeepImportValidationException>()),
        );
      },
    );

    test('rejects decompressed bytes with an invalid ZIP checksum', () async {
      final archive = _zip([
        _jsonEntry('Keep/Checksum mismatch.json', {
          'title': 'Checksum mismatch',
          'textContent': 'Body',
          'isPinned': false,
        }),
      ]);
      _setFirstZipEntryCrc32(archive, 0);

      await expectLater(
        parser.parseZipBytes(archive),
        throwsA(
          isA<KeepImportValidationException>().having(
            (error) => error.message,
            'message',
            contains('checksum'),
          ),
        ),
      );
    });
  });

  group('KeepArchiveInput', () {
    test(
      'rejects a declared overflow before listening to the stream',
      () async {
        var listened = false;
        final stream = Stream<List<int>>.multi((controller) {
          listened = true;
          controller.close();
        });
        final input = KeepArchiveInput.stream(stream, size: 11);

        await expectLater(
          input.read(
            maxBytes: 10,
            cancellationToken: KeepImportCancellationToken(),
          ),
          throwsA(isA<KeepImportValidationException>()),
        );
        expect(listened, isFalse);
      },
    );

    test('enforces the limit while consuming a misleading stream', () async {
      final input = KeepArchiveInput.stream(
        Stream<List<int>>.fromIterable([Uint8List(6), Uint8List(6)]),
        size: 10,
      );

      await expectLater(
        input.read(
          maxBytes: 10,
          cancellationToken: KeepImportCancellationToken(),
        ),
        throwsA(isA<KeepImportValidationException>()),
      );
    });
  });

  group('GoogleKeepImportService', () {
    test('skips only notes without a title, text, or attachments', () async {
      final persistence = _FakePersistence();
      final service = GoogleKeepImportService(persistence: persistence);
      final archive = _zip([
        _jsonEntry('Keep/Empty.json', {
          'title': '',
          'textContent': '',
          'isPinned': false,
        }),
        _jsonEntry('Keep/Title only.json', {
          'title': 'Title only',
          'textContent': '',
          'isPinned': false,
        }),
        _jsonEntry('Keep/Text only.json', {
          'title': '',
          'textContent': 'Text only',
          'isPinned': false,
        }),
        _jsonEntry('Keep/Whitespace text.json', {
          'title': '',
          'textContent': ' ',
          'isPinned': false,
        }),
        _jsonEntry('Keep/Attachment only.json', {
          'title': '',
          'textContent': '',
          'isPinned': false,
          'attachments': [
            {'filePath': 'photo.png', 'mimetype': 'image/png'},
          ],
        }),
        KeepArchiveEntry(
          path: 'Keep/photo.png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]);

      final report = await service.importZip(KeepArchiveInput.memory(archive));

      expect(report.discovered, 5);
      expect(report.imported, 4);
      expect(report.skipped, 1);
      expect(report.issues, isEmpty);
      expect(persistence.commitCalls, 1);
      expect(
        persistence.committed.map((draft) => draft.sourcePath),
        containsAll([
          'Keep/Title only.json',
          'Keep/Text only.json',
          'Keep/Whitespace text.json',
          'Keep/Attachment only.json',
        ]),
      );
    });

    test(
      'skips persisted and repeated fingerprints before committing',
      () async {
        final record = {
          'title': 'Duplicate',
          'textContent': 'Body',
          'isPinned': false,
        };
        final archive = _zip([
          _jsonEntry('Keep/One.json', record),
          _jsonEntry('Keep/Two.json', record),
        ]);
        final parsed = await parser.parseZipBytes(archive);
        final persistence = _FakePersistence(
          existing: {parsed.notes.first.fingerprint},
        );
        final service = GoogleKeepImportService(
          parser: parser,
          persistence: persistence,
        );
        await parsed.dispose();

        final report = await service.importZip(
          KeepArchiveInput.memory(archive),
        );

        expect(report.imported, 0);
        expect(report.skipped, 2);
        expect(persistence.committed, isEmpty);
      },
    );

    test(
      'does not extract duplicate attachment bytes and releases the source',
      () async {
        final source = _TrackingAttachmentSource(Uint8List.fromList([1, 2, 3]));
        final draft = _draft(
          fingerprint: 'existing',
          attachments: [
            KeepAttachmentDraft(
              archivePath: 'Keep/photo.png',
              mimeType: 'image/png',
              source: source,
            ),
          ],
        );
        final persistence = _FakePersistence(existing: {'existing'});
        final service = GoogleKeepImportService(
          parser: _FakeParser(
            KeepParseResult(notes: [draft], issues: const [], discovered: 1),
          ),
          persistence: persistence,
        );

        final report = await service.importZip(
          KeepArchiveInput.memory(Uint8List(1)),
        );

        expect(report.skipped, 1);
        expect(source.reads, 0);
        expect(source.disposals, 1);
      },
    );

    test('passes unique notes to one commit and returns its issues', () async {
      final persistence = _FakePersistence(
        commitIssues: const [
          KeepImportIssue(
            kind: KeepImportIssueKind.warning,
            source: 'Keep/One.json',
            message: 'Attachment skipped',
          ),
        ],
      );
      final service = GoogleKeepImportService(persistence: persistence);
      final archive = _zip([
        _jsonEntry('Keep/One.json', {
          'title': 'One',
          'textContent': 'Body one',
          'isPinned': false,
        }),
        _jsonEntry('Keep/Two.json', {
          'title': 'Two',
          'textContent': 'Body two',
          'isPinned': false,
        }),
      ]);

      final report = await service.importZip(KeepArchiveInput.memory(archive));

      expect(persistence.commitCalls, 1);
      expect(persistence.committed, hasLength(2));
      expect(report.imported, 2);
      expect(report.warnings, 1);
    });

    test('releases parsed sources when persistence fails', () async {
      final source = _TrackingAttachmentSource(Uint8List(1));
      final service = GoogleKeepImportService(
        parser: _FakeParser(
          KeepParseResult(
            notes: [
              _draft(
                attachments: [
                  KeepAttachmentDraft(
                    archivePath: 'Keep/audio.mp3',
                    mimeType: 'audio/mpeg',
                    source: source,
                  ),
                ],
              ),
            ],
            issues: const [],
            discovered: 1,
          ),
        ),
        persistence: _FakePersistence(failCommit: true),
      );

      await expectLater(
        service.importZip(KeepArchiveInput.memory(Uint8List(1))),
        throwsStateError,
      );
      expect(source.disposals, 1);
    });

    test('does not call persistence after cancellation', () async {
      final persistence = _FakePersistence();
      final service = GoogleKeepImportService(persistence: persistence);
      final token = KeepImportCancellationToken()..cancel();

      await expectLater(
        service.importZip(
          KeepArchiveInput.memory(
            _zip([
              _jsonEntry('Keep/One.json', {
                'title': 'One',
                'textContent': 'Body',
                'isPinned': false,
              }),
            ]),
          ),
          cancellationToken: token,
        ),
        throwsA(isA<KeepImportCancelled>()),
      );
      expect(persistence.commitCalls, 0);
    });
  });

  test(
    're-imports a fingerprint only after its note is permanently deleted',
    () async {
      final database = await _openImportDatabase();
      AppState.db = database;
      addTearDown(database.close);
      _disablePushSyncForTest();
      var timeOffset = 0;
      final persistence = DatabaseKeepImportPersistence(
        now: () =>
            DateTime.utc(2026, 1, 1).add(Duration(milliseconds: timeOffset++)),
        newId: _sequentialIds(),
      );
      final service = GoogleKeepImportService(persistence: persistence);
      final archive = _zip([
        _jsonEntry('Keep/Retry.json', {
          'title': 'Retry import',
          'textContent': 'Body',
          'isPinned': false,
        }),
      ]);
      Future<KeepImportReport> importArchive() =>
          service.importZip(KeepArchiveInput.memory(archive));

      final first = await importArchive();
      expect(first.imported, 1);
      expect(first.skipped, 0);
      final firstNoteId = Sqflite.firstIntValue(
        await database.rawQuery('SELECT id FROM ${Note.model}'),
      )!;

      final liveRetry = await importArchive();
      expect(liveRetry.imported, 0);
      expect(liveRetry.skipped, 1);

      expect(
        await database.delete(
          Note.model,
          where: 'id = ?',
          whereArgs: [firstNoteId],
        ),
        1,
      );
      expect(await database.query(ImportFingerprintStore.table), hasLength(1));

      final deletedRetry = await importArchive();
      expect(deletedRetry.imported, 1);
      expect(deletedRetry.skipped, 0);
      final noteRows = await database.query(Note.model);
      final fingerprintRows = await database.query(
        ImportFingerprintStore.table,
      );
      expect(noteRows, hasLength(1));
      expect(fingerprintRows, hasLength(1));
      final recreatedNoteId = noteRows.single['id'] as int;
      expect(recreatedNoteId, isNot(firstNoteId));
      expect(fingerprintRows.single['note_id'], recreatedNoteId);

      await database.update(
        Note.model,
        {'trashed': 1},
        where: 'id = ?',
        whereArgs: [recreatedNoteId],
      );
      final trashedRetry = await importArchive();
      expect(trashedRetry.imported, 0);
      expect(trashedRetry.skipped, 1);
    },
  );

  test(
    'database persistence stores canonical imported title content',
    () async {
      final database = await _openImportDatabase();
      AppState.db = database;
      addTearDown(database.close);
      _disablePushSyncForTest();
      final persistence = DatabaseKeepImportPersistence(
        now: () => DateTime.utc(2026, 1, 1),
        newId: _sequentialIds(),
      );

      final result = await persistence.commit(
        [
          _draft(fingerprint: 'titled', title: 'Imported title'),
          _draft(fingerprint: 'titleless', title: ''),
        ],
        source: ImportSource.googleKeepTakeout,
        cancellationToken: KeepImportCancellationToken(),
      );

      expect(result.imported, 2);
      final rows = await database.query(Note.model);
      final notes = await Future.wait(rows.map(Note.fromJsonAsync));
      final titled = notes.singleWhere(
        (note) => note.title == 'Imported title',
      );
      expect(
        titled.content,
        jsonEncode([
          {'insert': 'Imported title'},
          {
            'insert': '\n',
            'attributes': {'header': 1},
          },
          {'insert': 'Body\n'},
        ]),
      );
      final titleless = notes.singleWhere((note) => note.title == '');
      expect(
        titleless.content,
        jsonEncode([
          {'insert': 'Body\n'},
        ]),
      );
    },
  );

  test('cancellation during database saving rolls back every row', () async {
    final database = await _openImportDatabase();
    AppState.db = database;
    addTearDown(database.close);

    final token = KeepImportCancellationToken();
    final persistence = DatabaseKeepImportPersistence(
      now: () => DateTime.utc(2026, 1, 1),
      newId: _sequentialIds(),
    );

    await expectLater(
      persistence.commit(
        [
          _draft(fingerprint: 'one', labels: const ['Imported']),
          _draft(fingerprint: 'two', labels: const ['Imported']),
        ],
        source: ImportSource.googleKeepTakeout,
        cancellationToken: token,
        onProgress: (progress) {
          if (progress.phase == KeepImportPhase.saving &&
              progress.completed == 1) {
            token.cancel();
          }
        },
      ),
      throwsA(isA<KeepImportCancelled>()),
    );

    for (final table in [
      Note.model,
      Label.model,
      'sync_track',
      'label_sync_track',
      ImportFingerprintStore.table,
    ]) {
      final count = Sqflite.firstIntValue(
        await database.rawQuery('SELECT COUNT(*) FROM $table'),
      );
      expect(count, 0, reason: '$table must roll back');
    }
  });
}

KeepArchiveEntry _jsonEntry(String path, Map<String, Object?> value) =>
    KeepArchiveEntry(
      path: path,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );

Uint8List _zip(List<KeepArchiveEntry> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.addFile(ArchiveFile.bytes(entry.path, entry.bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

void _setFirstCentralDirectoryUncompressedSize(
  Uint8List archive,
  int declaredSize,
) {
  _setFirstZipHeaderUint32(
    archive,
    signature: const [0x50, 0x4b, 0x01, 0x02],
    fieldOffset: 24,
    value: declaredSize,
  );
}

void _setFirstZipEntryCrc32(Uint8List archive, int declaredCrc32) {
  _setFirstZipHeaderUint32(
    archive,
    signature: const [0x50, 0x4b, 0x03, 0x04],
    fieldOffset: 14,
    value: declaredCrc32,
  );
  _setFirstZipHeaderUint32(
    archive,
    signature: const [0x50, 0x4b, 0x01, 0x02],
    fieldOffset: 16,
    value: declaredCrc32,
  );
}

void _setFirstZipHeaderUint32(
  Uint8List archive, {
  required List<int> signature,
  required int fieldOffset,
  required int value,
}) {
  for (var index = 0; index <= archive.length - signature.length; index++) {
    var matches = true;
    for (var offset = 0; offset < signature.length; offset++) {
      if (archive[index + offset] == signature[offset]) continue;
      matches = false;
      break;
    }
    if (!matches) continue;
    ByteData.sublistView(
      archive,
    ).setUint32(index + fieldOffset, value, Endian.little);
    return;
  }
  throw StateError('ZIP header was not found');
}

KeepNoteDraft _draft({
  String fingerprint = 'fingerprint',
  String? title,
  List<String> labels = const [],
  List<KeepAttachmentDraft> attachments = const [],
}) => KeepNoteDraft(
  sourcePath: 'Keep/note.json',
  fingerprint: fingerprint,
  title: title ?? fingerprint,
  plainText: 'Body',
  delta: const [
    {'insert': 'Body'},
    {'insert': '\n'},
  ],
  labels: labels,
  color: 'DEFAULT',
  pinned: false,
  archived: false,
  trashed: false,
  createdAt: DateTime.utc(2025, 1, 1),
  updatedAt: DateTime.utc(2025, 1, 2),
  attachments: attachments,
);

Future<Database> _openImportDatabase() async {
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await Note.createTable(database);
  await Label.createTable(database);
  await NoteSyncTrack.createTable(database);
  await LabelSyncTrack.createTable(database);
  await ImportFingerprintStore.createTable(database);
  return database;
}

void _disablePushSyncForTest() {
  final previousSessionInvalid = AuthService.sessionInvalid.value;
  AuthService.sessionInvalid.value = true;
  addTearDown(() => AuthService.sessionInvalid.value = previousSessionInvalid);
}

String Function() _sequentialIds() {
  var next = 0;
  return () => 'import-${next++}';
}

class _FakePersistence implements KeepImportPersistence {
  _FakePersistence({
    this.existing = const {},
    this.commitIssues = const [],
    this.failCommit = false,
  });

  final Set<String> existing;
  final List<KeepImportIssue> commitIssues;
  final bool failCommit;
  final List<KeepNoteDraft> committed = [];
  int commitCalls = 0;

  @override
  Future<Set<String>> existingFingerprints(ImportSource source) async =>
      existing;

  @override
  Future<KeepPersistenceResult> commit(
    List<KeepNoteDraft> drafts, {
    required ImportSource source,
    required KeepImportCancellationToken cancellationToken,
    KeepImportProgressCallback? onProgress,
  }) async {
    commitCalls++;
    cancellationToken.throwIfCancelled();
    if (failCommit) throw StateError('commit failed');
    committed.addAll(drafts);
    return KeepPersistenceResult(imported: drafts.length, issues: commitIssues);
  }
}

class _FakeParser extends GoogleKeepTakeoutParser {
  _FakeParser(this.result);

  final KeepParseResult result;

  @override
  Future<KeepParseResult> parseZipBytes(
    Uint8List archiveBytes, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    return result;
  }
}

class _TrackingAttachmentSource implements KeepAttachmentSource {
  _TrackingAttachmentSource(this.bytes);

  final Uint8List bytes;
  int reads = 0;
  int disposals = 0;
  bool _disposed = false;

  @override
  int get byteLength => bytes.length;

  @override
  Future<Uint8List> read({
    KeepImportCancellationToken? cancellationToken,
  }) async {
    if (_disposed) throw StateError('source disposed');
    cancellationToken?.throwIfCancelled();
    reads++;
    return bytes;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    disposals++;
  }
}
