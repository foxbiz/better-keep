import 'dart:convert';
import 'package:better_keep/pages/content_preview_page.dart';
import 'dart:ui' show PointerDeviceKind;

import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/embeds/note_table_embed.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  testWidgets(
    'table cells keep the main toolbar and keyboard focused on the cell',
    (tester) async {
      final table = NoteTableData(rows: 2, columns: 2);
      await _pumpNoteEditor(
        tester,
        bodyDelta: [
          {
            'insert': {NoteTableData.type: table.toJson()},
          },
          {'insert': '\nLast line from note\n'},
        ],
      );
      final cellFinder = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      await tester.tap(cellFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      final cell = tester.widget<QuillEditor>(cellFinder);
      // Browsers dispatch editing keys through their native text field, so
      // exercise the shared editing actions directly as well as Backspace.
      Future<void> editWith(Intent intent) async {
        Actions.invoke(cell.focusNode.context!, intent);
        await tester.pump();
      }

      final toolbar = tester.widget<NoteEditorToolbar>(
        find.byKey(const Key('note_editor_toolbar')),
      );
      expect(toolbar.controller, same(cell.controller));
      expect(cell.focusNode.hasPrimaryFocus, true);
      final root = tester.widget<QuillEditor>(find.byType(QuillEditor).first);
      final original = jsonEncode(root.controller.document.toDelta().toJson());
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await editWith(const DeleteCharacterIntent(forward: false));
      expect(cell.focusNode.hasPrimaryFocus, true);
      expect(cell.controller.document.toPlainText(), '\n');
      expect(jsonEncode(root.controller.document.toDelta().toJson()), original);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Table text\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();
      expect(root.config.showCursor, isFalse);
      expect(tester.widget<QuillEditor>(cellFinder).config.showCursor, isTrue);
      expect(
        noteDeltaPlainText(root.controller.document.toDelta().toJson()),
        contains('Table text'),
      );
      // Deletion and selection actions must use the cell's editing value.
      expect(root.focusNode.hasFocus, isFalse);
      await editWith(
        const ExtendSelectionByCharacterIntent(
          forward: false,
          collapseSelection: true,
        ),
      );
      expect(cell.controller.selection.baseOffset, 9);
      await editWith(const DeleteCharacterIntent(forward: true));
      expect(cell.controller.document.toPlainText(), 'Table tex\n');
      await editWith(const DeleteCharacterIntent(forward: false));
      expect(cell.controller.document.toPlainText(), 'Table te\n');
      await editWith(const SelectAllTextIntent(SelectionChangedCause.keyboard));
      expect(cell.controller.selection.start, 0);
      expect(cell.controller.selection.end, 8);
      await editWith(const DeleteCharacterIntent(forward: false));
      expect(cell.controller.document.toPlainText(), '\n');
      expect(jsonEncode(root.controller.document.toDelta().toJson()), original);
      root.controller.document.history.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Editable again\n',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();
      expect(cell.controller.document.toPlainText(), 'Editable again\n');
      Actions.invoke(
        cell.focusNode.context!,
        const UndoTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      await tester.pump();
      expect(cell.controller.document.toPlainText(), '\n');
      Actions.invoke(
        cell.focusNode.context!,
        const RedoTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      await tester.pump();
      expect(cell.controller.document.toPlainText(), 'Editable again\n');
      final rootSelection = root.controller.selection;
      await tester.tap(cellFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(cellFinder);
      await tester.pump();
      expect(cell.focusNode.hasPrimaryFocus, isTrue);
      expect(root.controller.selection, rootSelection);
      root.focusNode.requestFocus();
      await tester.pumpAndSettle();
      final mainToolbar = tester.widget<NoteEditorToolbar>(
        find.byKey(const Key('note_editor_toolbar')),
      );
      expect(mainToolbar.controller, same(root.controller));
      expect(
        tester
            .widget<QuillEditor>(find.byType(QuillEditor).first)
            .config
            .showCursor,
        isTrue,
      );
      expect(tester.widget<QuillEditor>(cellFinder).config.showCursor, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('focusing a table cell reveals its caret instead of the note end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final table = NoteTableData(rows: 8, columns: 2);
    await _pumpNoteEditor(
      tester,
      platform: TargetPlatform.android,
      bodyDelta: [
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {
          'insert':
              '\n${List.filled(40, 'Following paragraph').join('\n')}\nLast line\n',
        },
      ],
    );
    final root = tester.widget<QuillEditor>(find.byType(QuillEditor).first);
    final cells = find.descendant(
      of: find.byType(NoteTableView),
      matching: find.byType(QuillEditor),
    );
    final cell = tester.widget<QuillEditor>(cells.first);
    final scroll = root.scrollController;
    final original = root.controller.document.toDelta().toJson();
    expect(scroll.offset, 0);
    await tester.tap(cells.first);
    await tester.pumpAndSettle();
    expect(cell.focusNode.hasPrimaryFocus, isTrue);
    expect(scroll.offset, lessThan(100));
    final lowerCellFinder = cells.at(12);
    final lowerCell = tester.widget<QuillEditor>(lowerCellFinder);
    await tester.tap(lowerCellFinder);
    await tester.pumpAndSettle();
    expect(lowerCell.focusNode.hasPrimaryFocus, isTrue);
    final beforeKeyboard = scroll.offset;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(beforeKeyboard));
    final toolbarTop = tester
        .getRect(find.byKey(const Key('note_editor_toolbar')))
        .top;
    final caret = lowerCell.config.editorKey!.currentState!.renderEditor;
    final caretRect = caret.getLocalRectForCaret(const TextPosition(offset: 0));
    expect(caret.localToGlobal(caretRect.bottomLeft).dy, lessThan(toolbarTop));
    expect(tester.getRect(lowerCellFinder).bottom, greaterThan(100));
    // Returning from the note's end must cancel any pending parent-caret work.
    tester.view.viewInsets = const FakeViewPadding();
    root.focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(root.focusNode.hasPrimaryFocus, isTrue);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(cells.first);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(root.focusNode.hasFocus, isFalse);
    expect(
      tester.widget<QuillEditor>(cells.first).focusNode.hasPrimaryFocus,
      isTrue,
    );
    expect(scroll.offset, lessThan(100));
    expect(root.controller.document.toDelta().toJson(), original);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inserted tables stay block and taps return typing to the note', (
    tester,
  ) async {
    await _pumpNoteEditor(
      tester,
      bodyDelta: [
        {'insert': 'BeforeAfter\n'},
      ],
    );
    final root = tester.widget<QuillEditor>(find.byType(QuillEditor));
    root.focusNode.requestFocus();
    await tester.pumpAndSettle();
    root.controller.updateSelection(
      const TextSelection.collapsed(offset: 6),
      ChangeSource.local,
    );
    await tester.tap(find.byKey(const ValueKey('insert_table')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('table_picker_2_2')));
    await tester.pumpAndSettle();
    expect(root.controller.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
    expect((root.controller.document.queryChild(7).node as Line).childCount, 1);
    final table = find.byType(NoteTableView);
    final cells = find.descendant(
      of: table,
      matching: find.byType(QuillEditor),
    );
    expect(
      tester.getSize(table).width,
      closeTo(tester.getSize(find.byType(QuillEditor).first).width - 32, 0.1),
    );
    await tester.tap(cells.first);
    await tester.pump();
    expect(
      tester.widget<QuillEditor>(cells.first).focusNode.hasPrimaryFocus,
      isTrue,
    );
    final afterText = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == 'After',
    );
    await tester.tapAt(_globalTextPosition(tester, afterText, 2));
    await tester.pump();
    expect(root.focusNode.hasPrimaryFocus, isTrue);
    expect(
      tester
          .widget<NoteEditorToolbar>(
            find.byKey(const Key('note_editor_toolbar')),
          )
          .controller,
      same(root.controller),
    );
    // The table margin is also a reliable way to resume after the block.
    await tester.tap(cells.first);
    await tester.pump();
    await tester.tapAt(tester.getRect(table).bottomLeft + const Offset(36, 4));
    await tester.pump();
    expect(root.focusNode.hasPrimaryFocus, isTrue);
    expect(root.controller.selection.baseOffset, 9);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Before\n\uFFFC\nOutside After\n',
        selection: TextSelection.collapsed(offset: 17),
      ),
    );
    await tester.pump();
    expect(
      root.controller.document.toPlainText(),
      'Before\n\uFFFC\nOutside After\n',
    );
    expect(
      tester.widget<QuillEditor>(cells.first).controller.document.toPlainText(),
      '\n',
    );
    expect((root.controller.document.queryChild(7).node as Line).childCount, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
    'table-only and adjacent tables expose writing space around the grid',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final adjacent in [false, true]) {
        for (final before in [true, false]) {
          final table = NoteTableData(rows: 1, columns: 1);
          final neighbor = [
            {
              'insert': {
                NoteTableData.type: NoteTableData(rows: 1, columns: 1).toJson(),
              },
            },
            {'insert': '\n'},
          ];
          final tableDelta = [
            if (adjacent && before) ...neighbor,
            {
              'insert': {NoteTableData.type: table.toJson()},
            },
            {'insert': '\n'},
            if (adjacent && !before) ...neighbor,
          ];
          await _pumpNoteEditor(tester, bodyDelta: tableDelta);
          final root = tester.widget<QuillEditor>(
            find.byType(QuillEditor).first,
          );
          final owner = root;
          final original = adjacent ? '\uFFFC\n\uFFFC\n' : '\uFFFC\n';
          expect(owner.controller.document.toPlainText(), original);
          final cell = find
              .descendant(
                of: find.byKey(ValueKey(table.id)),
                matching: find.byType(QuillEditor),
              )
              .first;
          final boundary = find.byKey(
            ValueKey('table_${before ? 'before' : 'after'}_${table.id}'),
          );
          expect(tester.getSize(boundary).height, greaterThanOrEqualTo(40));
          await tester.tap(cell);
          await tester.pump();
          root.controller.document.history.clear();
          await tester.tap(boundary);
          await tester.pump();
          expect(owner.focusNode.hasPrimaryFocus, isTrue);
          expect(
            tester
                .widget<NoteEditorToolbar>(
                  find.byKey(const Key('note_editor_toolbar')),
                )
                .controller,
            same(owner.controller),
          );
          final prefix = adjacent && before ? '\uFFFC\n' : '';
          final suffix = adjacent && !before ? '\uFFFC\n' : '';
          final blankParagraph =
              '$prefix${before ? '\n\uFFFC\n' : '\uFFFC\n\n'}$suffix';
          expect(owner.controller.document.toPlainText(), blankParagraph);
          // Repeated and rapid taps reuse the paragraph, including after returning from a cell.
          await tester.tap(boundary);
          await tester.pump();
          expect(owner.controller.document.toPlainText(), blankParagraph);
          final text =
              '$prefix${before ? 'Before\n\uFFFC\n' : '\uFFFC\nAfter\n'}$suffix';
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(
                offset: prefix.length + (before ? 6 : 7),
              ),
            ),
          );
          await tester.pump();
          expect(owner.controller.document.toPlainText(), text);
          expect(
            tester.widget<QuillEditor>(cell).controller.document.toPlainText(),
            '\n',
          );
          root.controller.undo();
          await tester.pump();
          await tester.pump();
          expect(owner.controller.document.toPlainText(), original);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 600));
        }
      }
    },
  );

  testWidgets(
    'table scrollbar stays in its gutter before focus and fades when idle',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 96);
      tester.view.viewPadding = const FakeViewPadding(bottom: 96);
      addTearDown(tester.view.reset);
      final table = NoteTableData(rows: 1, columns: 6);
      await _pumpNoteEditor(
        tester,
        platform: TargetPlatform.android,
        bodyDelta: [
          {
            'insert': {NoteTableData.type: table.toJson()},
          },
          {'insert': '\nFollowing text\n'},
        ],
      );
      await tester.pumpAndSettle();
      final root = tester.widget<QuillEditor>(find.byType(QuillEditor).first);
      final viewport = find.byKey(ValueKey('table_horizontal_${table.id}'));
      final horizontal = tester
          .widget<SingleChildScrollView>(viewport)
          .controller!;
      final bar = find.byKey(
        ValueKey('table_horizontal_scrollbar_${table.id}'),
      );
      final paint = find.descendant(
        of: bar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        ),
      );
      ScrollbarPainter painter() =>
          tester.widget<CustomPaint>(paint).foregroundPainter!
              as ScrollbarPainter;
      void expectThumbBelowGrid() {
        final box = tester.renderObject<RenderBox>(paint);
        final gutter =
            tester.getRect(viewport).bottomLeft + const Offset(50, 8);
        expect(
          painter().hitTestOnlyThumbInteractive(
            box.globalToLocal(gutter),
            PointerDeviceKind.mouse,
          ),
          isTrue,
        );
        expect(
          tester.getRect(bar).bottom - tester.getRect(viewport).bottom,
          16,
        );
      }

      // Exercise the thumb before any editor focus, with a device bottom inset.
      horizontal.jumpTo(12);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(root.focusNode.hasFocus, isFalse);
      expectThumbBelowGrid();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(painter().fadeoutOpacityAnimation.value, 0);
      final cell = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      await tester.tap(cell);
      tester.view.padding = const FakeViewPadding();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      horizontal.jumpTo(24);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expectThumbBelowGrid();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'only visible resize grips change dimensions while borders allow scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(420, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final data = NoteTableData(
        rows: 8,
        columns: 4,
        columnWidths: {for (var c = 0; c < 4; c++) c: 160},
      );
      await _pumpNoteEditor(
        tester,
        bodyDelta: [
          {
            'insert': {NoteTableData.type: data.toJson()},
          },
          {
            'insert':
                '\n${List.filled(30, 'Following paragraph').join('\n')}\n',
          },
        ],
      );
      final root = tester.widget<QuillEditor>(find.byType(QuillEditor).first);
      final firstCell = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      final horizontal = tester
          .widget<SingleChildScrollView>(
            find.byKey(ValueKey('table_horizontal_${data.id}')),
          )
          .controller!;
      final viewport = find.byKey(ValueKey('table_horizontal_${data.id}'));
      final horizontalBar = find.byKey(
        ValueKey('table_horizontal_scrollbar_${data.id}'),
      );
      final verticalBar = find.byKey(
        ValueKey('table_vertical_scrollbar_${data.id}'),
      );
      expect(
        tester.getRect(horizontalBar).bottom - tester.getRect(viewport).bottom,
        16,
      );
      expect(verticalBar, findsNothing);
      expect(tester.getSize(viewport).height, greaterThanOrEqualTo(8 * 72));
      final original = jsonEncode(root.controller.document.toDelta().toJson());
      for (final focused in [false, true]) {
        if (focused) {
          await tester.tap(firstCell);
          await tester.pumpAndSettle();
        }
        final bounds = tester.getRect(firstCell);
        // Border sections outside the visible grips must never resize cells.
        await tester.dragFrom(
          Offset(bounds.right - 1, bounds.top + 6),
          const Offset(6, -50),
        );
        await tester.pumpAndSettle();
        expect(
          jsonEncode(root.controller.document.toDelta().toJson()),
          original,
        );
        root.scrollController.jumpTo(0);
        horizontal.jumpTo(0);
        await tester.pumpAndSettle();
        final resetBounds = tester.getRect(firstCell);
        await tester.dragFrom(
          Offset(resetBounds.left + 6, resetBounds.bottom - 1),
          const Offset(-60, 6),
        );
        await tester.pumpAndSettle();
        expect(
          jsonEncode(root.controller.document.toDelta().toJson()),
          original,
        );
        root.scrollController.jumpTo(0);
        horizontal.jumpTo(0);
        await tester.pumpAndSettle();
      }
      await tester.tap(firstCell);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table_resize_column_1')), findsNothing);
      expect(find.byKey(const ValueKey('table_resize_row_1')), findsNothing);
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        final before = tester.getRect(firstCell);
        // A diagonal drag beginning on the visible control belongs to resizing.
        final column = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('table_resize_column_0'))),
          kind: kind,
        );
        await column.moveBy(const Offset(6, -50));
        await tester.pump();
        await column.up();
        await tester.pump();
        expect(tester.getSize(firstCell).width, closeTo(before.width + 6, 0.1));
        final row = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('table_resize_row_0'))),
          kind: kind,
        );
        await row.moveBy(const Offset(-60, 6));
        await tester.pump();
        await row.up();
        await tester.pump();
        expect(
          tester.getSize(firstCell).height,
          closeTo(before.height + 6, 0.1),
        );
        final saved = NoteTableData.fromJson(
          (root.controller.document.toDelta().first.data
              as Map)[NoteTableData.type],
        );
        expect(saved.columnWidths[0], closeTo(before.width + 6, 0.1));
        expect(saved.rowHeights[0], closeTo(before.height + 6, 0.1));
        expect(root.scrollController.offset, 0);
        expect(horizontal.offset, 0);
      }
      // Ordinary swipes through a cell's body still scroll wide tables.
      await tester.dragFrom(tester.getCenter(firstCell), const Offset(-60, 0));
      await tester.pumpAndSettle();
      expect(horizontal.offset, greaterThan(0));
      horizontal.jumpTo(0);
      await tester.pumpAndSettle();
      final gridBounds = tester.getRect(viewport);
      await tester.dragFrom(
        Offset(gridBounds.left + 30, gridBounds.bottom + 8),
        const Offset(50, 0),
      );
      await tester.pumpAndSettle();
      expect(horizontal.offset, greaterThan(0));
      final noteScroll = Scrollable.of(
        tester.element(find.byType(NoteTableView)),
        axis: Axis.vertical,
      ).position;
      final previousOffset = noteScroll.pixels;
      await tester.dragFrom(tester.getCenter(firstCell), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(noteScroll.pixels, greaterThan(previousOffset));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'Paste as formatted inserts tables in notes and rich text in cells',
    (tester) async {
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpNoteEditor(
        tester,
        bodyDelta: [
          {'insert': 'BeforeAfter\n'},
        ],
      );
      final root = tester.widget<QuillEditor>(find.byType(QuillEditor));
      final offset =
          root.controller.document.toPlainText().indexOf('BeforeAfter') + 6;
      root.controller.updateSelection(
        TextSelection.collapsed(offset: offset),
        ChangeSource.local,
      );

      Future<void> pasteTable() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {
                  'text':
                      '| **Task** | Status |\n| --- | --- |\n| Build | Ready |',
                }
              : null,
        );
        await tester.tap(
          find.byKey(const ValueKey('note_editor_overflow_menu')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Paste as'));
        await tester.tap(find.text('Paste as'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Formatted text'));
        await tester.pumpAndSettle();
        expect(find.byType(ContentPreviewPage), findsOneWidget);
        expect(find.byType(NoteTableView), findsOneWidget);
        final preview = tester.widget<NoteTableView>(
          find.byType(NoteTableView),
        );
        expect(preview.readOnly, isTrue);
        expect(preview.table.cell(1, 0).first['insert'], 'Build');
        await tester.tap(find.byTooltip('Insert'));
        await tester.pumpAndSettle();
        expect(find.byType(ContentPreviewPage), findsNothing);
      }

      await pasteTable();
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(
        root.controller.document.toPlainText(),
        contains('Before\n\uFFFC\nAfter'),
      );
      final cellFinder = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .last;
      await tester.tap(cellFinder);
      await tester.pump();
      final cell = tester.widget<QuillEditor>(cellFinder);
      cell.controller.updateSelection(
        const TextSelection.collapsed(offset: 5),
        ChangeSource.local,
      );
      root.controller.document.history.clear();
      await pasteTable();
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(
        cell.controller.document.toPlainText(),
        contains('ReadyTask\nStatus\nBuild\nReady\n'),
      );
      expect(
        cell.controller.document
            .toDelta()
            .toList()
            .where((op) => op.data == 'Task')
            .single
            .attributes,
        {'bold': true},
      );
      root.controller.undo();
      await tester.pump();
      await tester.pump();
      expect(cell.controller.document.toPlainText(), 'Ready\n');
      expect(find.byType(NoteTableView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets('blank space focuses short notes at the document end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final lines in const [
      ['One line'],
      ['First line', 'Second line'],
    ]) {
      await _pumpNoteEditor(
        tester,
        bodyDelta: [
          for (final line in lines) {'insert': '$line\n'},
        ],
      );
      final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      final surface = tester.getRect(
        find.byKey(const ValueKey('note_editor_scroll_surface')),
      );
      final editorRect = tester.getRect(find.byType(QuillEditor));
      expect(surface.bottom, greaterThan(editorRect.bottom + 40));
      expect(editor.focusNode.hasFocus, isFalse);

      await tester.tapAt(Offset(surface.center.dx, surface.bottom - 24));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(editor.focusNode.hasFocus, isTrue);
      expect(
        editor.controller.selection,
        TextSelection.collapsed(offset: editor.controller.document.length - 1),
      );
      expect(find.byKey(const Key('note_editor_toolbar')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('text and title taps keep their native focus behavior', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'First line\nSecond line\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));

    await tester.tap(find.text('First line', findRichText: true));
    await tester.pump();
    expect(editor.focusNode.hasFocus, isTrue);
    expect(
      editor.controller.selection.baseOffset,
      lessThan('First line'.length + 1),
    );

    final title = tester.widget<TextField>(find.byType(TextField).first);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(title.focusNode?.hasFocus, isTrue);
    expect(editor.focusNode.hasFocus, isFalse);
  });

  testWidgets('vertical selection restarts from an arrow-collapsed caret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'first line\nsecond line\nthird line\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final editorState = editor.config.editorKey!.currentState!;
    final lastLineCaret = editor.controller.document.length - 1;
    editor.controller.updateSelection(
      TextSelection.collapsed(offset: lastLineCaret),
      ChangeSource.local,
    );
    editor.focusNode.requestFocus();
    await tester.pump();

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(editor.controller.selection.isCollapsed, isFalse);
    final selectionBeforeCollapse = editor.controller.selection;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final collapsedCaret = editor.controller.selection;
    expect(
      collapsedCaret,
      TextSelection.collapsed(offset: selectionBeforeCollapse.end),
    );
    final expectedRun = editorState.renderEditor.startVerticalCaretMovement(
      collapsedCaret.extent,
    )..movePrevious();

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(editor.controller.selection.baseOffset, collapsedCaret.baseOffset);
    expect(
      editor.controller.selection.extentOffset,
      expectedRun.current.offset,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('selection keys work in read-only and trashed normal notes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final state in const [
      (readOnly: true, trashed: false),
      (readOnly: false, trashed: true),
    ]) {
      await _pumpNoteEditor(
        tester,
        readOnly: state.readOnly,
        trashed: state.trashed,
        bodyDelta: const [
          {'insert': 'first line\nsecond line\nthird line\n'},
        ],
      );
      final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      editor.focusNode.requestFocus();
      editor.controller.updateSelection(
        const TextSelection(baseOffset: 2, extentOffset: 25),
        ChangeSource.local,
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        editor.controller.selection,
        const TextSelection.collapsed(offset: 25),
      );

      editor.controller.updateSelection(
        const TextSelection(baseOffset: 25, extentOffset: 2),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        editor.controller.selection,
        const TextSelection.collapsed(offset: 2),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('desktop link taps focus the exact link and show its preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const linkText = 'Linked text';
    const url = 'https://example.invalid/link';
    await _pumpNoteEditor(
      tester,
      platform: TargetPlatform.macOS,
      bodyDelta: const [
        {
          'insert': linkText,
          'attributes': {'link': url},
        },
        {'insert': '\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(editor.config.customRecognizerBuilder, isNotNull);
    final linkedText = find.text(linkText, findRichText: true);
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 41,
    );
    addTearDown(mouse.removePointer);

    var linkPosition = _globalTextPosition(tester, linkedText, 1);
    await mouse.addPointer(location: linkPosition);
    await mouse.down(linkPosition);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    final firstOffset = editor.controller.selection.baseOffset;
    expect(editor.focusNode.hasFocus, isTrue);
    expect(firstOffset, inInclusiveRange(0, linkText.length - 1));
    expect(
      editor.controller.document
          .collectStyle(firstOffset, 1)
          .attributes[Attribute.link.key]
          ?.value,
      url,
    );
    expect(
      find.byKey(const ValueKey('note_editor_link_preview')),
      findsOneWidget,
    );
    expect(find.text(url), findsWidgets);

    linkPosition = _globalTextPosition(tester, linkedText, 8);
    await mouse.moveTo(linkPosition);
    await mouse.down(linkPosition);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    final secondOffset = editor.controller.selection.baseOffset;
    expect(secondOffset, inInclusiveRange(0, linkText.length - 1));
    expect(secondOffset, greaterThan(firstOffset));
    expect(find.text(url), findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('note_editor_link_preview')),
      findsOneWidget,
    );
    expect(find.text(url), findsWidgets);
  });

  testWidgets('mobile editors keep Flutter Quill link gestures', (
    tester,
  ) async {
    for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
      await _pumpNoteEditor(
        tester,
        platform: platform,
        bodyDelta: const [
          {
            'insert': 'Mobile link',
            'attributes': {'link': 'https://example.invalid/mobile'},
          },
          {'insert': '\n'},
        ],
      );

      expect(
        tester
            .widget<QuillEditor>(find.byType(QuillEditor))
            .config
            .customRecognizerBuilder,
        isNull,
        reason: '$platform should retain Flutter Quill link gestures',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('Add Link renders, cancels, inserts, and restores focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
    );

    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    var dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.controller.document.toPlainText(), '\n');

    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    dialog = find.byType(AlertDialog);
    final fields = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'Example');
    await tester.enterText(fields.last, 'https://example.com');
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, 'Add'),
      ),
    );
    await tester.pumpAndSettle();

    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.controller.document.toDelta().toJson(), [
      {
        'insert': 'Example',
        'attributes': {'link': 'https://example.com'},
      },
      {'insert': '\n'},
    ]);
    harness.controller.undo();
    await tester.pump();
    expect(harness.controller.document.toPlainText(), '\n');
  });

  testWidgets('scrolling is not treated as an empty-space tap', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: [
        {'insert': List.generate(80, (index) => 'Line $index').join('\n')},
        {'insert': '\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    await tester.pump();

    final surface = find.byKey(const ValueKey('note_editor_scroll_surface'));
    await tester.drag(surface, const Offset(0, -300));
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: surface,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable.first).position.pixels,
      greaterThan(0),
    );
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
  });

  testWidgets('attachment taps keep their navigation gesture', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'Body\n'},
      ],
      attachments: [NoteAttachment.sketch(SketchData())],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final sketch = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is SketchPainter,
    );

    expect(editor.focusNode.hasFocus, isFalse);
    await tester.tap(sketch.first);
    await tester.pumpAndSettle();

    expect(find.byType(SketchPage), findsOneWidget);
    expect(editor.focusNode.hasFocus, isFalse);
  });

  testWidgets('line spacing can be applied and removed from an indent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document.fromJson(const [
        {'insert': 'Indented'},
        {
          'insert': '\n',
          'attributes': {'indent': 1},
        },
      ]),
      selection: const TextSelection.collapsed(offset: 2),
    );

    await tester.tap(find.byTooltip('Line Spacing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Relaxed'));
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().last, {
      'insert': '\n',
      'attributes': {'indent': 1, 'line-height': 1.5},
    });

    await tester.tap(find.byTooltip('Line Spacing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Spacing'));
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().last, {
      'insert': '\n',
      'attributes': {'indent': 1},
    });
    expect(harness.focusNode.hasFocus, isTrue);
  });

  testWidgets('Link toolbar converts, updates, and removes selected text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const text = 'Selected text';
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document.fromJson(const [
        {
          'insert': text,
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: text.length),
    );

    await _submitLinkDialog(
      tester,
      action: 'Add',
      url: 'https://example.com/first',
    );
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
      'link': 'https://example.com/first',
    });

    harness.controller.updateSelection(
      const TextSelection.collapsed(offset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await _submitLinkDialog(
      tester,
      action: 'Update',
      url: 'https://example.com/updated',
    );
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
      'link': 'https://example.com/updated',
    });

    harness.controller.updateSelection(
      const TextSelection.collapsed(offset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Remove Link'),
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
    });
    expect(harness.focusNode.hasFocus, isTrue);
  });
}

Offset _globalTextPosition(
  WidgetTester tester,
  Finder richText,
  int textOffset,
) {
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final caret = paragraph.getOffsetForCaret(
    TextPosition(offset: textOffset),
    Rect.zero,
  );
  return paragraph.localToGlobal(caret + const Offset(1, 8));
}

Future<void> _pumpNoteEditor(
  WidgetTester tester, {
  required List<Map<String, dynamic>> bodyDelta,
  List<NoteAttachment> attachments = const [],
  TargetPlatform platform = TargetPlatform.macOS,
  bool readOnly = false,
  bool trashed = false,
}) async {
  final content = jsonEncode([
    {'insert': 'Interaction note'},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
    ...bodyDelta,
  ]);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      locale: const Locale('en'),
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: NoteEditor(
        note: Note(
          title: 'Interaction note',
          content: content,
          attachments: attachments,
          readOnly: readOnly,
          trashed: trashed,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<({QuillController controller, FocusNode focusNode})> _pumpToolbarHarness(
  WidgetTester tester, {
  required Document document,
  required TextSelection selection,
}) async {
  final controller = QuillController(document: document, selection: selection);
  final focusNode = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focusNode.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.macOS),
      locale: const Locale('en'),
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: QuillEditor.basic(
                controller: controller,
                focusNode: focusNode,
              ),
            ),
            NoteEditorToolbar(
              controller: controller,
              focusNode: focusNode,
              readOnly: false,
              parentColor: Colors.white,
              showHistory: false,
              showAttachments: false,
              showChecklist: false,
              showBlockLists: false,
              showIndent: false,
            ),
          ],
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  return (controller: controller, focusNode: focusNode);
}

Future<void> _submitLinkDialog(
  WidgetTester tester, {
  required String action,
  required String url,
}) async {
  await tester.tap(find.byTooltip('Link'));
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  final fields = find.descendant(of: dialog, matching: find.byType(TextField));
  await tester.enterText(fields.last, url);
  await tester.tap(
    find.descendant(
      of: dialog,
      matching: find.widgetWithText(FilledButton, action),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _sendShiftArrow(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(arrow);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}
