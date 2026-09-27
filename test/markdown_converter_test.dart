import 'package:better_keep/dialogs/paste_dialog.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/utils/markdown_converter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Markdown tables retain rich cells, alignment, escaped pipes and surrounding text',
    () {
      final delta = MarkdownConverter.markdownToQuillDelta(
        [
          'Before',
          '',
          '| Name | Details |',
          '| :--- | ---: |',
          r'| **_Bold_** | [Docs](https://example.com) and `a\|b` |',
          '| Short |',
          '',
          'After',
        ].join('\r\n'),
      );
      final table = NoteTableData.fromJson(
        delta.firstWhere(
          (op) => op['insert'] is Map,
        )['insert'][NoteTableData.type],
      );
      expect(table.rows, 3);
      expect(table.columns, 2);
      expect(table.cell(0, 0).first, {
        'insert': 'Name',
        'attributes': {'bold': true},
      });
      expect(table.cell(1, 0).first['attributes'], {
        'bold': true,
        'italic': true,
      });
      expect(table.cell(1, 0).last['attributes'], {'align': 'left'});
      expect(table.cell(1, 1).first['attributes'], {
        'link': 'https://example.com',
      });
      expect(table.cell(1, 1).firstWhere((op) => op['insert'] == 'a|b'), {
        'insert': 'a|b',
        'attributes': {'code': true},
      });
      expect(table.cell(1, 1).last['attributes'], {'align': 'right'});
      expect(table.cell(2, 1).single['insert'], '\n');
      expect(noteDeltaPlainText(delta), startsWith('Before\n'));
      expect(noteDeltaPlainText(delta), endsWith('After\n'));
      final withoutOuterPipes = MarkdownConverter.markdownToQuillDelta(
        'One | Two\n--- | ---\n1 | 2',
      );
      expect(withoutOuterPipes.first['insert'], contains(NoteTableData.type));
    },
  );

  test('invalid, oversized and fenced table source stays intact as text', () {
    for (final source in [
      '| One | Two |\n| --- |\n| 1 | 2 |',
      '```md\n| One | Two |\n| --- | --- |\n| 1 | 2 |\n```',
      '~~~md\n| One | Two |\n| --- | --- |\n| 1 | 2 |\n~~~',
      '| One | Two |\n| --- | --- |\n${List.filled(256, '| 1 | 2 |').join('\n')}',
    ]) {
      final delta = MarkdownConverter.markdownToQuillDelta(source);
      expect(delta.every((op) => op['insert'] is String), isTrue);
      expect(noteDeltaPlainText(delta), contains('| 1 | 2 |'));
    }
  });

  test(
    'formatted table paste splits the paragraph and undoes as one insertion',
    () {
      final controller = QuillController(
        document: Document()..insert(0, 'BeforeAfter'),
        selection: const TextSelection.collapsed(offset: 6),
      );
      final incoming = MarkdownConverter.markdownToDocument(
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );
      addTearDown(controller.dispose);
      addTearDown(incoming.close);
      controller.document.history.clear();
      insertDocumentIntoController(controller, incoming);
      expect(controller.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
      expect(controller.selection.baseOffset, 9);
      controller.undo();
      expect(controller.document.toPlainText(), 'BeforeAfter\n');
    },
  );
}
