import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unlock repair runs image thumbnails and sketch previews', () async {
    final calls = <String>[];

    final result = await SketchPreviewRepairService.repairDecryptedAttachments(
      Note(id: 1, locked: true),
      repairThumbnails: (_) async {
        calls.add('thumbnails');
        return true;
      },
      repairSketches: (_) async {
        calls.add('sketches');
        return const SketchPreviewRepairBatchResult();
      },
    );

    expect(result.changed, isTrue);
    expect(calls, ['thumbnails', 'sketches']);
  });
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init();
    SketchPreviewRepairService.resetStartupAttempts();
    SketchPreviewRepairService.resetTestOverrides();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE note (
        id INTEGER PRIMARY KEY,
        title TEXT,
        content TEXT,
        locked INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT,
        attachments TEXT
      )
    ''');
    AppState.db = database;
  });

  tearDown(() async {
    SketchPreviewRepairService.resetTestOverrides();
    await database.close();
  });

  test('attachment CAS changes no other note columns or timestamp', () async {
    const originalAttachments = '[{"type":"image","data":{}}]';
    await _insertNote(
      database,
      title: 'Current title',
      content: 'Current content',
      updatedAt: '2026-07-19T10:00:00.000',
      attachments: originalAttachments,
    );

    final updated = await Note.updateAttachmentsIfUnchanged(
      id: 1,
      expectedUpdatedAt: '2026-07-19T10:00:00.000',
      expectedAttachments: originalAttachments,
      attachments: '[]',
    );

    expect(updated, isTrue);
    final row = (await database.query('note')).single;
    expect(row['title'], 'Current title');
    expect(row['content'], 'Current content');
    expect(row['updated_at'], '2026-07-19T10:00:00.000');
    expect(row['attachments'], '[]');
  });

  test('attachment CAS rejects a concurrent ordinary note edit', () async {
    const attachments = '[]';
    await _insertNote(
      database,
      title: 'Snapshot title',
      content: 'Snapshot content',
      updatedAt: 'old',
      attachments: attachments,
    );
    await database.update(
      'note',
      {'title': 'User title', 'content': 'User content', 'updated_at': 'new'},
      where: 'id = ?',
      whereArgs: [1],
    );

    final updated = await Note.updateAttachmentsIfUnchanged(
      id: 1,
      expectedUpdatedAt: 'old',
      expectedAttachments: attachments,
      attachments: '["repaired"]',
    );

    expect(updated, isFalse);
    final row = (await database.query('note')).single;
    expect(row['title'], 'User title');
    expect(row['content'], 'User content');
    expect(row['attachments'], attachments);
  });

  test('attachment CAS rejects sync changes with the same timestamp', () async {
    await _insertNote(
      database,
      title: 'Title',
      content: 'Content',
      updatedAt: 'same',
      attachments: '[]',
    );
    await database.update(
      'note',
      {'attachments': '["synced"]'},
      where: 'id = ?',
      whereArgs: [1],
    );

    final updated = await Note.updateAttachmentsIfUnchanged(
      id: 1,
      expectedUpdatedAt: 'same',
      expectedAttachments: '[]',
      attachments: '["repaired"]',
    );

    expect(updated, isFalse);
    expect((await database.query('note')).single['attachments'], '["synced"]');
  });

  test('repair retries from current row after a concurrent edit', () async {
    await _insertSketchNote(database);
    var attempts = 0;
    final deleted = <String>[];
    final cached = <String>[];

    final repaired = await SketchPreviewRepairService.repairNoteById(
      1,
      repair: (note, _) async {
        attempts++;
        note.sketches.single.previewImage = '/tmp/generated-$attempts.jpg';
        if (attempts == 1) {
          await database.update(
            'note',
            {
              'title': 'User title',
              'content': 'User content',
              'updated_at': 'new',
            },
            where: 'id = ?',
            whereArgs: [1],
          );
        }
        return const SketchPreviewRepairBatchResult(changed: true);
      },
      cachePreviews: (paths) async => cached.addAll(paths),
      deleteGeneratedPreviews: (paths) async => deleted.addAll(paths),
    );

    expect(repaired.isComplete, isTrue);
    expect(attempts, 2);
    expect(deleted, ['/tmp/generated-1.jpg']);
    expect(cached, ['/tmp/generated-2.jpg']);

    final row = (await database.query('note')).single;
    expect(row['title'], 'User title');
    expect(row['content'], 'User content');
    expect(row['updated_at'], 'new');
    final attachments = jsonDecode(row['attachments'] as String) as List;
    expect(attachments.single['data']['previewImage'], '/tmp/generated-2.jpg');
  });

  test('repair reports repeated conflicts and cleans every orphan', () async {
    await _insertSketchNote(database);
    var attempts = 0;
    final deleted = <String>[];

    final repaired = await SketchPreviewRepairService.repairNoteById(
      1,
      repair: (note, _) async {
        attempts++;
        note.sketches.single.previewImage = '/tmp/generated-$attempts.jpg';
        await database.update(
          'note',
          {'updated_at': 'conflict-$attempts'},
          where: 'id = ?',
          whereArgs: [1],
        );
        return const SketchPreviewRepairBatchResult(changed: true);
      },
      cachePreviews: (_) async {},
      deleteGeneratedPreviews: (paths) async => deleted.addAll(paths),
    );

    expect(repaired.status, SketchPreviewRepairStatus.retryableFailure);
    expect(attempts, 2);
    expect(deleted, ['/tmp/generated-1.jpg', '/tmp/generated-2.jpg']);
  });

  test('locked rows repair only through the post-unlock path', () async {
    await _insertSketchNote(database, locked: true);
    var repairs = 0;

    expect(
      await SketchPreviewRepairService.repairNoteById(
        1,
        repair: (_, _) async {
          repairs++;
          return const SketchPreviewRepairBatchResult(changed: true);
        },
      ),
      isA<SketchPreviewRepairResult>().having(
        (result) => result.status,
        'status',
        SketchPreviewRepairStatus.deferredLocked,
      ),
    );
    expect(repairs, 0);

    expect(
      await SketchPreviewRepairService.repairNoteById(
        1,
        allowLocked: true,
        repair: (_, _) async {
          repairs++;
          return const SketchPreviewRepairBatchResult();
        },
      ),
      isA<SketchPreviewRepairResult>().having(
        (result) => result.isComplete,
        'complete',
        isTrue,
      ),
    );
    expect(repairs, 1);
  });

  test('eligible preview generation failure remains retryable', () async {
    final sketch = SketchData(
      backgroundImage: '/local/background.jpg',
      previewImage: '/local/old-preview.jpg',
      blurredThumbnail: 'old-thumbnail',
      strokes: [
        SketchStroke(points: '1,1,0.5;2,2,0.5;', color: Colors.black, size: 2),
      ],
    );
    final note = Note(attachments: [NoteAttachment.sketch(sketch)]);

    final result = await SketchPreviewRepairService.repairNote(
      note,
      pathExists: (_) async => true,
      generatePreview: (_) async => false,
    );

    expect(result.hasRetryableFailure, isTrue);
    expect(result.changed, isTrue);
    expect(result.failedSketchKeys, hasLength(1));
    expect(sketch.previewImage, isNull);
    expect(sketch.blurredThumbnail, isNull);
  });

  test('image-only startup scope ignores ordinary sketches', () async {
    final result = await SketchPreviewRepairService.repairNote(
      Note(
        attachments: [
          NoteAttachment.sketch(
            SketchData(
              strokes: [
                SketchStroke(points: '1,1,0.5;', color: Colors.black, size: 2),
              ],
            ),
          ),
        ],
      ),
      scope: SketchPreviewRepairScope.imageSketchesOnly,
    );

    expect(result.changed, isFalse);
    expect(result.hasRetryableFailure, isFalse);
  });

  test(
    'ordinary sketches are repaired by default with restored metadata',
    () async {
      final stroke = SketchStroke(
        points: '1,1,0.5;2,2,0.5;',
        color: Colors.deepPurple,
        size: 3,
        tool: SketchTool.highlighter,
      );
      final sketch = SketchData(
        strokesFilePath: '/local/strokes.json',
        strokes: [stroke],
        backgroundColor: Colors.amber,
        pagePattern: PagePattern.dotGrid,
        aspectRatio: 123,
      );
      var generations = 0;

      final result = await SketchPreviewRepairService.repairNote(
        Note(attachments: [NoteAttachment.sketch(sketch)]),
        pathExists: (path) async => path == '/local/preview.jpg',
        generatePreview: (target) async {
          generations++;
          expect(target.strokes.single.toString(), stroke.toString());
          expect(target.backgroundColor.toARGB32(), Colors.amber.toARGB32());
          expect(target.pagePattern, PagePattern.dotGrid);
          target.aspectRatio = kSketchA4Size.width / kSketchA4Size.height;
          target.previewImage = '/local/preview.jpg';
          target.blurredThumbnail = 'tiny-thumbnail';
          return true;
        },
      );

      expect(generations, 1);
      expect(result.changed, isTrue);
      expect(result.hasRetryableFailure, isFalse);
      expect(result.completedSketchKeys, hasLength(1));
      expect(sketch.aspectRatio, kSketchA4Size.width / kSketchA4Size.height);
    },
  );

  test('missing ordinary strokes source remains retryable', () async {
    final sketch = SketchData(strokesFilePath: '/missing/strokes.json');

    final result = await SketchPreviewRepairService.repairNote(
      Note(attachments: [NoteAttachment.sketch(sketch)]),
      pathExists: (_) async => false,
    );

    expect(result.hasRetryableFailure, isTrue);
    expect(result.failedSketchKeys, hasLength(1));
    expect(result.completedSketchKeys, isEmpty);
  });

  test('verified empty ordinary sketch completes without a preview', () async {
    final sketch = SketchData(
      strokesFilePath: '/local/empty.json',
      strokesHydrated: true,
    );

    final result = await SketchPreviewRepairService.repairNote(
      Note(attachments: [NoteAttachment.sketch(sketch)]),
      generatePreview: (_) async => throw StateError('must not render'),
    );

    expect(result.hasRetryableFailure, isFalse);
    expect(result.completedSketchKeys, hasLength(1));
    expect(result.changed, isFalse);
  });

  test('verified current source overlays the fresh guarded row', () async {
    final sourceSketch = SketchData(
      strokesFilePath: '/local/strokes.json',
      strokes: [
        SketchStroke(points: '4,5,0.5;6,7,0.5;', color: Colors.teal, size: 4),
      ],
      backgroundColor: Colors.orange,
      pagePattern: PagePattern.grid,
    );
    final targetSketch = SketchData(strokesFilePath: '/local/strokes.json');

    await SketchPreviewRepairService.overlayVerifiedUnlockedSources(
      Note(attachments: [NoteAttachment.sketch(sourceSketch)]),
      Note(attachments: [NoteAttachment.sketch(targetSketch)]),
    );

    expect(targetSketch.hasHydratedStrokeSource, isTrue);
    expect(
      targetSketch.strokes.single.toString(),
      sourceSketch.strokes.single.toString(),
    );
    expect(targetSketch.backgroundColor.toARGB32(), Colors.orange.toARGB32());
    expect(targetSketch.pagePattern, PagePattern.grid);
  });

  test(
    'verified background retry adopts only its tracked remote source',
    () async {
      await FileSyncTrack.createTable(database);
      await FileSyncTrack(
        noteId: 1,
        localPath: '/local/background.jpg',
        remotePath: 'https://example.com/background.jpg',
      ).save();
      final sourceSketch = SketchData(
        strokesFilePath: '/local/strokes.json',
        strokes: [
          SketchStroke(points: '4,5,0.5;', color: Colors.teal, size: 4),
        ],
        backgroundImage: '/local/background.jpg',
      );
      final targetSketch = SketchData(
        strokesFilePath: '/local/strokes.json',
        backgroundImage: 'https://example.com/background.jpg',
      );

      await SketchPreviewRepairService.overlayVerifiedUnlockedSources(
        Note(attachments: [NoteAttachment.sketch(sourceSketch)]),
        Note(attachments: [NoteAttachment.sketch(targetSketch)]),
      );

      expect(targetSketch.backgroundImage, '/local/background.jpg');
    },
  );

  test('partial repair persists successes but keeps note pending', () async {
    await _insertSketchNote(database);

    final result = await SketchPreviewRepairService.repairNoteById(
      1,
      repair: (note, _) async {
        note.sketches.single.previewImage = '/tmp/repaired-preview.jpg';
        return const SketchPreviewRepairBatchResult(
          changed: true,
          hasRetryableFailure: true,
          completedSketchKeys: {'repaired'},
          failedSketchKeys: {'failed'},
        );
      },
      cachePreviews: (_) async {},
      deleteGeneratedPreviews: (_) async {},
    );

    expect(result.status, SketchPreviewRepairStatus.retryableFailure);
    expect(result.completedSketchKeys, {'repaired'});
    final attachments =
        jsonDecode(
              (await database.query('note')).single['attachments'] as String,
            )
            as List;
    expect(
      attachments.single['data']['previewImage'],
      '/tmp/repaired-preview.jpg',
    );
  });

  test('completed sketch keys skip valid preview regeneration', () async {
    final sketch = SketchData(
      backgroundImage: '/local/background.jpg',
      strokes: [
        SketchStroke(points: '1,1,0.5;2,2,0.5;', color: Colors.black, size: 2),
      ],
    );
    final note = Note(attachments: [NoteAttachment.sketch(sketch)]);
    var generations = 0;

    final first = await SketchPreviewRepairService.repairNote(
      note,
      pathExists: (_) async => true,
      generatePreview: (target) async {
        generations++;
        target.previewImage = '/local/current-preview.jpg';
        target.blurredThumbnail = 'thumbnail';
        return true;
      },
    );
    final second = await SketchPreviewRepairService.repairNote(
      note,
      completedSketchKeys: first.completedSketchKeys,
      pathExists: (_) async => true,
      generatePreview: (_) async {
        generations++;
        return false;
      },
    );

    expect(generations, 1);
    expect(second.hasRetryableFailure, isFalse);
    expect(second.completedSketchKeys, first.completedSketchKeys);
  });

  test('local failures retry three times then resolve with placeholder', () {
    const failure = SketchPreviewRepairResult(
      status: SketchPreviewRepairStatus.retryableFailure,
      sourceSignature: 'source-a',
    );

    final first = SketchPreviewRepairService.advanceLocalProgress(
      previous: null,
      result: failure,
    );
    final second = SketchPreviewRepairService.advanceLocalProgress(
      previous: first,
      result: failure,
    );
    final third = SketchPreviewRepairService.advanceLocalProgress(
      previous: second,
      result: failure,
    );

    expect(first.state, SketchPreviewLocalProgressState.pending);
    expect(second.state, SketchPreviewLocalProgressState.pending);
    expect(
      third.state,
      SketchPreviewLocalProgressState.resolvedWithPlaceholder,
    );
    expect(third.failedAttempts, 3);

    final changedSource = SketchPreviewRepairService.advanceLocalProgress(
      previous: third,
      result: const SketchPreviewRepairResult(
        status: SketchPreviewRepairStatus.retryableFailure,
        sourceSignature: 'source-b',
      ),
    );
    expect(changedSource.state, SketchPreviewLocalProgressState.pending);
    expect(changedSource.failedAttempts, 1);

    final recovered = SketchPreviewRepairService.advanceLocalProgress(
      previous: second,
      result: const SketchPreviewRepairResult(
        status: SketchPreviewRepairStatus.repaired,
        sourceSignature: 'source-a',
        completedSketchKeys: {'sketch-a'},
      ),
    );
    expect(recovered.state, SketchPreviewLocalProgressState.complete);
    expect(recovered.failedAttempts, 0);
    expect(recovered.completedSketchKeys, {'sketch-a'});
  });

  test('failed startup repair does not write the global marker', () async {
    await _insertSketchNote(
      database,
      backgroundPath: '/definitely-missing/background.jpg',
    );

    await SketchPreviewRepairService.runIfNeeded();

    final prefs = await AppState.prefs;
    expect(prefs.getInt('sketch_preview_renderer_version'), isNull);
    final attachments =
        jsonDecode(
              (await database.query('note')).single['attachments'] as String,
            )
            as List;
    expect(attachments.single['data']['previewImage'], isNull);
  });

  test(
    'persistent startup failure is bounded and completes with placeholder',
    () async {
      await _insertSketchNote(
        database,
        backgroundPath: '/definitely-missing/background.jpg',
      );

      for (var attempt = 0; attempt < 3; attempt++) {
        SketchPreviewRepairService.resetStartupAttempts();
        await SketchPreviewRepairService.runIfNeeded();
      }

      final prefs = await AppState.prefs;
      expect(
        prefs.getInt('sketch_preview_renderer_version'),
        SketchPreviewRepairService.currentVersion,
      );
    },
  );

  test(
    'first-unlock marker skips complete previews but retries missing ones',
    () async {
      var complete = false;
      var repairs = 0;

      Future<bool> repair() async {
        repairs++;
        complete = true;
        return true;
      }

      expect(
        await SketchPreviewRepairService.runFirstUnlockRepair(
          noteId: 7,
          previewIsComplete: () async => complete,
          repair: repair,
        ),
        isTrue,
      );
      expect(repairs, 1);

      expect(
        await SketchPreviewRepairService.runFirstUnlockRepair(
          noteId: 7,
          previewIsComplete: () async => complete,
          repair: repair,
        ),
        isTrue,
      );
      expect(repairs, 1);

      complete = false;
      expect(
        await SketchPreviewRepairService.runFirstUnlockRepair(
          noteId: 7,
          previewIsComplete: () async => complete,
          repair: repair,
        ),
        isTrue,
      );
      expect(repairs, 2);
    },
  );

  test(
    'old unlock marker does not suppress a missing ordinary preview',
    () async {
      final prefs = await AppState.prefs;
      await prefs.setStringList(
        'sketch_preview_renderer_v2_unlocked_note_ids',
        ['41'],
      );
      final sketch = SketchData(
        strokesFilePath: '/local/strokes.json',
        strokes: [
          SketchStroke(
            points: '1,1,0.5;2,2,0.5;',
            color: Colors.black,
            size: 2,
          ),
        ],
      );
      final note = Note(
        id: 41,
        locked: true,
        attachments: [NoteAttachment.sketch(sketch)],
      );
      var repairs = 0;

      final repaired = await SketchPreviewRepairService.runFirstUnlockRepair(
        noteId: 41,
        previewIsComplete: () =>
            SketchPreviewRepairService.hasCompleteLocalAttachmentPreviews(
              note,
              pathExists: (path) async => path == '/local/preview.jpg',
            ),
        repair: () async {
          repairs++;
          sketch.previewImage = '/local/preview.jpg';
          sketch.blurredThumbnail = 'tiny-thumbnail';
          return true;
        },
      );

      expect(repaired, isTrue);
      expect(repairs, 1);
    },
  );

  test(
    'synced locked ordinary sketch repairs on first successful unlock',
    () async {
      const password = '2468';
      final directory = await Directory.systemTemp.createTemp(
        'locked-ordinary-sketch-',
      );
      final strokesPath = '${directory.path}/strokes.json';
      final previewPath = '${directory.path}/preview.jpg';
      final stroke = SketchStroke(
        points: '10,20,0.5;30,40,0.5;',
        color: Colors.indigo,
        size: 6,
        tool: SketchTool.brush,
      );
      try {
        final protectedStrokes = await encryptBytesWithPassword(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'strokes': [stroke.toString()],
                'bgColor': Colors.lime.toARGB32(),
                'pagePattern': PagePattern.singleLine.name,
                'aspectRatio': kSketchA4Size.width / kSketchA4Size.height,
              }),
            ),
          ),
          password,
        );
        await File(strokesPath).writeAsBytes(protectedStrokes);

        final syncedAttachment = NoteAttachment.sketch(
          SketchData(
            strokesFilePath: strokesPath,
            previewImage: 'https://old-client.example/preview.jpg',
            blurredThumbnail: 'remote-thumbnail-must-be-discarded',
          ),
        );
        NoteSyncService.discardRemoteAttachmentPresentation(syncedAttachment);
        expect(syncedAttachment.sketch!.previewImage, isNull);
        expect(syncedAttachment.sketch!.blurredThumbnail, isNull);
        expect(
          await SketchStrokesFileService.hydrate(syncedAttachment.sketch!),
          SketchStrokesLoadResult.passwordProtected,
        );

        final encryptedContent = await encrypt(
          '[{"insert":"locked note\\n"}]',
          password,
        );
        final attachments = jsonEncode([syncedAttachment.toJson()]);
        await _insertNote(
          database,
          title: 'Locked sketch',
          content: encryptedContent,
          updatedAt: '2026-07-19T10:00:00.000',
          attachments: attachments,
          locked: true,
        );
        final note = Note(
          id: 1,
          title: 'Locked sketch',
          content: encryptedContent,
          locked: true,
          updatedAt: DateTime.parse('2026-07-19T10:00:00.000'),
          attachments: [syncedAttachment],
        );
        var generations = 0;
        SketchPreviewRepairService.previewGeneratorOverride = (target) async {
          generations++;
          expect(target.strokes.single.toString(), stroke.toString());
          expect(target.backgroundColor.toARGB32(), Colors.lime.toARGB32());
          expect(target.pagePattern, PagePattern.singleLine);
          await File(previewPath).writeAsBytes([1, 2, 3]);
          target.previewImage = previewPath;
          target.blurredThumbnail = 'local-blurred-thumbnail';
          target.aspectRatio = kSketchA4Size.width / kSketchA4Size.height;
          return true;
        };

        await note.unlock(password);

        expect(note.unlocked, isTrue);
        expect(generations, 1);
        expect(note.sketches.single.hasHydratedStrokeSource, isTrue);
        expect(note.sketches.single.previewImage, previewPath);
        expect(
          note.sketches.single.blurredThumbnail,
          'local-blurred-thumbnail',
        );
        final row = (await database.query('note')).single;
        expect(row['updated_at'], '2026-07-19T10:00:00.000');
        final storedAttachments =
            jsonDecode(row['attachments'] as String) as List<dynamic>;
        final storedSketch =
            (storedAttachments.single as Map<String, dynamic>)['data']
                as Map<String, dynamic>;
        expect(storedSketch['previewImage'], previewPath);
        expect(storedSketch['blurredThumbnail'], 'local-blurred-thumbnail');
        expect(
          (await AppState.prefs).getStringList(
            'sketch_preview_renderer_v2_unlocked_note_ids',
          ),
          ['1'],
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'completion rejects unhydrated and quarantined ordinary sources',
    () async {
      final unhydrated = SketchData(
        strokesFilePath: '/local/strokes.json',
        previewImage: '/local/preview.jpg',
        blurredThumbnail: 'tiny-thumbnail',
      );
      final quarantined = SketchData(
        strokesFilePath: '/local/quarantined.json',
        previewImage: '/local/preview.jpg',
        blurredThumbnail: 'tiny-thumbnail',
        strokesHydrated: true,
      )..markLegacyMigrationFailed('invalid legacy source');

      expect(
        await SketchPreviewRepairService.hasCompleteLocalAttachmentPreviews(
          Note(attachments: [NoteAttachment.sketch(unhydrated)]),
          pathExists: (_) async => true,
        ),
        isFalse,
      );
      expect(
        await SketchPreviewRepairService.hasCompleteLocalAttachmentPreviews(
          Note(attachments: [NoteAttachment.sketch(quarantined)]),
          pathExists: (_) async => true,
        ),
        isFalse,
      );
    },
  );

  test('startup version scan remains image-sketch only', () async {
    await _insertSketchNote(database, backgroundPath: null);

    await SketchPreviewRepairService.runIfNeeded();

    final prefs = await AppState.prefs;
    expect(
      prefs.getInt('sketch_preview_renderer_version'),
      SketchPreviewRepairService.currentVersion,
    );
  });

  test('incorrect PIN cannot reach first-unlock preview repair', () async {
    final encryptedContent = await encrypt('[{"insert":"secret\\n"}]', '1234');
    await _insertNote(
      database,
      title: 'Locked',
      content: encryptedContent,
      updatedAt: 'old',
      attachments: '[]',
      locked: true,
    );
    final note = Note(
      id: 1,
      locked: true,
      title: 'Locked',
      content: encryptedContent,
      updatedAt: DateTime.parse('2026-07-19T10:00:00.000'),
    );

    await expectLater(
      note.unlock('wrong'),
      throwsA(isA<NoteUnlockException>()),
    );
    expect(note.unlocked, isFalse);
    final prefs = await AppState.prefs;
    expect(
      prefs.getStringList('sketch_preview_renderer_v2_unlocked_note_ids'),
      isNull,
    );

    await note.unlock('1234');
    expect(note.unlocked, isTrue);
    expect(
      prefs.getStringList('sketch_preview_renderer_v2_unlocked_note_ids'),
      ['1'],
    );
  });
}

Future<void> _insertNote(
  Database database, {
  required String title,
  required String content,
  required String updatedAt,
  required String attachments,
  bool locked = false,
}) {
  return database.insert('note', {
    'id': 1,
    'title': title,
    'content': content,
    'locked': locked ? 1 : 0,
    'updated_at': updatedAt,
    'attachments': attachments,
  });
}

Future<void> _insertSketchNote(
  Database database, {
  bool locked = false,
  String? backgroundPath = '/tmp/background.jpg',
}) {
  final attachments = jsonEncode([
    {
      'type': 'sketch',
      'data': {
        'strokesFilePath': '/tmp/strokes.json',
        'aspectRatio': 1.0,
        'previewImage': '/tmp/old-preview.jpg',
        'backgroundImage': backgroundPath,
      },
    },
  ]);
  return _insertNote(
    database,
    title: 'Snapshot title',
    content: 'Snapshot content',
    updatedAt: 'old',
    attachments: attachments,
    locked: locked,
  );
}
