import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/note_find_controller.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/services/note_find_delta_composer.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('insertion preserves expanded selection and undoes atomically', () {
    final document = Document.fromDelta(Delta()..insert('hello world\n'));
    final controller = QuillController(
      document: document,
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    addTearDown(controller.dispose);
    final table = NoteTable.empty(id: 'id', rowCount: 2, columnCount: 2);

    final offset = NoteTableInsertion.insert(
      controller: controller,
      table: table,
    );

    expect(offset, 6);
    expect(document.toPlainText(), 'hello\n\uFFFC\n world\n');
    expect(
      document.toPlainText().replaceAll(RegExp(r'[\n\uFFFC]'), ''),
      'hello world',
    );

    controller.undo();
    expect(document.toPlainText(), 'hello world\n');
  });

  test('insertion isolates a table at both sides of a line boundary', () {
    final table = NoteTable.empty(id: 'id', rowCount: 1, columnCount: 1);
    for (final offset in [5, 6]) {
      final document = Document.fromDelta(Delta()..insert('first\nsecond\n'));
      final controller = QuillController(
        document: document,
        selection: TextSelection.collapsed(offset: offset),
      );

      NoteTableInsertion.insert(controller: controller, table: table);

      expect(document.toPlainText(), 'first\n\uFFFC\nsecond\n');
      controller.dispose();
    }
  });

  test('Tab from the final cell adds one row until the maximum', () {
    final table = NoteTable.empty(id: 'id', rowCount: 1, columnCount: 2);
    final document = Document.fromDelta(
      Delta()
        ..insert(NoteTableCodec.encodeInsert(table))
        ..insert('\n'),
    );
    final quill = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    final focus = FocusNode();
    final controller = NoteTableController(
      controller: quill,
      parentFocusNode: focus,
    );
    addTearDown(() {
      controller.dispose();
      quill.dispose();
      focus.dispose();
    });
    controller.activate(
      const NoteTableCellAddress(tableId: 'id', row: 0, column: 1),
    );

    controller.moveToNextCell(backwards: false);

    expect(controller.activeTable?.rowCount, 2);
    expect(controller.activeCell?.row, 1);
    expect(controller.activeCell?.column, 0);
  });

  test('deleting a table is immediately recoverable with Quill undo', () {
    final table = NoteTable.empty(id: 'id', rowCount: 1, columnCount: 1);
    final document = Document.fromDelta(
      Delta()
        ..insert(NoteTableCodec.encodeInsert(table))
        ..insert('\n'),
    );
    final quill = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    final focus = FocusNode();
    final controller = NoteTableController(
      controller: quill,
      parentFocusNode: focus,
    );
    addTearDown(() {
      controller.dispose();
      quill.dispose();
      focus.dispose();
    });
    controller.activate(
      const NoteTableCellAddress(tableId: 'id', row: 0, column: 0),
    );

    controller.deleteTable();
    expect(document.toPlainText(), '\n');

    quill.undo();
    expect(document.toPlainText(), '\uFFFC\n');
    expect(
      NoteTableCodec.tryDecodeInsert(document.toDelta().toList().first.data),
      table,
    );
  });

  test('mixed body and table replacements compose into one undo step', () {
    final table = NoteTable(
      id: 'table',
      rows: const [
        ['one one'],
      ],
    );
    final document = Document.fromDelta(
      Delta()
        ..insert('one\n')
        ..insert(NoteTableCodec.encodeInsert(table))
        ..insert('\none\n'),
    );
    final controller = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    const cell = NoteTableCellAddress(tableId: 'table', row: 0, column: 0);
    final plan = NoteFindReplacementPlan(
      edits: [
        NoteFindReplacementEdit(
          target: NoteFindTarget.body(const NoteSearchMatch(start: 0, end: 3)),
          replacement: 'body',
        ),
        NoteFindReplacementEdit(
          target: NoteFindTarget.table(
            match: const NoteSearchMatch(start: 0, end: 3),
            documentOffset: 4,
            cell: cell,
          ),
          replacement: 'cell',
        ),
        NoteFindReplacementEdit(
          target: NoteFindTarget.table(
            match: const NoteSearchMatch(start: 4, end: 7),
            documentOffset: 4,
            cell: cell,
          ),
          replacement: 'cell',
        ),
        NoteFindReplacementEdit(
          target: NoteFindTarget.body(const NoteSearchMatch(start: 6, end: 9)),
          replacement: 'body',
        ),
      ],
    );

    controller.compose(
      NoteFindDeltaComposer.build(document, plan),
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );

    final updated = NoteTableCodec.tryDecodeInsert(
      document
          .toDelta()
          .toList()
          .firstWhere((operation) => operation.data is Map)
          .data,
    );
    expect(document.toPlainText(), 'body\n\uFFFC\nbody\n');
    expect(updated?.rows, const [
      ['cell cell'],
    ]);

    controller.undo();
    expect(document.toPlainText(), 'one\n\uFFFC\none\n');
    expect(
      NoteTableCodec.tryDecodeInsert(
        document
            .toDelta()
            .toList()
            .firstWhere((operation) => operation.data is Map)
            .data,
      )?.rows,
      table.rows,
    );
  });

  test(
    'Find searches cells independently and builds a cell replacement',
    () async {
      final table = NoteTable(
        id: 'table',
        rows: const [
          ['alpha', 'beta alpha'],
        ],
      );
      final controller = NoteFindController(
        snapshot: () => (
          document: const NoteSearchDocument(text: 'body\uFFFC'),
          revision: 3,
        ),
        tableSnapshot: () => [NoteFindTableSnapshot(offset: 4, table: table)],
      );
      addTearDown(controller.dispose);

      controller.open(anchorOffset: 0, seed: 'alpha');
      await pumpEventQueue(times: 20);

      expect(controller.matchCount, 2);
      expect(controller.currentTarget?.cell?.column, 0);
      controller.replacementController.text = 'replaced';
      final request = await controller.buildReplacementRequest(
        replaceAll: false,
      );
      expect(request.revision, 3);
      expect(request.plan.edits.single.target.cell?.column, 0);
      expect(request.plan.edits.single.replacement, 'replaced');

      controller.queryController.text = 'alphabeta';
      controller.scheduleSearch(immediate: true);
      await pumpEventQueue(times: 20);
      expect(controller.matchCount, 0, reason: 'matches cannot span cells');
    },
  );
}
