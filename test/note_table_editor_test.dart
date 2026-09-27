import 'dart:convert';
import 'package:better_keep/state.dart';
import 'package:better_keep/pages/image_viewer.dart';
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
    expect(cellBounds.left, tableBounds.left + 22);
    expect(cellBounds.top, tableBounds.top + 22);
    expect(cellBounds.width, closeTo((tableBounds.width - 2 - 44) / 2, 0.1));
    await tester.tap(firstCell);
    await tester.pump();
    expect(tester.getRect(firstCell), cellBounds);
    void expectCenteredControls() {
      final bounds = tester.getRect(firstCell);
      for (final (axis, menuCenter, gripCenter) in [
        ('row', bounds.centerLeft, bounds.bottomCenter),
        ('column', bounds.topCenter, bounds.centerRight),
      ]) {
        final menu = find.byKey(ValueKey('table_${axis}_0'));
        final grip = find.byKey(ValueKey('table_resize_${axis}_0'));
        expect(tester.getCenter(menu), menuCenter);
        expect(tester.getCenter(grip), gripCenter);
        expect(tester.getSize(menu), const Size.square(44));
        // The outer half of each menu must remain tappable, not clipped.
        expect(
          menu.hitTestable(at: const Alignment(-0.8, -0.8)),
          findsOneWidget,
        );
      }
    }

    expectCenteredControls();
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byKey(const ValueKey('table_row_1')), findsNothing);
    final rowGrip = find.byKey(const ValueKey('table_resize_row_0'));
    final columnGrip = find.byKey(const ValueKey('table_resize_column_0'));
    expect(tester.getSize(rowGrip), const Size(56, 44));
    expect(tester.getSize(columnGrip), const Size(44, 56));
    for (final (grip, turns) in [(rowGrip, 0), (columnGrip, 1)]) {
      final rotated = tester.widget<RotatedBox>(
        find.descendant(of: grip, matching: find.byType(RotatedBox)),
      );
      expect(rotated.quarterTurns, turns);
      final face = rotated.child! as Container;
      expect(face.constraints!.biggest, const Size(28, 5));
    }
    AppState.tableHeaders = true;
    await tester.pumpAndSettle();
    expectCenteredControls();
    AppState.tableHeaders = false;
    await tester.pumpAndSettle();

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
    'a sole cell image is centered until a paragraph is added above or below',
    (tester) async {
      final attachment = NoteAttachment.sketch(SketchData(aspectRatio: 4));
      final reference = {...attachmentReference(attachment), 'id': 'centered'};
      final table = NoteTableData(rows: 1, columns: 1, rowHeights: {0: 260});
      final note = Note(attachments: [attachment]);
      final root = _controller(table);
      final editing = NoteEmbedEditing()..rootController = root;
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      final cellFinder = find.descendant(
        of: find.byType(NoteTableView),
        matching: find.byType(QuillEditor),
      );
      final cell = tester.widget<QuillEditor>(cellFinder);
      insertNoteEmbed(
        cell.controller,
        noteAttachmentEmbedType,
        reference,
        block: true,
      );
      expect(cell.controller.document.toPlainText(), '\uFFFC\n');
      await tester.pumpAndSettle();
      final saved = jsonEncode(root.document.toDelta().toJson());
      final image = find.byKey(const ValueKey('attachment_image_centered'));
      void expectCentered() {
        final center = tester.getCenter(cellFinder);
        expect(tester.getCenter(image).dx, closeTo(center.dx, 0.5));
        expect(tester.getCenter(image).dy, closeTo(center.dy, 0.5));
        expect(
          tester
              .widget<QuillEditor>(cellFinder)
              .scrollController
              .position
              .maxScrollExtent,
          closeTo(0, 0.5),
        );
      }

      expectCentered();
      // The space around a centered image still focuses text editing.
      await tester.tapAt(tester.getTopLeft(cellFinder) + const Offset(16, 30));
      await tester.pumpAndSettle();
      expect(cell.focusNode.hasPrimaryFocus, isTrue);
      expect(find.text('Preview image'), findsNothing);
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      for (final before in [true, false]) {
        for (final text in ['\n', 'Surrounding text\n']) {
          root.document.history.clear();
          cell.controller.replaceText(before ? 0 : 1, 0, text, null);
          await tester.pumpAndSettle();
          expect(
            tester.getCenter(image).dy,
            lessThan(tester.getCenter(cellFinder).dy - 20),
          );
          expect(cell.controller.document.toPlainText(), contains(text));
          if (text == '\n') {
            root.document.history.clear();
            cell.controller.updateSelection(
              TextSelection.collapsed(offset: before ? 1 : 2),
              ChangeSource.local,
            );
            Actions.invoke(
              cell.focusNode.context!,
              const DeleteCharacterIntent(forward: false),
            );
            await tester.pumpAndSettle();
            expect(cell.controller.document.toPlainText(), '\uFFFC\n');
            expectCentered();
            root.undo();
            await tester.pumpAndSettle();
            expect(
              cell.controller.document.toPlainText(),
              before ? '\n\uFFFC\n' : '\uFFFC\n\n',
            );
            root.redo();
          } else {
            root.undo();
          }
          await tester.pumpAndSettle();
          expectCentered();
          expect(jsonEncode(root.document.toDelta().toJson()), saved);
        }
      }
      // The last column's matching grip remains usable beyond its border.
      cell.focusNode.requestFocus();
      await tester.pumpAndSettle();
      root.document.history.clear();
      final width = tester.getSize(cellFinder).width;
      final viewport = find.byKey(ValueKey('table_horizontal_${table.id}'));
      final horizontal = tester
          .widget<SingleChildScrollView>(viewport)
          .controller!;
      expect(horizontal.position.maxScrollExtent, 0);
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('table_resize_column_0'))) +
            const Offset(16, 20),
        const Offset(24, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(cellFinder).width, closeTo(width + 24, 0.1));
      expectCentered();
      expect(horizontal.offset, 0);
      root.undo();
      await tester.pumpAndSettle();
      expectCentered();
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      root.readOnly = true;
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      expectCentered();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'tapping a sole cell image selects the cell and reveals table controls',
    (tester) async {
      final attachment = NoteAttachment.sketch(SketchData(aspectRatio: 4));
      final reference = {...attachmentReference(attachment), 'id': 'control'};
      final table = NoteTableData(rows: 2, columns: 2, rowHeights: {0: 200})
          .withCell(0, 0, [
            {
              'insert': {noteAttachmentEmbedType: reference},
            },
            {'insert': '\n'},
          ]);
      final note = Note(attachments: [attachment]);
      final root = _controller(table);
      final editing = NoteEmbedEditing()..rootController = root;
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      final image = find.byKey(const ValueKey('attachment_image_control'));
      expect(image, findsOneWidget);
      final cellFinder = find
          .descendant(
            of: find.byType(NoteTableView),
            matching: find.byType(QuillEditor),
          )
          .first;
      expect(find.byKey(const ValueKey('table_row_0')), findsNothing);
      expect(find.byKey(const ValueKey('table_column_0')), findsNothing);

      // The note editor owns focus while the user picks the cell by its image.
      focus.requestFocus();
      await tester.pump();

      await tester.tap(image);
      await tester.pumpAndSettle();
      // The first tap only selects the cell; the image menu stays closed.
      expect(find.text('Preview image'), findsNothing);
      expect(
        editing.controller,
        same(tester.widget<QuillEditor>(cellFinder).controller),
      );
      expect(find.byKey(const ValueKey('table_row_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('table_column_0')), findsOneWidget);

      // A second tap on the now-active cell opens the image menu without moving
      // focus, so the cell stays selected when the menu is dismissed.
      await tester.tap(image);
      await tester.pumpAndSettle();
      expect(find.text('Preview image'), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('Preview image'), findsNothing);
      expect(find.byKey(const ValueKey('table_row_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('table_column_0')), findsOneWidget);
      expect(
        editing.controller,
        same(tester.widget<QuillEditor>(cellFinder).controller),
      );

      // Read-only cells cannot be selected, so the image menu opens directly
      // and no table controls appear.
      root.readOnly = true;
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('attachment_image_control')));
      await tester.pumpAndSettle();
      expect(find.text('Preview image'), findsOneWidget);
      expect(find.byKey(const ValueKey('table_row_0')), findsNothing);
      expect(find.byKey(const ValueKey('table_column_0')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'cell images fit remaining text height, preview, and follow attachment updates',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAECAYAAABP2FU6AAAAEElEQVR4nGPQW7DiPwMqAQBdZgnVHK1lFQAAAABJRU5ErkJggg==',
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
      final reference = {...attachmentReference(attachment), 'width': 120.0};
      final table = NoteTableData(rows: 1, columns: 1, rowHeights: {0: 280})
          .withCell(0, 0, [
            {
              'insert': 'A rich heading',
              'attributes': {'bold': true, 'size': 'large'},
            },
            {'insert': '\nWrapped text before the images\n'},
            {
              'insert': {noteAttachmentEmbedType: reference},
            },
            {'insert': '\n'},
            {
              'insert': {
                noteAttachmentEmbedType: {...reference, 'id': 'cell-second'},
              },
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
      final editing = NoteEmbedEditing()..rootController = root;
      final focus = FocusNode();
      addTearDown(() {
        root.dispose();
        editing.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      expect(find.byType(UniversalImage), findsNWidgets(3));
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
      final cell = tester.widget<QuillEditor>(cellFinder);
      void expectImagesFit() {
        final bounds = tester.getRect(cellFinder).deflate(7.9);
        for (final element in imageFinder.evaluate()) {
          final image = tester.getRect(find.byWidget(element.widget));
          expect(
            bounds.contains(image.topLeft),
            isTrue,
            reason: '$image in $bounds',
          );
          expect(
            bounds.contains(image.bottomRight),
            isTrue,
            reason: '$image in $bounds',
          );
          expect(image.width, closeTo(image.height / 4, 0.1));
        }
        expect(cell.scrollController.position.maxScrollExtent, closeTo(0, 0.5));
      }

      expectImagesFit();
      final originalHeight = tester.getSize(imageFinder.first).height;
      final saved = jsonEncode(root.document.toDelta().toJson());
      root.document.history.clear();
      cell.controller.replaceText(0, 0, 'Extra line\n', null);
      await tester.pumpAndSettle();
      expectImagesFit();
      expect(
        tester.getSize(imageFinder.first).height,
        lessThan(originalHeight),
      );
      root.undo();
      await tester.pumpAndSettle();
      expectImagesFit();
      expect(
        tester.getSize(imageFinder.first).height,
        closeTo(originalHeight, 0.1),
      );
      expect(jsonEncode(root.document.toDelta().toJson()), saved);

      // The final row's hit area remains usable below its bottom border.
      await tester.tapAt(tester.getTopLeft(cellFinder) + const Offset(20, 20));
      await tester.pumpAndSettle();
      root.document.history.clear();
      await tester.dragFrom(
        tester.getCenter(find.byKey(const ValueKey('table_resize_row_0'))) +
            const Offset(20, 16),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expectImagesFit();
      expect(
        tester.getSize(imageFinder.first).height,
        closeTo(originalHeight + 20, 0.1),
      );
      root.undo();
      await tester.pumpAndSettle();
      expectImagesFit();
      expect(jsonEncode(root.document.toDelta().toJson()), saved);

      await tester.tap(imageFinder.first);
      await tester.pumpAndSettle();
      expect(find.text('Preview image'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(
        find.byKey(ValueKey('attachment_resize_${reference['id']}')),
        findsNothing,
      );
      await tester.tap(find.text('Preview image'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ImageViewer>(find.byType(ImageViewer)).image.src,
        '/old.png',
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      attachment.type = AttachmentType.sketch;
      attachment.sketch = SketchData(
        previewImage: '/new.png',
        strokesFilePath: '/strokes.json',
        aspectRatio: 0.25,
      );
      attachment.image = null;
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      for (final element in find.byType(UniversalImage).evaluate()) {
        expect((element.widget as UniversalImage).path, '/new.png');
      }
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      await tester.pumpAndSettle();
      expectImagesFit();
      root.readOnly = true;
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      await tester.pumpAndSettle();
      await tester.tap(imageFinder.first);
      await tester.pumpAndSettle();
      expect(find.text('Remove'), findsNothing);
      await tester.tap(find.text('Preview image'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ImageViewer>(find.byType(ImageViewer)).image.src,
        '/new.png',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(jsonEncode(root.document.toDelta().toJson()), saved);
      note.attachments.clear();
      await tester.pumpWidget(_editor(root, editing, focus, note: note));
      expect(find.byTooltip('Attachment unavailable'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      // Quill defers web caret work for the keyboard animation.
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'attachment resizing preserves block layout, aspect ratio, and undo outside tables',
    (tester) async {
      for (final ratio in [1.0, 4.0]) {
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
        final root = QuillController(
          document: documentFromJsonSafe(delta),
          selection: const TextSelection.collapsed(offset: 0),
        );
        final editing = NoteEmbedEditing()..rootController = root;
        final focus = FocusNode();
        await tester.pumpWidget(
          _editor(root, editing, focus, note: note, rebuildOnController: false),
        );
        await tester.pumpAndSettle();

        final image = find.byKey(const ValueKey('attachment_image_resizable'));
        final originalSize = tester.getSize(image);
        expect(originalSize, Size(120, 120 / ratio));
        expect(root.document.toPlainText(), 'Before \n\uFFFC\n after\n');
        final handle = find.byKey(
          const ValueKey('attachment_resize_resizable'),
        );
        expect(handle, findsNothing);
        final ownerEditor = find.byWidgetPredicate(
          (widget) =>
              widget is QuillEditor && identical(widget.controller, root),
        );
        expect(
          tester.getCenter(image).dx,
          closeTo(tester.getCenter(ownerEditor).dx, 0.1),
        );
        await tester.tap(image);
        await tester.pumpAndSettle();
        expect(handle, findsOneWidget);
        expect(find.text('Remove'), findsNothing);
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
        expect(find.text('Remove'), findsOneWidget);
        await tester.tap(find.text('Remove'));
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
        final saved = root.document.toDelta().toJson().firstWhere(
          (op) => op['insert'] is Map,
        )['insert'][noteAttachmentEmbedType];
        expect(saved['width'], resized.width);
        expect(saved['src'], reference['src']);
        expect(saved['placement'], 'inline');
        expect(root.document.toPlainText(), 'Before \n\uFFFC\n after\n');
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
