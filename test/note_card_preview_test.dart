import 'dart:convert';

import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/note_image_grid.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/note_editor/embeds/note_attachment_embed.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/embeds/note_table_embed.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late NoteCardBodyCache cache;
  setUp(() => cache = NoteCardBodyCache());
  tearDown(() => cache.dispose());

  Document preview(Document source, {int limit = 500}) {
    cache.update(locked: false, document: source, maxChars: limit);
    return cache.controller!.document;
  }

  for (final limit in [500, 1000]) {
    test('long single insert retains its first $limit characters', () {
      final source = Document.fromJson([
        {'insert': '${'a' * (limit + 100)}\n'},
      ]);
      final original = jsonEncode(source.toDelta().toJson());
      expect(
        preview(source, limit: limit).toPlainText(),
        '${'a' * limit}...\n',
      );
      expect(jsonEncode(source.toDelta().toJson()), original);
    });

    test('exact $limit-character note needs no ellipsis', () {
      final source = Document.fromJson([
        {'insert': '${'a' * limit}\n'},
      ]);
      expect(preview(source, limit: limit).toPlainText(), source.toPlainText());
    });

    test(
      'truncation skips table payload and uses the $limit-character budget for text',
      () {
        final table = NoteTableData(rows: 2, columns: 2).withCell(1, 1, [
          {'insert': 'Preserved cell\n'},
        ]);
        final prefix = '${'a' * (limit - 2)}\n';
        final source = Document.fromJson([
          {'insert': prefix},
          {
            'insert': {NoteTableData.type: table.toJson()},
          },
          {'insert': '\nFollowing text\n'},
        ]);
        addTearDown(source.close);
        final original = source.toDelta().toJson();
        final result = preview(source, limit: limit);
        expect(result.toPlainText(), '${prefix}F...\n');
        expect(cache.tableCount, 1);
        expect(
          result.toDelta().toJson().every((op) => op['insert'] is String),
          isTrue,
        );
        expect(source.toDelta().toJson(), original);
      },
    );
  }

  test('truncation preserves rich text and summarizes embedded images', () {
    final source = Document.fromJson([
      {'insert': 'Heading\n'},
      {
        'insert': {'image': 'fixture-image'},
      },
      {
        'insert': 'bold ',
        'attributes': {'bold': true},
      },
      {
        'insert': 'continued text',
        'attributes': {'italic': true},
      },
      {
        'insert': '\n',
        'attributes': {'list': 'checked', 'indent': 1},
      },
    ]);
    final original = jsonEncode(source.toDelta().toJson());
    final result = preview(source, limit: 16).toDelta().toJson();
    expect(cache.imageSources, {'fixture-image'});
    expect(result.every((op) => op['insert'] is String), isTrue);
    expect(
      result,
      contains(
        equals({
          'insert': 'bold ',
          'attributes': {'bold': true},
        }),
      ),
    );
    expect(
      result,
      contains(
        equals({
          'insert': 'con',
          'attributes': {'italic': true},
        }),
      ),
    );
    expect(result.last, {
      'insert': '\n',
      'attributes': {'list': 'checked', 'indent': 1},
    });
    expect(jsonEncode(source.toDelta().toJson()), original);
  });

  test('operation and Unicode boundaries retain text and one ellipsis', () {
    final source = Document.fromJson([
      {
        'insert': 'a👩🏽‍💻e\u0301',
        'attributes': {'bold': true},
      },
      {'insert': 'remaining text\n'},
    ]);
    expect(preview(source, limit: 3).toPlainText(), 'a👩🏽‍💻e\u0301...\n');
    expect(preview(source, limit: 2).toPlainText(), 'a👩🏽‍💻...\n');
  });

  test('empty notes remain empty and locked notes have no preview', () {
    expect(preview(Document()).toPlainText(), '\n');
    cache.update(
      locked: true,
      document: Document.fromJson([
        {'insert': 'Private\n'},
      ]),
    );
    expect(cache.controller, isNull);
  });

  testWidgets('card updates and resizing keep the current preview limit', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final note = Note(
      id: 42,
      content: jsonEncode([
        {'insert': '${'a' * 1200}\n'},
      ]),
    );

    Future<void> show(double width) async {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: [
            ...AppLocalizations.localizationsDelegates,
            FlutterQuillLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: NoteCard(note: note, index: 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    String body() => tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller
        .document
        .toPlainText();
    await show(900);
    expect(body(), '${'a' * 1000}...\n');
    note.content = jsonEncode([
      {'insert': '${'b' * 1200}\n'},
    ]);
    await show(900);
    expect(body(), '${'b' * 1000}...\n');
    await show(500);
    expect(body(), '${'b' * 500}...\n');
    await show(900);
    expect(body(), '${'b' * 1000}...\n');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'cards retain attachment previews and summarize only in-note media',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init();
      const thumbnail =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
      for (final path in ['/photo.png', '/sketch.png']) {
        UniversalImageCache.instance.put(path, path, base64Decode(thumbnail));
      }
      addTearDown(UniversalImageCache.instance.clear);
      final attachment = NoteAttachment.image(
        NoteImage(
          src: '/photo.png',
          size: 1,
          index: 0,
          aspectRatio: '1:1',
          lastModified: '1',
          blurredThumbnail: thumbnail,
        ),
      );
      final reference = attachmentReference(attachment);
      final table = NoteTableData(rows: 256, columns: 256).withCell(0, 0, [
        {'insert': 'Private table text\n'},
      ]);
      final content = jsonEncode([
        {'insert': 'Before\n'},
        {
          'insert': {noteAttachmentEmbedType: reference},
        },
        {'insert': '\n'},
        {
          'insert': {noteAttachmentEmbedType: reference},
        },
        {'insert': '\n'},
        {
          'insert': {'image': '/imported.png'},
        },
        {'insert': '\n'},
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {'insert': '\nAfter\n'},
      ]);
      for (final (width, brightness, locale, scale, hasBody) in [
        (180.0, Brightness.light, const Locale('en'), 1.0, true),
        (300.0, Brightness.dark, const Locale('pt'), 1.8, true),
        (180.0, Brightness.light, const Locale('en'), 1.0, false),
      ]) {
        for (final locked in [false, true]) {
          final note = Note(
            id: 42,
            locked: locked,
            content: hasBody ? content : null,
            attachments: [
              attachment,
              NoteAttachment.sketch(
                SketchData(
                  previewImage: '/sketch.png',
                  strokesFilePath: '/sketch.json',
                  blurredThumbnail: thumbnail,
                ),
              ),
            ],
          );
          final original = jsonEncode(note.toJson());
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              locale: locale,
              localizationsDelegates: [
                ...AppLocalizations.localizationsDelegates,
                FlutterQuillLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        child: NoteCard(note: note, index: 0),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final l10n = AppLocalizations.of(
            tester.element(find.byType(NoteCard)),
          )!;
          // Only the repeated body reference and imported body image get chips.
          // An attachment without a body reference keeps its preview only.
          final showsBody = hasBody && !locked;
          expect(
            find.text(l10n.imageCount(2)),
            showsBody ? findsOneWidget : findsNothing,
          );
          expect(find.text(l10n.sketchCount(1)), findsNothing);
          expect(
            find.text(l10n.tableCount(1)),
            showsBody ? findsOneWidget : findsNothing,
          );
          expect(find.byType(NoteTableView), findsNothing);
          expect(find.byType(NoteImageGrid), findsOneWidget);
          final grid = tester.widget<NoteImageGrid>(find.byType(NoteImageGrid));
          expect(grid.maxHeight, 200);
          expect(
            grid.images.map((image) => image.src),
            locked ? ['', ''] : ['/photo.png', '/sketch.png'],
          );
          expect(grid.customImageBuilder, locked ? isNotNull : isNull);
          expect(
            find.byType(UniversalImage),
            locked ? findsNothing : findsNWidgets(2),
          );
          expect(
            find.byWidgetPredicate((widget) => widget is RawScrollbar),
            findsNothing,
          );
          if (!showsBody) {
            expect(find.byType(QuillEditor), findsNothing);
            if (locked) {
              expect(find.text(l10n.thisNoteIsLocked), findsOneWidget);
            }
          } else {
            final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
            expect(editor.controller.document.toPlainText(), 'Before\nAfter\n');
          }
          expect(jsonEncode(note.toJson()), original);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );

  testWidgets(
    'table card previews summarize large and nested tables without rendering cells or changing data',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init();
      final nested = NoteTableData(rows: 256, columns: 256);
      final large = NoteTableData(rows: 256, columns: 256, rowHeights: {0: 260})
          .withCell(0, 0, [
            {
              'insert': {NoteTableData.type: nested.toJson()},
            },
            {'insert': '\n'},
          ]);
      final small = NoteTableData(rows: 1, columns: 1);
      for (final width in [180.0, 300.0]) {
        for (final table in [large, small]) {
          final content = jsonEncode([
            {
              'insert': {NoteTableData.type: table.toJson()},
            },
            {'insert': '\n'},
          ]);
          final note = Note(id: 42, content: content);
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: [
                ...AppLocalizations.localizationsDelegates,
                FlutterQuillLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: NoteCard(note: note, index: 0),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(NoteTableView), findsNothing);
          expect(find.byType(QuillEditor), findsNothing);
          expect(
            find.byWidgetPredicate((widget) => widget is RawScrollbar),
            findsNothing,
          );
          expect(find.text('1 table'), findsOneWidget);
          expect(tester.getSize(find.byType(NoteCard)).height, lessThan(180));
          expect(note.content, content);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );
}
