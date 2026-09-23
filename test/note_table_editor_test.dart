import 'dart:convert';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/quill_config.dart';
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
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
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
    'cell formatting keeps media tools but omits nested table insertion',
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
      expect(find.byKey(const ValueKey('insert_table')), findsOneWidget);
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
      expect(find.byKey(const ValueKey('insert_table')), findsNothing);
      expect(find.byKey(const ValueKey('insert_note_image')), findsOneWidget);
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
      final restored = NoteTableData.fromJson(
        (root.document.toDelta().first.data as Map)[NoteTableData.type],
      );
      expect(restored.cell(0, 0).first['attributes']['bold'], true);
      root.document.history.clear();
      final pasted = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {'insert': 'Pasted text\n'},
      ]);
      insertNoteEmbed(
        cell.controller,
        NoteTableData.type,
        pasted.toJson(),
        block: true,
      );
      expect(cell.controller.document.toPlainText(), 'Cell text\n');
      cell.controller.replaceText(
        9,
        0,
        Delta()..insert({NoteTableData.type: pasted.toJson()}),
        const TextSelection.collapsed(offset: 9),
      );
      await tester.pump();
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Pasted text'),
      );
      // Quill groups history by wall time; undo all edits since insertion.
      while (root.document.hasUndo) {
        root.undo();
      }
      await tester.pump();
      await tester.pump();
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Cell text'),
      );
      expect(cell.controller.document.toPlainText(), 'Cell text\n');
      editing.release(cell.controller);
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('insert_table')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Quill defers web caret work for the keyboard animation.
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'legacy nested cells display rich content without rewriting saved data',
    (tester) async {
      final nested = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {
          'insert': 'Legacy text',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]);
      final table = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {
          'insert': {NoteTableData.type: nested.toJson()},
        },
        {'insert': '\n'},
      ]);
      final root = _controller(table);
      final editing = NoteEmbedEditing();
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      final original = jsonEncode(root.document.toDelta().toJson());
      await tester.pumpWidget(_editor(root, editing, focus));
      expect(find.byType(NoteTableView), findsOneWidget);
      final cell = tester.widget<QuillEditor>(
        find.descendant(
          of: find.byType(NoteTableView),
          matching: find.byType(QuillEditor),
        ),
      );
      expect(cell.controller.document.toPlainText(), 'Legacy text\n');
      expect(cell.controller.document.toDelta().first.attributes, {
        'bold': true,
      });
      expect(jsonEncode(root.document.toDelta().toJson()), original);
      cell.focusNode.requestFocus();
      await tester.pumpAndSettle();
      expect(jsonEncode(root.document.toDelta().toJson()), original);
      cell.controller.replaceText(0, 0, 'Edited ', null);
      await tester.pump();
      expect(
        noteDeltaPlainText(root.document.toDelta().toJson()),
        contains('Edited Legacy text'),
      );
      root.undo();
      await tester.pump();
      await tester.pump();
      expect(jsonEncode(root.document.toDelta().toJson()), original);
      expect(cell.controller.document.toPlainText(), 'Legacy text\n');
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
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
      final reference = attachmentReference(attachment);
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
    'attachment resizing preserves block layout, aspect ratio, and undo in notes and cells',
    (tester) async {
      for (final inCell in [false, true]) {
        final ratio = inCell ? 4.0 : 1.0;
        final note = Note(
          attachments: [
            NoteAttachment.sketch(SketchData(aspectRatio: ratio))
              ..id = 'missing',
          ],
        );
        final reference = <String, dynamic>{
          'id': 'resizable',
          'src': 'attachment://missing',
          'placement': 'inline',
          'width': 120.0,
        };
        final delta = [
          {'insert': 'Before '},
          {
            'insert': {noteAttachmentEmbedType: reference},
          },
          {'insert': ' after\n'},
        ];
        final root = inCell
            ? _controller(
                NoteTableData(
                  rows: 1,
                  columns: 1,
                  rowHeights: {0: 220},
                ).withCell(0, 0, delta),
              )
            : QuillController(
                document: documentFromJsonSafe(delta),
                selection: const TextSelection.collapsed(offset: 0),
              );
        final editing = NoteEmbedEditing()..rootController = root;
        final focus = FocusNode();
        await tester.pumpWidget(
          _editor(root, editing, focus, note: note, rebuildOnController: false),
        );
        await tester.pumpAndSettle();
        final owner = inCell
            ? tester
                  .widget<QuillEditor>(
                    find
                        .descendant(
                          of: find.byType(NoteTableView),
                          matching: find.byType(QuillEditor),
                        )
                        .first,
                  )
                  .controller
            : root;
        final image = find.byKey(const ValueKey('attachment_image_resizable'));
        final originalSize = tester.getSize(image);
        expect(originalSize, Size(120, 120 / ratio));
        expect(owner.document.toPlainText(), 'Before \n\uFFFC\n after\n');
        final handle = find.byKey(
          const ValueKey('attachment_resize_resizable'),
        );
        expect(handle, findsNothing);
        final ownerEditor = find.byWidgetPredicate(
          (widget) =>
              widget is QuillEditor && identical(widget.controller, owner),
        );
        expect(
          tester.getCenter(image).dx,
          closeTo(tester.getCenter(ownerEditor).dx, 0.1),
        );
        await tester.tap(image);
        await tester.pumpAndSettle();
        expect(handle, findsOneWidget);
        expect(find.text('Remove from text'), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        expect(handle, findsNothing);
        final imageFocus = Focus.of(tester.element(image));
        imageFocus.unfocus();
        await tester.pumpAndSettle();
        imageFocus.requestFocus();
        await tester.pumpAndSettle();
        expect(handle, findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        expect(handle, findsNothing);
        // Keyboard activation also reveals controls after they time out.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(handle, findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('attachment_options_resizable')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
        expect(find.text('Remove from text'), findsOneWidget);
        await tester.tap(find.text('Remove from text'));
        await tester.pumpAndSettle();
        expect(image, findsNothing);
        root.undo();
        await tester.pumpAndSettle();
        expect(tester.getSize(image), originalSize);
        await tester.tap(image);
        await tester.pump();
        root.document.history.clear();
        final blockSnapshot = jsonEncode(root.document.toDelta().toJson());
        final drag = await tester.startGesture(tester.getCenter(handle));
        await drag.moveBy(const Offset(-48, -16));
        await tester.pump(const Duration(seconds: 5));
        expect(handle, findsOneWidget);
        await drag.moveBy(const Offset(-16, -16));
        await drag.up();
        await tester.pumpAndSettle();
        expect(tester.getSize(image).width, lessThan(originalSize.width));
        expect(handle.hitTestable(), findsOneWidget);
        expect(
          find
              .byKey(const ValueKey('attachment_options_resizable'))
              .hitTestable(),
          findsOneWidget,
        );
        root.undo();
        await tester.pumpAndSettle();
        expect(jsonEncode(root.document.toDelta().toJson()), blockSnapshot);
        expect(tester.getSize(image), originalSize);
        await tester.tap(image);
        await tester.pump();
        root.document.history.clear();
        final before = jsonEncode(root.document.toDelta().toJson());
        await tester.drag(handle, const Offset(32, 32));
        await tester.pumpAndSettle();
        final resized = tester.getSize(image);
        expect(resized.width, greaterThan(originalSize.width));
        expect(resized.height, resized.width / ratio);
        final saved = owner.document.toDelta().toJson().firstWhere(
          (op) => op['insert'] is Map,
        )['insert'][noteAttachmentEmbedType];
        expect(saved['width'], resized.width);
        expect(saved['src'], reference['src']);
        expect(saved['placement'], 'inline');
        expect(owner.document.toPlainText(), 'Before \n\uFFFC\n after\n');
        root.undo();
        await tester.pumpAndSettle();
        expect(jsonEncode(root.document.toDelta().toJson()), before);
        expect(tester.getSize(image), originalSize);
        root.readOnly = true;
        await tester.pumpWidget(
          _editor(root, editing, focus, note: note, rebuildOnController: false),
        );
        await tester.pumpAndSettle();
        expect(handle, findsNothing);
        expect(tester.getSize(image), originalSize);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 600));
        root.dispose();
        editing.dispose();
        focus.dispose();
      }
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
      final horizontal = tester
          .widget<SingleChildScrollView>(
            find.byKey(ValueKey('table_horizontal_${table.id}')),
          )
          .controller!;
      await tester.dragFrom(
        tester.getCenter(cells.first),
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(horizontal.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
      expect(cells.evaluate().length, lessThan(80));
      final snapshot = jsonEncode(root.document.toDelta().toJson());
      final parentScroll = Scrollable.of(
        tester.element(find.byType(NoteTableView)),
        axis: Axis.vertical,
      ).position;
      parentScroll.jumpTo(72 * 220);
      await tester.pumpAndSettle();
      expect(cells.evaluate().length, lessThan(80));
      expect(find.text('221'), findsOneWidget);
      final columnHeading = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  RegExp(r'^[A-Z]+$').hasMatch(widget.data ?? ''),
            ),
          )
          .first;
      expect(tester.getRect(columnHeading).top, greaterThanOrEqualTo(0));
      expect(find.text('1'), findsNothing);
      expect(jsonEncode(root.document.toDelta().toJson()), snapshot);
      expect(find.byKey(ValueKey('table_vertical_${table.id}')), findsNothing);
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
  bool rebuildOnController = true,
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
                  listenable: Listenable.merge([
                    editing,
                    if (rebuildOnController) root,
                  ]),
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
