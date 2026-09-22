import 'dart:convert';

import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
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

    test('truncation at $limit keeps a table separate from the ellipsis', () {
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
      expect(result.toPlainText(), '$prefix\uFFFC\n...\n');
      final line = result.queryChild(prefix.length).node as Line;
      expect(line.childCount, 1);
      expect((line.children.single as Embed).value.data, table.toJson());
      expect(source.toDelta().toJson(), original);
    });
  }

  test('truncation preserves inline and checklist attributes and embeds', () {
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
    expect(
      result,
      contains(
        equals({
          'insert': {'image': 'fixture-image'},
        }),
      ),
    );
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
          'insert': 'co',
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
    'table card previews crop large and nested tables without scrollbars or data changes',
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
          final rootTable = find.byKey(ValueKey(table.id));
          final displayedHeight =
              tester.getBottomRight(rootTable).dy -
              tester.getTopLeft(rootTable).dy;
          expect(displayedHeight, lessThanOrEqualTo(160));
          expect(tester.getSize(find.byType(NoteCard)).height, lessThan(300));
          expect(
            displayedHeight,
            table == small ? lessThan(160) : closeTo(160, 0.1),
          );
          expect(
            find.descendant(
              of: rootTable,
              matching: find.byWidgetPredicate(
                (widget) => widget is RawScrollbar,
              ),
            ),
            findsNothing,
          );
          final cells = find.descendant(
            of: rootTable,
            matching: find.byType(QuillEditor),
          );
          expect(cells.evaluate().length, lessThan(40));
          expect(
            tester.widget<NoteTableView>(rootTable).table.rows,
            table.rows,
          );
          for (final editor in tester.widgetList<QuillEditor>(cells)) {
            expect(editor.controller.readOnly, isTrue);
          }
          expect(note.content, content);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );
}
