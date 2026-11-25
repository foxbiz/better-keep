import 'dart:convert';
import 'dart:io';

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets(
    'sketch edits keep old source bytes and advance the note revision even when previews match',
    (tester) async {
      late Directory directory;
      late Database db;
      final compression = FlutterImageCompressPlatform.instance;
      FlutterImageCompressPlatform.instance = _SamePreview();
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('sketch-revision-');
        SharedPreferences.setMockInitialValues({});
        await AppState.init(prefs: await SharedPreferences.getInstance());
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await Note.createTable(db);
        await NoteSyncTrack.createTable(db);
        await SyncMutationJournal.install(db);
        AppState.db = db;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      var saves = 0;
      Note.syncTriggerOverride = () => saves++;
      addTearDown(() async {
        Note.syncTriggerOverride = null;
        FlutterImageCompressPlatform.instance = compression;
        UniversalImageCache.instance.clear();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await db.close();
        await directory.delete(recursive: true);
      });
      final originalPath = '${directory.path}/original.json';
      final previewPath = '${directory.path}/preview.png';
      late SketchData sketch;
      late Note note;
      late String originalBytes;
      await tester.runAsync(() async {
        sketch = SketchData(
          strokes: [
            SketchStroke(
              points: '100,100,0.5;200,200,0.5;',
              color: Colors.black,
              size: 5,
            ),
          ],
          strokesFilePath: originalPath,
          previewImage: previewPath,
          aspectRatio: kSketchA4Size.aspectRatio,
          blurredThumbnail: base64Encode(_SamePreview.bytes),
          strokesHydrated: true,
        );
        originalBytes = jsonEncode(sketch.toStrokesFileJson());
        note = Note(
          title: 'QA sketch',
          attachments: [NoteAttachment.sketch(sketch)],
        );
      });
      late SyncLocalVersion before;
      await tester.runAsync(() async {
        await File(originalPath).writeAsString(originalBytes);
        await File(previewPath).writeAsBytes(_SamePreview.bytes);
        await note.save();
        before = (await SyncMutationJournal.current(
          db,
          SyncEntityKind.note,
          note.syncId!,
        ))!;
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SketchPage(note: note, sketch: sketch),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(InteractiveViewer), const Offset(80, 60));
      await tester.pump(const Duration(seconds: 4));
      for (var i = 0; i < 100 && saves < 2; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(sketch.strokes.length, 2);
      await tester.runAsync(() async {
        // The old note snapshot remains safe to upload during this save.
        expect(await File(originalPath).readAsString(), originalBytes);
        expect(sketch.strokesFilePath, isNot(originalPath));
        final after = (await SyncMutationJournal.current(
          db,
          SyncEntityKind.note,
          note.syncId!,
        ))!;
        expect(after.compareTo(before), greaterThan(0));
        expect(saves, 2);
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}

// Low-resolution thumbnails can be identical for distinct drawings.
class _SamePreview extends FlutterImageCompressPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
  static final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  @override
  Future<Uint8List> compressWithList(
    Uint8List image, {
    int minWidth = 1920,
    int minHeight = 1080,
    int quality = 95,
    int rotate = 0,
    int inSampleSize = 1,
    bool autoCorrectionAngle = true,
    CompressFormat format = CompressFormat.jpeg,
    bool keepExif = false,
  }) async => bytes;
}
