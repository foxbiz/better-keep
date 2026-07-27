import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:better_keep/services/import/google_keep_import_service.dart';
import 'package:better_keep/services/import/google_keep_takeout_parser.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = GoogleKeepTakeoutParser();

  group('GoogleKeepTakeoutParser', () {
    test('parses text, checklist, metadata, labels, and attachments', () {
      final result = parser.parseEntries([
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
      expect(text.title, 'Private idea');
      expect(text.plainText, 'First line\nSecond line');
      expect(text.labels, ['Ideas']);
      expect(text.color, 'BLUE');
      expect(text.pinned, isTrue);
      expect(text.attachments.single.archivePath, 'Takeout/Keep/photo.png');
      expect(text.createdAt.toUtc().microsecondsSinceEpoch, 1700000000000000);

      final checklist = result.notes.singleWhere(
        (note) => note.title == 'Morning',
      );
      expect(checklist.archived, isTrue);
      expect(checklist.plainText, 'Stretch\nJournal');
      expect(checklist.delta[1]['attributes'], {'list': 'checked'});
      expect(checklist.delta[3]['attributes'], {'list': 'unchecked'});
    });

    test('reports missing and unsupported attachments without losing note', () {
      final result = parser.parseEntries([
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
    });

    test('produces a stable fingerprint when JSON keys are reordered', () {
      final first = parser.parseEntries([
        _jsonEntry('Keep/First.json', {
          'title': 'Same',
          'textContent': 'Body',
          'isPinned': false,
        }),
      ]);
      final second = parser.parseEntries([
        _jsonEntry('Keep/Second.json', {
          'isPinned': false,
          'textContent': 'Body',
          'title': 'Same',
        }),
      ]);

      expect(first.notes.single.fingerprint, second.notes.single.fingerprint);
    });

    test('rejects unsafe archive paths', () {
      expect(
        () => parser.parseEntries([
          _jsonEntry('../Keep/unsafe.json', {
            'title': 'Unsafe',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ]),
        throwsA(isA<KeepImportValidationException>()),
      );
    });

    test('rejects archives that exceed expanded size limit', () {
      expect(
        () => parser.parseEntries([
          KeepArchiveEntry(path: 'Keep/large.json', bytes: Uint8List(20)),
        ], options: const KeepImportOptions(maxUncompressedBytes: 10)),
        throwsA(isA<KeepImportValidationException>()),
      );
    });

    test('honors cancellation before parsing a record', () {
      final token = KeepImportCancellationToken()..cancel();
      expect(
        () => parser.parseEntries([
          _jsonEntry('Keep/Note.json', {
            'title': 'Cancelled',
            'textContent': 'Body',
            'isPinned': false,
          }),
        ], cancellationToken: token),
        throwsA(isA<KeepImportCancelled>()),
      );
    });

    test('rejects a ZIP containing a traversal entry', () {
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
      final zip = ZipEncoder().encodeBytes(archive);

      expect(
        () => parser.parseZipBytes(zip),
        throwsA(isA<KeepImportValidationException>()),
      );
    });
  });

  group('GoogleKeepImportService', () {
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
        final parsed = parser.parseZipBytes(archive);
        final persistence = _FakePersistence(
          existing: {parsed.notes.first.fingerprint},
        );
        final service = GoogleKeepImportService(
          parser: parser,
          persistence: persistence,
        );

        final report = await service.importZip(bytes: archive);

        expect(report.imported, 0);
        expect(report.skipped, 2);
        expect(persistence.committed, isEmpty);
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

      final report = await service.importZip(bytes: archive);

      expect(persistence.commitCalls, 1);
      expect(persistence.committed, hasLength(2));
      expect(report.imported, 2);
      expect(report.warnings, 1);
    });

    test('does not call persistence after cancellation', () async {
      final persistence = _FakePersistence();
      final service = GoogleKeepImportService(persistence: persistence);
      final token = KeepImportCancellationToken()..cancel();

      await expectLater(
        service.importZip(
          bytes: _zip([
            _jsonEntry('Keep/One.json', {
              'title': 'One',
              'textContent': 'Body',
              'isPinned': false,
            }),
          ]),
          cancellationToken: token,
        ),
        throwsA(isA<KeepImportCancelled>()),
      );
      expect(persistence.commitCalls, 0);
    });
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

class _FakePersistence implements KeepImportPersistence {
  final Set<String> existing;
  final List<KeepImportIssue> commitIssues;
  final List<KeepNoteDraft> committed = [];
  int commitCalls = 0;

  _FakePersistence({this.existing = const {}, this.commitIssues = const []});

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
    committed.addAll(drafts);
    return KeepPersistenceResult(imported: drafts.length, issues: commitIssues);
  }
}
