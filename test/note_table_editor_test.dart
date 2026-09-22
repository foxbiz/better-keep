import 'dart:convert';
import 'package:better_keep/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/note_editor/embeds/note_attachment_embed.dart';
import 'package:better_keep/dialogs/insert_table_dialog.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_builders.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/pages/note_editor/embeds/note_table_embed.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });
  testWidgets(
    'picker has 6 by 5 quick choices and validates custom dimensions',
    (tester) async {
      NoteTableData? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showInsertTableDialog(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table_picker_5_6')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('table_custom_rows')),
        '257',
      );
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('table_custom_rows')),
        '256',
      );
      await tester.enterText(
        find.byKey(const ValueKey('table_custom_columns')),
        '256',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(result?.rows, 256);
      expect(result?.columns, 256);
      expect(result?.cells, isEmpty);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table_picker_2_3')));
      await tester.pumpAndSettle();
      expect(result?.rows, 2);
      expect(result?.columns, 3);
    },
  );

  testWidgets(
    'cell formatting uses the shared toolbar and nested tables persist through root undo',
    (tester) async {
      final table = NoteTableData(rows: 2, columns: 2);
      final root = _controller(table);
      final editing = NoteEmbedEditing();
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus));
      final cellFinder = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      final cell = tester.widget<QuillEditor>(cellFinder);
      cell.focusNode.requestFocus();
      await tester.pump();
      expect(editing.controller, same(cell.controller));
      await tester.ensureVisible(find.byTooltip('Bold'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bold'));
      await tester.pump();
      cell.controller.replaceText(
        0,
        0,
        'Cell text',
        const TextSelection.collapsed(offset: 9),
      );
      await tester.pump();
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Cell text'),
      );
      var restored = NoteTableData.fromJson(
        (root.document.toDelta().first.data as Map)[NoteTableData.type],
      );
      expect(restored.cell(0, 0).first['attributes']['bold'], true);
      root.document.history.clear();
      final nested = NoteTableData(rows: 1, columns: 1);
      insertNoteEmbed(
        cell.controller,
        NoteTableData.type,
        nested.toJson(),
        block: true,
      );
      await tester.pump();
      expect(find.byType(NoteTableView), findsNWidgets(2));
      final withNested = NoteTableData.fromJson(
        (root.document.toDelta().first.data as Map)[NoteTableData.type],
      );
      replaceNoteEmbed(
        root,
        NoteTableData.type,
        table.id,
        withNested.resizeRow(0, 180).toJson(),
      );
      await tester.pump();
      final nestedCellFinder = find
          .descendant(
            of: find.byType(NoteTableView).last,
            matching: find.byType(QuillEditor),
          )
          .last;
      await tester.ensureVisible(nestedCellFinder);
      await tester.pump();
      await tester.tap(nestedCellFinder);
      await tester.pump();
      final nestedCell = tester.widget<QuillEditor>(nestedCellFinder);
      expect(editing.controller, same(nestedCell.controller));
      final cellEditors = tester.widgetList<QuillEditor>(
        find.descendant(
          of: find.byType(NoteTableView).first,
          matching: find.byType(QuillEditor),
        ),
      );
      expect(
        cellEditors
            .where((editor) => editor.config.showCursor == true)
            .single
            .controller,
        same(nestedCell.controller),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Nested text\n',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      await tester.pump();
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Nested text'),
      );
      expect(
        NoteTableData.fromJson(
          (root.document.toDelta().first.data as Map)[NoteTableData.type],
        ).rowHeights[0],
        180,
      );
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getRect(find.byType(NoteTableView).last).bottomLeft +
            const Offset(36, 4),
      );
      await tester.pump();
      expect(cell.focusNode.hasPrimaryFocus, isTrue);
      expect(editing.controller, same(cell.controller));
      root.undo();
      await tester.pump();
      await tester.pump();
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Cell text'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Quill defers web caret work for the keyboard animation.
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets('edge actions resize, duplicate and remove rich rows with undo', (
    tester,
  ) async {
    final table = NoteTableData(rows: 2, columns: 2).withCell(0, 0, [
      {'insert': 'Original\n'},
    ]);
    final root = _controller(table);
    final editing = NoteEmbedEditing();
    final focus = FocusNode();
    addTearDown(() {
      root.dispose();
      editing.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(_editor(root, editing, focus));
    expect(find.text('A'), findsNothing);
    expect(find.text('1'), findsNothing);
    expect(find.text('Add row'), findsNothing);
    expect(find.text('Add column'), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    final firstCell = find
        .descendant(
          of: find.byType(NoteTableView),
          matching: find.byType(QuillEditor),
        )
        .first;
    final tableBounds = tester.getRect(find.byType(NoteTableView));
    final cellBounds = tester.getRect(firstCell);
    expect(cellBounds.left, tableBounds.left);
    expect(cellBounds.top, tableBounds.top);
    expect(cellBounds.width, closeTo((tableBounds.width - 2) / 2, 0.1));
    await tester.tap(firstCell);
    await tester.pump();
    expect(tester.getRect(firstCell), cellBounds);
    expect(
      tester.getRect(find.byKey(const ValueKey('table_column_0'))).top,
      cellBounds.top,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('table_row_0'))).left,
      cellBounds.left,
    );
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byKey(const ValueKey('table_row_1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('table_row_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate row'));
    await tester.pumpAndSettle();
    var data = NoteTableData.fromJson(
      (root.document.toDelta().first.data as Map)[NoteTableData.type],
    );
    expect(data.rows, 3);
    expect(data.cell(1, 0), data.cell(0, 0));
    expect(
      find.descendant(
        of: find.byType(NoteTableView),
        matching: find.byType(QuillEditor),
      ),
      findsNWidgets(6),
    );
    await tester.tap(firstCell);
    await tester.pump();
    final originalWidth = tester.getSize(firstCell).width;
    final columnDrag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('table_resize_column_0'))),
    );
    for (final movement in [24.0, 23.0, 23.0]) {
      await columnDrag.moveBy(Offset(movement, 0));
      await tester.pump();
    }
    await columnDrag.up();
    await tester.pumpAndSettle();
    data = NoteTableData.fromJson(
      (root.document.toDelta().first.data as Map)[NoteTableData.type],
    );
    expect(data.columnWidths[0], closeTo(originalWidth + 70, 0.1));
    final rowDrag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('table_resize_row_0'))),
    );
    await rowDrag.moveBy(const Offset(0, 22));
    await tester.pump();
    await rowDrag.moveBy(const Offset(0, 18));
    await tester.pump();
    await rowDrag.up();
    await tester.pumpAndSettle();
    data = NoteTableData.fromJson(
      (root.document.toDelta().first.data as Map)[NoteTableData.type],
    );
    expect(data.rowHeights[0], closeTo(112, 0.1));
    await tester.tap(find.byKey(const ValueKey('table_column_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete table'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteTableView), findsNothing);
    root.undo();
    await tester.pumpAndSettle();
    expect(find.byType(NoteTableView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
    'one attachment reference renders in text and cells and follows image-to-sketch updates',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      UniversalImageCache.instance.put('/old.png', '/old.png', bytes);
      UniversalImageCache.instance.put('/new.png', '/new.png', bytes);
      addTearDown(UniversalImageCache.instance.clear);
      final attachment = NoteAttachment.image(
        NoteImage(
          src: '/old.png',
          size: bytes.length,
          index: 0,
          aspectRatio: '1:4',
          lastModified: '1',
        ),
      );
      final reference = attachmentReference(attachment, inline: true);
      final table = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {
          'insert': {noteAttachmentEmbedType: reference},
        },
        {'insert': '\n'},
      ]);
      final root = _controller(table);
      root.replaceText(1, 0, '\n', null);
      root.replaceText(
        2,
        0,
        Embeddable(noteAttachmentEmbedType, {...reference, 'id': 'second'}),
        null,
      );
      final note = Note(attachments: [attachment]);
      final editing = NoteEmbedEditing();
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      expect(find.byType(UniversalImage), findsNWidgets(2));
      for (final element in find.byType(UniversalImage).evaluate()) {
        expect((element.widget as UniversalImage).path, '/old.png');
      }
      final cellFinder = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      final imageFinder = find.descendant(
        of: cellFinder,
        matching: find.byType(UniversalImage),
      );
      void expectImageFits() {
        final bounds = tester.getRect(cellFinder).deflate(2);
        final image = tester.getRect(imageFinder);
        expect(bounds.contains(image.topLeft), isTrue);
        expect(bounds.contains(image.bottomRight), isTrue);
      }

      expectImageFits();
      // Switching between inline and block must keep the whole image in the cell.
      final cell = tester.widget<QuillEditor>(cellFinder);
      changeAttachmentPlacement(cell.controller, reference, inline: false);
      await tester.pump();
      expectImageFits();
      final saved = jsonEncode(root.document.toDelta().toJson());
      attachment.type = AttachmentType.sketch;
      attachment.sketch = SketchData(
        previewImage: '/new.png',
        strokesFilePath: '/strokes.json',
      );
      attachment.image = null;
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      for (final element in find.byType(UniversalImage).evaluate()) {
        expect((element.widget as UniversalImage).path, '/new.png');
      }
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      expectImageFits();
      note.attachments.clear();
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      expect(find.byTooltip('Attachment unavailable'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Quill defers web caret work for the keyboard animation.
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'large tables virtualize cells, constrain scrolling, and keep read-only cells protected',
    (tester) async {
      final table = NoteTableData(rows: 256, columns: 256);
      final root = _controller(table)..readOnly = true;
      final editing = NoteEmbedEditing();
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus));
      final cells = find.descendant(
        of: find.byType(NoteTableView),
        matching: find.byType(QuillEditor),
      );
      expect(cells.evaluate().length, lessThan(80));
      expect(
        tester.getSize(find.byType(NoteTableView)).width,
        lessThanOrEqualTo(360),
      );
      for (final element in cells.evaluate()) {
        expect((element.widget as QuillEditor).controller.readOnly, true);
      }
      expect(find.text('A'), findsNothing);
      expect(find.text('1'), findsNothing);
      AppState.tableHeaders = true;
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('table_headers'), isTrue);
      await AppState.init(prefs: prefs);
      expect(AppState.tableHeaders, isTrue);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.drag(
        find.byKey(ValueKey('table_horizontal_${table.id}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(cells.evaluate().length, lessThan(80));
      await tester.pumpWidget(const SizedBox.shrink());
      // Quill defers web caret work for the keyboard animation.
      await tester.pump(const Duration(milliseconds: 600));
    },
  );
}

QuillController _controller(NoteTableData table) => QuillController(
  document: Document.fromJson([
    {
      'insert': {NoteTableData.type: table.toJson()},
    },
    {'insert': '\n'},
  ]),
  selection: const TextSelection.collapsed(offset: 0),
);
Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: betterKeepLocalizationDelegates,
  supportedLocales: betterKeepSupportedLocales,
  home: Scaffold(body: child),
);
Widget _editor(
  QuillController root,
  NoteEmbedEditing editing,
  FocusNode focus, {
  Note? note,
}) {
  final currentNote = note ?? Note();
  final editorKey = GlobalKey<EditorState>();
  return _app(
    Center(
      child: SizedBox(
        width: 360,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: ListenableBuilder(
                  listenable: Listenable.merge([editing, root]),
                  builder: (_, _) => QuillEditor.basic(
                    controller: root,
                    focusNode: focus,
                    config: QuillEditorConfig(
                      editorKey: editorKey,
                      showCursor: !root.readOnly && editing.controller == null,
                      enableSelectionToolbar: editing.controller == null,
                      scrollable: false,
                      onTapDown: (details, _) => editing.handlesTapDown(
                        root,
                        details,
                        editorKey.currentState,
                      ),
                      onTapUp: (details, _) =>
                          editing.handlesGesture(root, details.globalPosition),
                      embedBuilders: noteEmbedBuilders(
                        note: currentNote,
                        editing: editing,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ListenableBuilder(
              listenable: editing,
              builder: (_, _) => NoteEditorToolbar(
                key: ObjectKey(editing.controller ?? root),
                controller: editing.controller ?? root,
                focusNode: editing.focusNode ?? focus,
                readOnly: root.readOnly,
                parentColor: Colors.white,
                showAttachments: false,
                note: currentNote,
                showDocumentEmbeds: true,
                historyBinding: NoteEditorHistoryBinding.quill(root),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
