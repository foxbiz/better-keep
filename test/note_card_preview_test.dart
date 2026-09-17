import 'dart:convert';

import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
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
}
