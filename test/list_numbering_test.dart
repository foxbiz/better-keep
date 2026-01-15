import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/utils/quill_config.dart';

void main() {
  group('Ordered list numbering with nested checkboxes', () {
    testWidgets('ordered list numbers continue after nested checkboxes', (
      WidgetTester tester,
    ) async {
      // Create a document with:
      // 1. First item
      //   [ ] Nested checkbox 1
      //   [ ] Nested checkbox 2
      // 2. Second item (should be 2, not 1)
      final documentJson = [
        {'insert': 'First item'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Nested checkbox 1'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 1},
        },
        {'insert': 'Nested checkbox 2'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 1},
        },
        {'insert': 'Second item'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];

      final document = Document.fromJson(documentJson);
      final controller = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuillEditor.basic(
              controller: controller,
              config: QuillEditorConfig(
                customLeadingBlockBuilder: customLeadingBlockBuilder,
                customStyles: buildQuillStyles(
                  foregroundColor: Colors.black,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );

      // Allow the widget to render
      await tester.pumpAndSettle();

      // Find QuillNumberPoint widgets (ordered list markers)
      final numberPointFinder = find.byType(QuillNumberPoint);
      expect(numberPointFinder, findsNWidgets(2));

      // Get the QuillNumberPoint widgets and verify their indices
      final numberPoints = tester
          .widgetList<QuillNumberPoint>(numberPointFinder)
          .toList();

      // First ordered item should have index "1"
      expect(numberPoints[0].index, '1');

      // Second ordered item should have index "2" (not reset to "1")
      expect(numberPoints[1].index, '2');

      controller.dispose();
    });

    testWidgets('simple ordered list numbers correctly', (
      WidgetTester tester,
    ) async {
      final documentJson = [
        {'insert': 'Item one'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Item two'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Item three'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];

      final document = Document.fromJson(documentJson);
      final controller = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuillEditor.basic(
              controller: controller,
              config: QuillEditorConfig(
                customLeadingBlockBuilder: customLeadingBlockBuilder,
                customStyles: buildQuillStyles(
                  foregroundColor: Colors.black,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final numberPoints = tester
          .widgetList<QuillNumberPoint>(find.byType(QuillNumberPoint))
          .toList();

      expect(numberPoints.length, 3);
      expect(numberPoints[0].index, '1');
      expect(numberPoints[1].index, '2');
      expect(numberPoints[2].index, '3');

      controller.dispose();
    });

    testWidgets('nested bullet list does not affect ordered list numbering', (
      WidgetTester tester,
    ) async {
      final documentJson = [
        {'insert': 'First ordered'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Nested bullet'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet', 'indent': 1},
        },
        {'insert': 'Second ordered'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];

      final document = Document.fromJson(documentJson);
      final controller = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuillEditor.basic(
              controller: controller,
              config: QuillEditorConfig(
                customLeadingBlockBuilder: customLeadingBlockBuilder,
                customStyles: buildQuillStyles(
                  foregroundColor: Colors.black,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final numberPoints = tester
          .widgetList<QuillNumberPoint>(find.byType(QuillNumberPoint))
          .toList();

      expect(numberPoints.length, 2);
      expect(numberPoints[0].index, '1');
      expect(numberPoints[1].index, '2');

      controller.dispose();
    });

    testWidgets('deeply nested checkboxes do not break parent ordered list', (
      WidgetTester tester,
    ) async {
      final documentJson = [
        {'insert': 'First'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Nested level 1'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 1},
        },
        {'insert': 'Nested level 2'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 2},
        },
        {'insert': 'Second'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Third'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];

      final document = Document.fromJson(documentJson);
      final controller = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuillEditor.basic(
              controller: controller,
              config: QuillEditorConfig(
                customLeadingBlockBuilder: customLeadingBlockBuilder,
                customStyles: buildQuillStyles(
                  foregroundColor: Colors.black,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final numberPoints = tester
          .widgetList<QuillNumberPoint>(find.byType(QuillNumberPoint))
          .toList();

      expect(numberPoints.length, 3);
      expect(numberPoints[0].index, '1');
      expect(numberPoints[1].index, '2');
      expect(numberPoints[2].index, '3');

      controller.dispose();
    });
  });

  group('Markdown export for nested lists', () {
    test(
      'ordered list with nested checkboxes exports with proper indentation',
      () {
        // Create a note with ordered list containing nested checkboxes
        final documentJson = [
          {'insert': 'First item'},
          {
            'insert': '\n',
            'attributes': {'list': 'ordered'},
          },
          {'insert': 'Nested checkbox 1'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked', 'indent': 1},
          },
          {'insert': 'Nested checkbox 2'},
          {
            'insert': '\n',
            'attributes': {'list': 'checked', 'indent': 1},
          },
          {'insert': 'Second item'},
          {
            'insert': '\n',
            'attributes': {'list': 'ordered'},
          },
        ];

        final note = Note(
          title: 'Test Note',
          content: json.encode(documentJson),
        );

        final markdown = ExportDataService().noteToMarkdown(
          note,
          includeMetadata: false,
        );

        // Split into lines and check structure
        final lines = markdown.trim().split('\n');

        // Should have:
        // 1. First item
        //     - [ ] Nested checkbox 1
        //     - [x] Nested checkbox 2
        // 1. Second item

        expect(lines.length, 4);
        expect(lines[0], '1. First item');
        expect(lines[1], '    - [ ] Nested checkbox 1'); // 4 spaces indent
        expect(lines[2], '    - [x] Nested checkbox 2'); // 4 spaces indent
        expect(lines[3], '1. Second item');
      },
    );

    test('deeply nested checkboxes export with multiple indent levels', () {
      final documentJson = [
        {'insert': 'First'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': 'Level 1 checkbox'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 1},
        },
        {'insert': 'Level 2 checkbox'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked', 'indent': 2},
        },
        {'insert': 'Second'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ];

      final note = Note(
        title: 'Deep Nesting',
        content: json.encode(documentJson),
      );

      final markdown = ExportDataService().noteToMarkdown(
        note,
        includeMetadata: false,
      );

      final lines = markdown.trim().split('\n');

      expect(lines.length, 4);
      expect(lines[0], '1. First');
      expect(lines[1], '    - [ ] Level 1 checkbox'); // 4 spaces
      expect(lines[2], '        - [x] Level 2 checkbox'); // 8 spaces
      expect(lines[3], '1. Second');
    });
  });
}
