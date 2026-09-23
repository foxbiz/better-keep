import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/dialogs/paste_dialog.dart';
import 'package:better_keep/utils/note_embed_rules.dart';
import 'dart:convert';
import 'package:flutter_quill/quill_delta.dart';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/embeds/note_attachment_embed.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sparse tables preserve legacy nested content through storage and axis edits',
    () {
      final nested = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {'insert': 'Nested\n'},
      ]);
      final rich = [
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
        {
          'insert': {NoteTableData.type: nested.toJson()},
        },
        {'insert': '\n'},
      ];
      final table = NoteTableData(
        rows: 256,
        columns: 256,
      ).withCell(100, 200, rich).resizeColumn(200, 220).resizeRow(100, 120);
      final restored = NoteTableData.fromJson(
        jsonDecode(jsonEncode(table.toJson())),
      );
      expect(restored.cells.length, 1);
      expect(restored.cell(100, 200), rich);
      expect(restored.changeAxis(row: true, index: 0), same(restored));
      final smaller = restored.changeAxis(row: true, index: 0, delete: true);
      expect(smaller.cell(99, 200), rich);
      expect(smaller.rowHeights[99], 120);
      final duplicate = smaller.changeAxis(
        row: true,
        index: 99,
        duplicate: true,
      );
      expect(duplicate.cell(99, 200), rich);
      expect(
        (duplicate.cell(100, 200)[2]['insert'][NoteTableData.type]
            as Map)['id'],
        isNot(nested.id),
      );
      expect(
        noteDeltaPlainText([
          {
            'insert': {NoteTableData.type: duplicate.toJson()},
          },
        ]),
        contains('Nested'),
      );
      expect(() => NoteTableData(rows: 257, columns: 1), throwsFormatException);
    },
  );

  test(
    'cell paste flattens tables in reading order and preserves rich media',
    () {
      final image = {
        noteAttachmentEmbedType: {
          'id': 'image-reference',
          'src': 'attachment://image',
          'placement': 'block',
          'width': 120,
        },
      };
      final nested = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
        {'insert': 'Checklist'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked'},
        },
        {'insert': image},
        {'insert': '\n'},
      ]);
      final table = NoteTableData(rows: 256, columns: 256)
          .withCell(255, 255, [
            {'insert': 'Last\n'},
          ])
          .withCell(0, 10, [
            {
              'insert': {NoteTableData.type: nested.toJson()},
            },
            {'insert': '\n'},
          ])
          .withCell(0, 2, [
            {
              'insert': 'First',
              'attributes': {'bold': true},
            },
            {'insert': '\n'},
          ]);
      final source = documentFromJsonSafe([
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {'insert': '\n'},
      ]);
      addTearDown(source.close);
      final original = jsonEncode(source.toDelta().toJson());
      for (final method in ['native', 'formatted', 'embed']) {
        final controller = NoteEditorController(
          document: Document()..setCustomRules(customQuillRules),
          selection: const TextSelection.collapsed(offset: 0),
          allowTables: false,
        );
        addTearDown(controller.dispose);
        if (method == 'formatted') {
          insertDocumentIntoController(controller, source);
        } else {
          controller.replaceText(
            0,
            0,
            method == 'native'
                ? source.toDelta()
                : Embeddable(NoteTableData.type, table.toJson()),
            const TextSelection.collapsed(offset: 0),
          );
        }
        final ops = controller.document.toDelta().toList();
        expect(ops.any((op) => isNoteTable(op.data)), isFalse);
        expect(
          controller.document.toPlainText(),
          'First\nChecklist\n\uFFFC\nLast\n\n',
        );
        expect(ops.first.attributes, {'bold': true});
        expect(
          ops.where((op) => op.attributes?['list'] == 'checked'),
          hasLength(1),
        );
        expect(ops.where((op) => op.data is Map).single.data, image);
        expect(controller.selection.baseOffset, controller.document.length - 1);
        expect(jsonEncode(source.toDelta().toJson()), original);
        controller.undo();
        expect(controller.document.toPlainText(), '\n');
        controller.redo();
        expect(
          controller.document.toPlainText(),
          contains('Checklist\n\uFFFC\nLast'),
        );
      }
    },
  );

  test(
    'insertion, cell edits and undo keep the surrounding document intact',
    () {
      final controller = QuillController(
        document: Document.fromJson([
          {'insert': 'BeforeAfter\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 6),
      );
      addTearDown(controller.dispose);
      final table = NoteTableData(rows: 2, columns: 2);
      insertNoteEmbed(
        controller,
        NoteTableData.type,
        table.toJson(),
        block: true,
      );
      expect(controller.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
      expect(controller.selection.baseOffset, 9);
      controller.document.history.clear();
      replaceNoteEmbed(
        controller,
        NoteTableData.type,
        table.id,
        table.withCell(1, 1, [
          {'insert': 'Cell\n'},
        ]).toJson(),
      );
      expect(
        noteDeltaPlainText(controller.document.toDelta().toJson()),
        contains('Cell'),
      );
      controller.undo();
      expect(
        noteDeltaPlainText(controller.document.toDelta().toJson()),
        isNot(contains('Cell')),
      );
      controller.redo();
      expect(
        noteDeltaPlainText(controller.document.toDelta().toJson()),
        contains('Cell'),
      );
    },
  );

  for (final (type, placement) in [
    (NoteTableData.type, 'block'),
    (noteAttachmentEmbedType, 'block'),
    (noteAttachmentEmbedType, 'inline'),
  ]) {
    test(
      'reopened and native-pasted $type ($placement) remains a block paragraph',
      () {
        final data = type == NoteTableData.type
            ? NoteTableData(rows: 1, columns: 1).toJson()
            : {
                'id': 'ref',
                'src': 'attachment://image',
                'placement': placement,
              };
        final embed = {type: data};
        final original = [
          {'insert': 'Before'},
          {'insert': embed},
          {'insert': 'After\n'},
          {'insert': embed},
          {'insert': '\n'},
        ];
        final snapshot = jsonEncode(original);
        final reopened = documentFromJsonSafe(original);
        addTearDown(reopened.close);
        expect(reopened.toPlainText(), 'Before\n\uFFFC\nAfter\n\uFFFC\n');
        expect(jsonEncode(original), snapshot);
        expect(
          reopened
              .toDelta()
              .toList()
              .where((op) => op.data is Map)
              .map((op) => op.data),
          [embed, embed],
        );
        final controller = NoteEditorController(
          document: Document()..insert(0, 'BeforeAfter'),
          selection: const TextSelection.collapsed(offset: 6),
        );
        addTearDown(controller.dispose);
        controller.document.setCustomRules(customQuillRules);
        controller.document.history.clear();
        controller.replaceText(
          6,
          0,
          Delta()..insert(embed),
          const TextSelection.collapsed(offset: 6),
        );
        expect(controller.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
        expect(controller.selection.baseOffset, 9);
        expect((controller.document.queryChild(7).node as Line).childCount, 1);
        controller.undo();
        expect(controller.document.toPlainText(), 'BeforeAfter\n');
        controller.replaceText(6, 0, Embeddable(type, data), null);
        expect(controller.document.toPlainText(), 'Before\n\uFFFC\nAfter\n');
      },
    );
  }

  test('pasted embeds with the same payload edit their own occurrence', () {
    final table = NoteTableData(rows: 1, columns: 1);
    final controller = QuillController(
      document: Document.fromJson([
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {'insert': '\n'},
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    replaceNoteEmbed(
      controller,
      NoteTableData.type,
      table.id,
      table.withCell(0, 0, [
        {'insert': 'Copy\n'},
      ]).toJson(),
      offsetHint: 2,
    );
    final delta = controller.document.toDelta().toJson();
    expect(
      NoteTableData.fromJson(
        (delta.first['insert'] as Map)[NoteTableData.type],
      ).cells,
      isEmpty,
    );
    expect(
      NoteTableData.fromJson(
        (delta[2]['insert'] as Map)[NoteTableData.type],
      ).cell(0, 0).first['insert'],
      'Copy\n',
    );
  });

  test(
    'attachment IDs survive serialization and file replacement; block insertion preserves text',
    () {
      final attachment = NoteAttachment.image(
        NoteImage(
          src: '/first.png',
          size: 1,
          index: 0,
          aspectRatio: '1:1',
          lastModified: '1',
        ),
      );
      final reference = attachmentReference(attachment);
      final restored = NoteAttachment.fromJson(attachment.toJson());
      restored.image!.src = '/updated.png';
      final note = Note(attachments: [restored]);
      expect(
        resolveNoteAttachment(note, reference['src'] as String)?.image!.src,
        '/updated.png',
      );
      final controller = QuillController(
        document: Document.fromJson([
          {'insert': 'BeforeAfter\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 6),
      );
      addTearDown(controller.dispose);
      insertNoteEmbed(
        controller,
        noteAttachmentEmbedType,
        reference,
        block: true,
      );
      expect(reference['placement'], 'block');
      expect(controller.document.toPlainText(), 'Before\n\uFFfc\nAfter\n');
      controller.readOnly = true;
      replaceNoteEmbed(
        controller,
        noteAttachmentEmbedType,
        reference['id'] as String,
        null,
      );
      expect(controller.document.toPlainText(), 'Before\n\uFFfc\nAfter\n');
      note.attachments.clear();
      expect(resolveNoteAttachment(note, reference['src'] as String), isNull);
    },
  );

  test(
    'tables and all attachment images keep their own line while editing',
    () {
      for (final (type, placement) in [
        (NoteTableData.type, 'block'),
        (noteAttachmentEmbedType, 'block'),
        (noteAttachmentEmbedType, 'inline'),
      ]) {
        final data = type == NoteTableData.type
            ? NoteTableData(rows: 1, columns: 1).toJson()
            : {
                'id': 'ref',
                'src': 'attachment://image',
                'placement': placement,
              };
        final doc = Document.fromJson([
          {'insert': 'Before\n'},
          {
            'insert': {type: data},
          },
          {'insert': '\nAfter\n'},
        ])..setCustomRules(customQuillRules);
        doc.delete(6, 1);
        expect(doc.toPlainText(), 'Before\n\uFFFC\nAfter\n');
        doc.delete(8, 1);
        expect(doc.toPlainText(), 'Before\n\uFFFC\nAfter\n');
        doc.insert(8, 'New');
        expect(doc.toPlainText(), 'Before\n\uFFFC\nNew\nAfter\n');
        doc.close();
      }
      final empty = NoteTableData(rows: 1, columns: 1);
      expect(
        noteDeltaPlainText([
          {
            'insert': {NoteTableData.type: empty.toJson()},
          },
        ]).trim(),
        isNotEmpty,
      );
    },
  );

  test('text indexing and markdown exports include rich table content', () {
    final table = NoteTableData(rows: 1, columns: 1).withCell(0, 0, [
      {
        'insert': 'Cell text',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
    ]);
    final note = Note(
      content: jsonEncode([
        {
          'insert': {NoteTableData.type: table.toJson()},
        },
        {'insert': '\n'},
      ]),
    );
    expect(note.toJson()['plain_text'], contains('Cell text'));
    final markdown = ExportDataService().noteToMarkdown(
      note,
      includeMetadata: false,
    );
    expect(markdown, contains('<table>'));
    expect(markdown, contains('<strong>Cell text</strong>'));
  });
}
