import 'dart:convert';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/legacy_sketch_migration_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;
  late SharedPreferences preferences;
  const password = '2468';

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
    Note.localSketchMetadataDecryptOverride = null;
    Note.localSketchMetadataEncryptOverride = null;
    Note.legacyMigrationSyncTriggerOverride = () async {};
  });

  tearDown(() async {
    Note.lockFileOperationsOverride = null;
    Note.localSketchMetadataDecryptOverride = null;
    Note.localSketchMetadataEncryptOverride = null;
    Note.legacyMigrationSyncTriggerOverride = null;
    await database.close();
  });

  test('decodes both historical legacy payload shapes', () async {
    final stroke = _stroke(Colors.red);
    final listCiphertext = await encrypt(
      jsonEncode([stroke.toString()]),
      password,
    );
    final mapCiphertext = await encrypt(
      jsonEncode({
        'strokes': [stroke.toString()],
        'bgColor': Colors.blue.toARGB32(),
        'pagePattern': PagePattern.grid.name,
      }),
      password,
    );

    final fromList = await LegacyEncryptedSketchDecoder.decode(
      ciphertext: listCiphertext,
      password: password,
      fallbackBackgroundColor: Colors.green,
      fallbackPagePattern: PagePattern.singleLine,
    );
    final fromMap = await LegacyEncryptedSketchDecoder.decode(
      ciphertext: mapCiphertext,
      password: password,
      fallbackBackgroundColor: Colors.green,
      fallbackPagePattern: PagePattern.singleLine,
    );

    expect(fromList.encodedStrokes, [stroke.toString()]);
    expect(fromList.backgroundColor.toARGB32(), Colors.green.toARGB32());
    expect(fromList.pagePattern, PagePattern.singleLine);
    expect(fromMap.encodedStrokes, [stroke.toString()]);
    expect(fromMap.backgroundColor.toARGB32(), Colors.blue.toARGB32());
    expect(fromMap.pagePattern, PagePattern.grid);
  });

  test('locked serialization never creates app-key sketch metadata', () async {
    final stroke = _stroke(Colors.red);
    var encryptionCalls = 0;
    Note.localSketchMetadataEncryptOverride = (plaintext) async {
      encryptionCalls++;
      return 'local:$plaintext';
    };
    final sketch = SketchData(
      strokesFilePath: '/docs/current.json',
      strokes: [stroke],
      backgroundColor: Colors.blue,
      pagePattern: PagePattern.grid,
      aspectRatio: 1.5,
      strokesHydrated: true,
    );
    final locked = await _lockedNote(
      id: 20,
      password: password,
      attachments: [NoteAttachment.sketch(sketch)],
    );

    final lockedData = _singleSketchData(
      await locked.serializeAttachmentsForLocalStorage(),
    );

    expect(encryptionCalls, 0);
    expect(lockedData, isNot(contains('encrypted_metadata')));
    expect(lockedData, isNot(contains('strokes')));
    expect(lockedData, isNot(contains('bgColor')));
    expect(lockedData, isNot(contains('pagePattern')));
    expect(lockedData['strokesFilePath'], '/docs/current.json');
    expect(lockedData['aspectRatio'], 1.5);
    expect(
      SketchData(encryptedMetadata: 'local-only-source').toJson(),
      isNot(contains('encrypted_metadata')),
    );

    final unlocked = Note(
      id: 21,
      attachments: [
        NoteAttachment.sketch(
          SketchData(
            strokesFilePath: '/docs/plain.json',
            strokes: [stroke],
            backgroundColor: Colors.green,
            pagePattern: PagePattern.dotGrid,
            strokesHydrated: true,
          ),
        ),
      ],
    );
    final unlockedData = _singleSketchData(
      await unlocked.serializeAttachmentsForLocalStorage(),
    );

    expect(encryptionCalls, 1);
    expect(unlockedData['encrypted_metadata'], startsWith('local:'));
    expect(unlockedData, isNot(contains('strokes')));
  });

  test(
    'locked row retains existing metadata opaque before PIN authentication',
    () async {
      final protectedContent = await encrypt(
        jsonEncode([
          {'insert': 'secret\n'},
        ]),
        password,
      );
      final note = await Note.fromJsonAsync({
        'id': 22,
        'title': 'Locked drawing',
        'content': protectedContent,
        'locked': 1,
        'attachments': jsonEncode([
          {
            'type': 'sketch',
            'data': {
              'strokesFilePath': '/docs/current.json',
              'aspectRatio': 1.25,
              'encrypted_metadata': 'opaque-app-key-ciphertext',
            },
          },
        ]),
      });

      final sketch = note.sketches.single;
      expect(sketch.strokes, isEmpty);
      expect(sketch.hasHydratedStrokeSource, isFalse);
      expect(sketch.encryptedMetadata, 'opaque-app-key-ciphertext');
      expect(sketch.requiresLegacyMigration, isTrue);
    },
  );

  test('wrong PIN never invokes the local metadata decoder', () async {
    final note = await _lockedNote(
      id: 23,
      password: password,
      attachments: [
        NoteAttachment.sketch(
          SketchData(
            strokesFilePath: '/docs/current.json',
            encryptedMetadata: 'opaque-app-key-ciphertext',
          ),
        ),
      ],
    );
    await _insertNote(database, note);
    var decoderCalls = 0;
    final fake = _FakeMigrationFiles();

    await expectLater(
      _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (ciphertext) async {
          decoderCalls++;
          return jsonEncode({'strokes': <String>[]});
        },
      ).migrate(noteId: 23, password: 'wrong'),
      throwsA(isA<FormatException>()),
    );

    expect(decoderCalls, 0);
    final reloaded = await Note.fromJsonAsync(
      (await database.query('note', where: 'id = 23')).single,
    );
    expect(reloaded.sketches.single.encryptedMetadata, isNotNull);
    expect(reloaded.sketches.single.strokes, isEmpty);
  });

  test(
    'matching protected source removes only redundant local metadata',
    () async {
      final stroke = _stroke(Colors.deepOrange);
      const currentPath = '/docs/protected-current.json';
      final currentJson = jsonEncode({
        'strokes': [stroke.toString()],
        'bgColor': Colors.blue.toARGB32(),
        'pagePattern': PagePattern.grid.name,
        'aspectRatio': 1.75,
      });
      final protectedBytes = await encryptBytesWithPassword(
        Uint8List.fromList(utf8.encode(currentJson)),
        password,
      );
      final fake = _FakeMigrationFiles(files: {currentPath: protectedBytes});
      final note = await _lockedNote(
        id: 24,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(
              strokesFilePath: currentPath,
              encryptedMetadata: 'matching-app-key-ciphertext',
              aspectRatio: 1.75,
            ),
          ),
        ],
      );
      await _insertNote(database, note);
      final originalRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 24')).single,
      );

      final result = await _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (_) async => jsonEncode({
          'strokes': [stroke.toString()],
          'bgColor': Colors.blue.toARGB32(),
          'pagePattern': PagePattern.grid.name,
        }),
      ).migrate(noteId: 24, password: password);

      expect(result.status, LegacySketchMigrationStatus.migrated);
      expect(result.migrated, isEmpty);
      expect(result.sanitized, hasLength(1));
      expect(result.shouldTriggerSync, isFalse);
      expect(result.updatedAt, isNull);
      final updatedRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 24')).single,
      );
      for (final key in originalRow.keys.where((key) => key != 'attachments')) {
        expect(updatedRow[key], originalRow[key], reason: key);
      }
      expect(
        _singleSketchData(updatedRow['attachments']! as String),
        isNot(contains('encrypted_metadata')),
      );
      expect(fake.files.keys, [currentPath]);
      expect(fake.files[currentPath], protectedBytes);
      expect(await database.query('sync_track'), isEmpty);

      final prePinReload = await Note.fromJsonAsync(updatedRow);
      expect(prePinReload.sketches.single.strokes, isEmpty);
      expect(prePinReload.sketches.single.hasEncryptedMetadata, isFalse);
      expect(prePinReload.sketches.single.hasHydratedStrokeSource, isFalse);

      final repeated = await _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (_) async =>
            throw StateError('The removed metadata must not be decoded again'),
      ).migrate(noteId: 24, password: password);
      expect(repeated.status, LegacySketchMigrationStatus.notNeeded);
      expect(
        Map<String, Object?>.from(
          (await database.query('note', where: 'id = 24')).single,
        ),
        updatedRow,
      );
    },
  );

  test(
    'metadata-only source migrates to a verified PIN-protected file',
    () async {
      final stroke = _stroke(Colors.teal);
      final note = await _lockedNote(
        id: 25,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(
              encryptedMetadata: 'only-app-key-ciphertext',
              aspectRatio: 0.8,
            ),
          ),
        ],
      );
      await _insertNote(database, note);
      final originalRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 25')).single,
      );
      final fake = _FakeMigrationFiles();

      final result = await _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (_) async => jsonEncode({
          'strokes': [stroke.toString()],
          'bgColor': Colors.purple.toARGB32(),
          'pagePattern': PagePattern.dotGrid.name,
        }),
      ).migrate(noteId: 25, password: password);

      expect(result.status, LegacySketchMigrationStatus.migrated);
      expect(result.migrated, hasLength(1));
      expect(result.shouldTriggerSync, isTrue);
      final newPath = result.migrated.single.newPath;
      final protected = fake.files[newPath]!;
      expect(isBytesPasswordEncrypted(protected), isTrue);
      final recovered =
          jsonDecode(
                utf8.decode(
                  await decryptBytesWithPassword(protected, password),
                ),
              )
              as Map<String, dynamic>;
      expect(recovered['strokes'], [stroke.toString()]);
      expect(recovered['bgColor'], Colors.purple.toARGB32());
      expect(recovered['pagePattern'], PagePattern.dotGrid.name);
      expect(recovered['aspectRatio'], 0.8);
      expect(recovered, isNot(contains('encryptedStrokes')));
      expect(recovered, isNot(contains('encrypted_metadata')));

      final updatedRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 25')).single,
      );
      final updatedData = _singleSketchData(
        updatedRow['attachments']! as String,
      );
      expect(updatedData['strokesFilePath'], newPath);
      expect(updatedData, isNot(contains('encrypted_metadata')));
      expect(updatedRow['updated_at'], isNot(originalRow['updated_at']));
      final fileTracking = (await database.query('file_sync_track')).single;
      expect(fileTracking['note_id'], 25);
      expect(fileTracking['local_path'], newPath);
      expect(fileTracking['remote_path'], isNull);
      expect(fileTracking['content_hash'], isNull);
      expect((await database.query('sync_track')).single['action'], 'upload');
    },
  );

  test(
    'failed metadata-only staging preserves the opaque source and row',
    () async {
      final stroke = _stroke(Colors.amber);
      final note = await _lockedNote(
        id: 27,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(encryptedMetadata: 'last-surviving-app-key-source'),
          ),
        ],
      );
      await _insertNote(database, note);
      final originalRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 27')).single,
      );
      final fake = _FakeMigrationFiles(failWriteNumber: 1);

      final result = await _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (_) async => jsonEncode({
          'strokes': [stroke.toString()],
          'bgColor': Colors.white.toARGB32(),
          'pagePattern': PagePattern.blank.name,
        }),
      ).migrate(noteId: 27, password: password);

      expect(result.status, LegacySketchMigrationStatus.deferred);
      expect(result.quarantined, hasLength(1));
      expect(fake.files, isEmpty);
      expect(
        Map<String, Object?>.from(
          (await database.query('note', where: 'id = 27')).single,
        ),
        originalRow,
      );
      expect(
        _singleSketchData(originalRow['attachments']! as String),
        containsPair('encrypted_metadata', 'last-surviving-app-key-source'),
      );
      expect(await database.query('file_sync_track'), isEmpty);
      expect(await database.query('sync_track'), isEmpty);
    },
  );

  test(
    'conflicting protected and local metadata sources are quarantined',
    () async {
      final currentStroke = _stroke(Colors.green);
      final metadataStroke = _stroke(Colors.red);
      const currentPath = '/docs/metadata-conflict.json';
      final currentBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': [currentStroke.toString()],
            'bgColor': Colors.white.toARGB32(),
            'pagePattern': PagePattern.blank.name,
            'aspectRatio': 1.0,
          }),
        ),
      );
      final protectedBytes = await encryptBytesWithPassword(
        currentBytes,
        password,
      );
      final fake = _FakeMigrationFiles(files: {currentPath: protectedBytes});
      final note = await _lockedNote(
        id: 26,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(
              strokesFilePath: currentPath,
              encryptedMetadata: 'conflicting-app-key-ciphertext',
            ),
          ),
        ],
      );
      await _insertNote(database, note);
      final originalRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 26')).single,
      );

      final result = await _service(
        fake,
        preferences,
        database,
        localMetadataDecryptor: (_) async => jsonEncode({
          'strokes': [metadataStroke.toString()],
          'bgColor': Colors.white.toARGB32(),
          'pagePattern': PagePattern.blank.name,
        }),
      ).migrate(noteId: 26, password: password);

      expect(result.status, LegacySketchMigrationStatus.deferred);
      expect(result.migrated, isEmpty);
      expect(result.sanitized, isEmpty);
      expect(result.quarantined, hasLength(1));
      result.applyTo(note);
      expect(note.sketches.single.isLegacyQuarantined, isTrue);
      expect(
        Map<String, Object?>.from(
          (await database.query('note', where: 'id = 26')).single,
        ),
        originalRow,
      );
      expect(fake.files.keys, [currentPath]);
      expect(fake.files[currentPath], protectedBytes);
      expect(await database.query('sync_track'), isEmpty);
    },
  );

  test(
    'migrates inline ciphertext to verified current protected file',
    () async {
      final stroke = _stroke(Colors.red);
      final ciphertext = await _legacyMap(stroke, password);
      final note = await _lockedNote(
        id: 1,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(
              encryptedStrokes: ciphertext,
              aspectRatio: 1.5,
              backgroundImage: '/docs/background.jpg',
            ),
          ),
        ],
      );
      await _insertNote(database, note);
      final originalRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 1')).single,
      );
      final fake = _FakeMigrationFiles();

      final result = await _service(
        fake,
        preferences,
        database,
      ).migrate(noteId: 1, password: password);

      expect(result.status, LegacySketchMigrationStatus.migrated);
      expect(result.migrated, hasLength(1));
      final migratedPath = result.migrated.single.newPath;
      final protected = fake.files[migratedPath]!;
      expect(isBytesPasswordEncrypted(protected), isTrue);
      final currentJson =
          jsonDecode(
                utf8.decode(
                  await decryptBytesWithPassword(protected, password),
                ),
              )
              as Map<String, dynamic>;
      expect(currentJson, isNot(contains('encryptedStrokes')));
      expect(currentJson['strokes'], [stroke.toString()]);
      expect(currentJson['bgColor'], Colors.blue.toARGB32());
      expect(currentJson['pagePattern'], PagePattern.grid.name);
      expect(currentJson['aspectRatio'], 1.5);

      final updatedRow = Map<String, Object?>.from(
        (await database.query('note', where: 'id = 1')).single,
      );
      expect(updatedRow['title'], originalRow['title']);
      expect(updatedRow['content'], originalRow['content']);
      expect(updatedRow['locked'], originalRow['locked']);
      expect(updatedRow['created_at'], originalRow['created_at']);
      expect(updatedRow['updated_at'], isNot(originalRow['updated_at']));
      final reloaded = await Note.fromJsonAsync(updatedRow);
      expect(reloaded.sketches.single.strokesFilePath, migratedPath);
      expect(reloaded.sketches.single.hasEncryptedStrokes, isFalse);
      expect(reloaded.sketches.single.backgroundImage, '/docs/background.jpg');
      final sync = (await database.query('sync_track')).single;
      expect(sync['action'], 'upload');
      expect(sync['status'], 'pending');
      expect(await LegacySketchMigrationJournal(preferences).load(), isEmpty);
    },
  );

  test(
    'migrates file-contained ciphertext inside an outer ENCP file',
    () async {
      final stroke = _stroke(Colors.purple);
      final ciphertext = await _legacyMap(stroke, password);
      final oldPath = '/docs/legacy.json';
      final legacyJson = utf8.encode(
        jsonEncode({
          'strokes': <String>[],
          'encryptedStrokes': ciphertext,
          'aspectRatio': 0.75,
        }),
      );
      final fake = _FakeMigrationFiles(
        files: {
          oldPath: await encryptBytesWithPassword(
            Uint8List.fromList(legacyJson),
            password,
          ),
        },
      );
      final note = await _lockedNote(
        id: 2,
        password: password,
        attachments: [
          NoteAttachment.sketch(SketchData(strokesFilePath: oldPath)),
        ],
      );
      await _insertNote(database, note);
      await database.insert('file_sync_track', {
        'note_id': 2,
        'local_path': oldPath,
        'remote_path': 'https://example.com/legacy',
        'content_hash': 'old-hash',
      });

      final result = await _service(
        fake,
        preferences,
        database,
      ).migrate(noteId: 2, password: password);

      expect(result.status, LegacySketchMigrationStatus.migrated);
      expect(fake.files.containsKey(oldPath), isFalse);
      final migrated = result.migrated.single;
      expect(migrated.drawing.encodedStrokes, [stroke.toString()]);
      expect(migrated.aspectRatio, 0.75);
      expect(isBytesPasswordEncrypted(fake.files[migrated.newPath]!), isTrue);
      final tracking = (await database.query('file_sync_track')).single;
      expect(tracking['local_path'], migrated.newPath);
      expect(tracking['content_hash'], isNull);
    },
  );

  test('conflicting current and legacy sources are quarantined', () async {
    final legacyStroke = _stroke(Colors.red);
    final currentStroke = _stroke(Colors.green);
    final ciphertext = await _legacyMap(legacyStroke, password);
    const currentPath = '/docs/current-conflict.json';
    final fake = _FakeMigrationFiles(
      files: {
        currentPath: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'strokes': [currentStroke.toString()],
              'bgColor': Colors.blue.toARGB32(),
              'pagePattern': PagePattern.grid.name,
              'aspectRatio': 1.0,
            }),
          ),
        ),
      },
    );
    final note = await _lockedNote(
      id: 13,
      password: password,
      attachments: [
        NoteAttachment.sketch(
          SketchData(
            strokesFilePath: currentPath,
            encryptedStrokes: ciphertext,
          ),
        ),
      ],
    );
    await _insertNote(database, note);

    final result = await _service(
      fake,
      preferences,
      database,
    ).migrate(noteId: 13, password: password);

    expect(result.status, LegacySketchMigrationStatus.deferred);
    expect(result.migrated, isEmpty);
    expect(result.quarantined, hasLength(1));
    expect(fake.files.keys, [currentPath]);
    final reloaded = await Note.fromJsonAsync(
      (await database.query('note', where: 'id = 13')).single,
    );
    expect(reloaded.sketches.single.strokesFilePath, currentPath);
    expect(reloaded.sketches.single.encryptedStrokes, ciphertext);
  });

  test(
    'partial conversion preserves and quarantines malformed ciphertext',
    () async {
      final validStroke = _stroke(Colors.black);
      final validCiphertext = await _legacyMap(validStroke, password);
      const invalidCiphertext = 'not-valid-encrypted-data';
      final note = await _lockedNote(
        id: 3,
        password: password,
        attachments: [
          NoteAttachment.sketch(SketchData(encryptedStrokes: validCiphertext)),
          NoteAttachment.sketch(
            SketchData(encryptedStrokes: invalidCiphertext),
          ),
        ],
      );
      await _insertNote(database, note);
      final fake = _FakeMigrationFiles();

      final result = await _service(
        fake,
        preferences,
        database,
      ).migrate(noteId: 3, password: password);

      expect(result.status, LegacySketchMigrationStatus.partial);
      expect(result.migrated, hasLength(1));
      expect(result.quarantined, hasLength(1));
      result.applyTo(note);
      expect(note.sketches.first.hasEncryptedStrokes, isFalse);
      expect(note.sketches.first.strokes.map((stroke) => stroke.toString()), [
        validStroke.toString(),
      ]);
      expect(note.sketches.last.isLegacyQuarantined, isTrue);
      expect(note.sketches.last.encryptedStrokes, invalidCiphertext);

      final row = (await database.query('note', where: 'id = 3')).single;
      final reloaded = await Note.fromJsonAsync(row);
      expect(reloaded.sketches.first.hasStrokesFile, isTrue);
      expect(reloaded.sketches.last.encryptedStrokes, invalidCiphertext);
    },
  );

  test('failed staged write preserves row and legacy ciphertext', () async {
    final ciphertext = await _legacyMap(_stroke(Colors.orange), password);
    final note = await _lockedNote(
      id: 4,
      password: password,
      attachments: [
        NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
      ],
    );
    await _insertNote(database, note);
    final originalRow = Map<String, Object?>.from(
      (await database.query('note', where: 'id = 4')).single,
    );
    final fake = _FakeMigrationFiles(failWriteNumber: 1);

    final result = await _service(
      fake,
      preferences,
      database,
    ).migrate(noteId: 4, password: password);

    expect(result.status, LegacySketchMigrationStatus.deferred);
    expect(result.quarantined, hasLength(1));
    expect(
      Map<String, Object?>.from(
        (await database.query('note', where: 'id = 4')).single,
      ),
      originalRow,
    );
    expect(fake.files, isEmpty);
    expect(await database.query('sync_track'), isEmpty);
    expect(await LegacySketchMigrationJournal(preferences).load(), isEmpty);
  });

  test('failed read-back verification preserves the original source', () async {
    final ciphertext = await _legacyMap(_stroke(Colors.lime), password);
    final note = await _lockedNote(
      id: 14,
      password: password,
      attachments: [
        NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
      ],
    );
    await _insertNote(database, note);
    final original = Map<String, Object?>.from(
      (await database.query('note', where: 'id = 14')).single,
    );
    final fake = _FakeMigrationFiles(corruptWriteNumber: 1);

    final result = await _service(
      fake,
      preferences,
      database,
    ).migrate(noteId: 14, password: password);

    expect(result.status, LegacySketchMigrationStatus.deferred);
    expect(fake.files, isEmpty);
    expect(
      Map<String, Object?>.from(
        (await database.query('note', where: 'id = 14')).single,
      ),
      original,
    );
  });

  test('database failure removes staging and preserves the row', () async {
    final ciphertext = await _legacyMap(_stroke(Colors.brown), password);
    final note = await _lockedNote(
      id: 15,
      password: password,
      attachments: [
        NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
      ],
    );
    await _insertNote(database, note);
    final original = Map<String, Object?>.from(
      (await database.query('note', where: 'id = 15')).single,
    );
    await database.execute('''
      CREATE TRIGGER fail_legacy_migration
      BEFORE UPDATE ON note
      WHEN OLD.id = 15
      BEGIN
        SELECT RAISE(ABORT, 'injected migration database failure');
      END
    ''');
    final fake = _FakeMigrationFiles();

    final result = await _service(
      fake,
      preferences,
      database,
    ).migrate(noteId: 15, password: password);

    expect(result.status, LegacySketchMigrationStatus.deferred);
    expect(fake.files, isEmpty);
    expect(
      Map<String, Object?>.from(
        (await database.query('note', where: 'id = 15')).single,
      ),
      original,
    );
    expect(await LegacySketchMigrationJournal(preferences).load(), isEmpty);
  });

  test(
    'full-row conflict retries and preserves the concurrent title edit',
    () async {
      final ciphertext = await _legacyMap(_stroke(Colors.teal), password);
      final note = await _lockedNote(
        id: 5,
        password: password,
        attachments: [
          NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
        ],
      );
      await _insertNote(database, note);
      late _FakeMigrationFiles fake;
      fake = _FakeMigrationFiles(
        onWrite: (_, _) async {
          await database.update(
            'note',
            {'title': 'Concurrent title'},
            where: 'id = ?',
            whereArgs: [5],
          );
          fake.onWrite = null;
        },
      );

      final result = await _service(
        fake,
        preferences,
        database,
      ).migrate(noteId: 5, password: password);

      expect(result.status, LegacySketchMigrationStatus.migrated);
      final row = (await database.query('note', where: 'id = 5')).single;
      expect(row['title'], 'Concurrent title');
      expect(fake.files, hasLength(1));
      expect(await LegacySketchMigrationJournal(preferences).load(), isEmpty);
    },
  );

  test('wrong PIN performs no file or database mutation', () async {
    final ciphertext = await _legacyMap(_stroke(Colors.red), password);
    final note = await _lockedNote(
      id: 6,
      password: password,
      attachments: [
        NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
      ],
    );
    await _insertNote(database, note);
    final original = Map<String, Object?>.from(
      (await database.query('note', where: 'id = 6')).single,
    );
    final fake = _FakeMigrationFiles();

    await expectLater(
      _service(
        fake,
        preferences,
        database,
      ).migrate(noteId: 6, password: 'wrong'),
      throwsA(isA<FormatException>()),
    );

    expect(fake.files, isEmpty);
    expect(
      Map<String, Object?>.from(
        (await database.query('note', where: 'id = 6')).single,
      ),
      original,
    );
  });

  test(
    'note unlock runs migration and hydrates the in-memory drawing',
    () async {
      final stroke = _stroke(Colors.indigo);
      final ciphertext = await _legacyMap(stroke, password);
      final note = await _lockedNote(
        id: 8,
        password: password,
        attachments: [
          NoteAttachment.sketch(
            SketchData(encryptedStrokes: ciphertext, aspectRatio: 2),
          ),
        ],
      );
      await _insertNote(database, note);
      final fake = _FakeMigrationFiles();
      Note.lockFileOperationsOverride = fake.operations;

      await note.unlock(password);

      expect(note.unlocked, isTrue);
      expect(note.password, password);
      expect(note.sketches.single.hasEncryptedStrokes, isFalse);
      expect(note.sketches.single.hasHydratedStrokeSource, isTrue);
      expect(note.sketches.single.strokes.map((item) => item.toString()), [
        stroke.toString(),
      ]);
      expect(
        isBytesPasswordEncrypted(
          fake.files[note.sketches.single.strokesFilePath]!,
        ),
        isTrue,
      );
    },
  );

  test('failed legacy sketch blocks permanent lock removal', () async {
    final note = await _lockedNote(
      id: 9,
      password: password,
      attachments: [
        NoteAttachment.sketch(
          SketchData(encryptedStrokes: 'corrupt-ciphertext'),
        ),
      ],
    );
    await _insertNote(database, note);
    Note.lockFileOperationsOverride = _FakeMigrationFiles().operations;

    await note.unlock(password);

    expect(note.unlocked, isTrue);
    expect(note.sketches.single.isLegacyQuarantined, isTrue);
    await expectLater(
      note.removeLock(password),
      throwsA(isA<NoteUnlockException>()),
    );
    expect(note.locked, isTrue);
  });

  test('normal note save preserves quarantined inline ciphertext', () async {
    const ciphertext = 'preserve-this-existing-value';
    final note = await _lockedNote(
      id: 12,
      password: password,
      attachments: [
        NoteAttachment.sketch(SketchData(encryptedStrokes: ciphertext)),
      ],
    );
    await _insertNote(database, note);
    note.title = 'Edited title';

    expect(await note.save(false), 12);

    final reloaded = await Note.fromJsonAsync(
      (await database.query('note', where: 'id = 12')).single,
    );
    expect(reloaded.title, 'Edited title');
    expect(reloaded.sketches.single.encryptedStrokes, ciphertext);
    expect(reloaded.sketches.single.strokesFilePath, isNull);
  });

  test(
    'preview repair overlays only matching verified migrated sources',
    () async {
      final stroke = _stroke(Colors.cyan);
      final sourceSketch = SketchData(
        strokesFilePath: '/docs/current.json',
        strokes: [stroke],
        backgroundColor: Colors.amber,
        pagePattern: PagePattern.dotGrid,
        aspectRatio: 1.25,
        strokesHydrated: true,
        legacyMigrationState: LegacySketchMigrationState.converted,
      );
      final targetSketch = SketchData(strokesFilePath: '/docs/current.json');
      final mismatchedSketch = SketchData(strokesFilePath: '/docs/other.json');

      await SketchPreviewRepairService.overlayVerifiedUnlockedSources(
        Note(attachments: [NoteAttachment.sketch(sourceSketch)]),
        Note(attachments: [NoteAttachment.sketch(targetSketch)]),
      );
      await SketchPreviewRepairService.overlayVerifiedUnlockedSources(
        Note(attachments: [NoteAttachment.sketch(sourceSketch)]),
        Note(attachments: [NoteAttachment.sketch(mismatchedSketch)]),
      );

      expect(targetSketch.strokes.map((item) => item.toString()), [
        stroke.toString(),
      ]);
      expect(targetSketch.backgroundColor.toARGB32(), Colors.amber.toARGB32());
      expect(targetSketch.pagePattern, PagePattern.dotGrid);
      expect(targetSketch.aspectRatio, 1.25);
      expect(targetSketch.hasHydratedStrokeSource, isTrue);
      expect(mismatchedSketch.strokes, isEmpty);
      expect(mismatchedSketch.hasHydratedStrokeSource, isFalse);
    },
  );

  test('journal contains paths but no PIN or stroke payload', () async {
    final record = LegacySketchMigrationJournalRecord(
      transactionId: 'transaction',
      noteId: 7,
      phase: LegacySketchMigrationJournalPhase.planning,
      replacements: const [
        NoteLockFileReplacement(
          attachmentIndex: 0,
          kind: NoteLockAssetKind.sketchStrokes,
          oldPath: '/docs/old.json',
          newPath: '/docs/new.json',
        ),
      ],
    );
    await LegacySketchMigrationJournal(preferences).put(record);

    final encoded = preferences.getString(
      LegacySketchMigrationJournal.preferenceKey,
    )!;
    expect(encoded, contains('/docs/new.json'));
    expect(encoded, isNot(contains(password)));
    expect(encoded, isNot(contains('1,2,0.5')));
    expect(encoded, isNot(contains('encryptedStrokes')));
  });

  test('startup recovery removes uncommitted staged files only', () async {
    const oldPath = '/docs/old.json';
    const newPath = '/docs/new.json';
    final fake = _FakeMigrationFiles(
      files: {
        oldPath: Uint8List.fromList([1, 2, 3]),
        newPath: await encryptBytesWithPassword(
          Uint8List.fromList(utf8.encode(jsonEncode({'strokes': []}))),
          password,
        ),
      },
    );
    await database.insert('note', {
      'id': 10,
      'locked': 1,
      'attachments': jsonEncode([
        NoteAttachment.sketch(SketchData(strokesFilePath: oldPath)).toJson(),
      ]),
    });
    final journal = LegacySketchMigrationJournal(preferences);
    await journal.put(
      const LegacySketchMigrationJournalRecord(
        transactionId: 'precommit',
        noteId: 10,
        phase: LegacySketchMigrationJournalPhase.planning,
        replacements: [
          NoteLockFileReplacement(
            attachmentIndex: 0,
            kind: NoteLockAssetKind.sketchStrokes,
            oldPath: oldPath,
            newPath: newPath,
          ),
        ],
      ),
    );

    await LegacySketchMigrationRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );

    expect(fake.files.containsKey(oldPath), isTrue);
    expect(fake.files.containsKey(newPath), isFalse);
    expect(await journal.load(), isEmpty);
  });

  test('startup recovery finishes committed cleanup idempotently', () async {
    const oldPath = '/docs/old-committed.json';
    const newPath = '/docs/new-committed.json';
    final protected = await encryptBytesWithPassword(
      Uint8List.fromList(utf8.encode(jsonEncode({'strokes': []}))),
      password,
    );
    final fake = _FakeMigrationFiles(
      files: {
        oldPath: Uint8List.fromList([1, 2, 3]),
        newPath: protected,
      },
      undeletablePaths: {oldPath},
    );
    final attachments = jsonEncode([
      NoteAttachment.sketch(SketchData(strokesFilePath: newPath)).toJson(),
    ]);
    await database.insert('note', {
      'id': 11,
      'locked': 1,
      'attachments': attachments,
    });
    final journal = LegacySketchMigrationJournal(preferences);
    await journal.put(
      LegacySketchMigrationJournalRecord(
        transactionId: 'committed',
        noteId: 11,
        phase: LegacySketchMigrationJournalPhase.ready,
        replacements: const [
          NoteLockFileReplacement(
            attachmentIndex: 0,
            kind: NoteLockAssetKind.sketchStrokes,
            oldPath: oldPath,
            newPath: newPath,
          ),
        ],
        expectedAttachmentsDigest:
            LegacySketchMigrationJournalRecord.attachmentsDigest(attachments),
      ),
    );

    await LegacySketchMigrationRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );
    expect(fake.files.containsKey(oldPath), isTrue);
    expect(await journal.load(), hasLength(1));

    fake.undeletablePaths.clear();
    await LegacySketchMigrationRecoveryService.recoverPending(
      database: database,
      fileOperations: fake.operations,
      journal: journal,
    );
    expect(fake.files.containsKey(oldPath), isFalse);
    expect(fake.files.containsKey(newPath), isTrue);
    expect(await journal.load(), isEmpty);
  });
}

LegacySketchMigrationService _service(
  _FakeMigrationFiles fake,
  SharedPreferences preferences,
  Database database, {
  LocalSketchMetadataDecryptor? localMetadataDecryptor,
}) => LegacySketchMigrationService(
  database: database,
  operations: fake.operations,
  journal: LegacySketchMigrationJournal(preferences),
  localMetadataDecryptor: localMetadataDecryptor,
);

class _FakeMigrationFiles {
  final Map<String, Uint8List> files;
  final int? failWriteNumber;
  final int? corruptWriteNumber;
  final Set<String> undeletablePaths;
  Future<void> Function(String path, Uint8List bytes)? onWrite;
  var _writeCount = 0;
  var _id = 0;

  _FakeMigrationFiles({
    Map<String, Uint8List>? files,
    this.failWriteNumber,
    this.corruptWriteNumber,
    this.onWrite,
    this.undeletablePaths = const {},
  }) : files = files ?? {};

  late final operations = NoteLockFileOperations(
    exists: (filePath) async => files.containsKey(filePath),
    read: (filePath) async {
      final value = files[filePath];
      if (value == null) throw StateError('Missing $filePath');
      return Uint8List.fromList(value);
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
  );
}

SketchStroke _stroke(Color color) =>
    SketchStroke(points: '1,2,0.5;3,4,0.7;', color: color, size: 4);

Future<String> _legacyMap(SketchStroke stroke, String password) => encrypt(
  jsonEncode({
    'strokes': [stroke.toString()],
    'bgColor': Colors.blue.toARGB32(),
    'pagePattern': PagePattern.grid.name,
  }),
  password,
);

Future<Note> _lockedNote({
  required int id,
  required String password,
  required List<NoteAttachment> attachments,
}) async => Note(
  id: id,
  title: 'Locked drawing',
  content: await encrypt(
    jsonEncode([
      {'insert': 'secret\n'},
    ]),
    password,
  ),
  plainText: '',
  locked: true,
  createdAt: DateTime.utc(2026, 7, 18),
  updatedAt: DateTime.utc(2026, 7, 19),
  attachments: attachments,
);

Future<void> _insertNote(Database database, Note note) async {
  final row = await note.toJsonAsync();
  row['id'] = note.id;
  await database.insert('note', row);
}

Map<String, dynamic> _singleSketchData(String attachments) {
  final decoded = jsonDecode(attachments) as List<dynamic>;
  return Map<String, dynamic>.from(
    (decoded.single as Map<String, dynamic>)['data'] as Map,
  );
}
