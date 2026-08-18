import 'dart:convert';

import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/services/note_document_projection.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:better_keep/services/note_table_markdown_codec.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stage two enables table creation and import', () {
    expect(enableTableCreation, isTrue);
    expect(enableMarkdownTableImport, isTrue);
  });

  group('NoteTableCodec', () {
    test(
      'round-trips the versioned embed with Unicode and multiline cells',
      () {
        final source = NoteTable(
          id: 'stable-id',
          header: true,
          rows: const [
            ['名前', 'Description'],
            ['📝', 'line one\nline two'],
          ],
        );

        final embed = NoteTableCodec.encode(source);
        final payload =
            jsonDecode(embed.data as String) as Map<String, dynamic>;

        expect(payload['version'], 1);
        expect(payload['id'], 'stable-id');
        expect(payload['header'], isTrue);
        expect(NoteTableCodec.decodeData(embed.data), source);
      },
    );

    test('rejects future, malformed, ragged, and oversized payloads', () {
      Map<String, dynamic> payload({
        int version = 1,
        Object rows = const [
          ['a'],
        ],
      }) => {'version': version, 'id': 'id', 'header': false, 'rows': rows};

      expect(
        NoteTableCodec.tryDecodeData(jsonEncode(payload(version: 2))),
        isNull,
      );
      expect(
        NoteTableCodec.tryDecodeData(
          jsonEncode(
            payload(
              rows: const [
                ['a'],
                ['b', 'c'],
              ],
            ),
          ),
        ),
        isNull,
      );
      expect(
        NoteTableCodec.tryDecodeData(
          jsonEncode(
            payload(
              rows: List.generate(NoteTableCodec.maxRows + 1, (_) => ['a']),
            ),
          ),
        ),
        isNull,
      );
      expect(NoteTableCodec.tryDecodeData('{not-json'), isNull);
    });
  });

  test(
    'structural operations preserve identity and rectangular dimensions',
    () {
      final source = NoteTable.empty(id: 'id', rowCount: 2, columnCount: 2);
      final result = source
          .updateCell(0, 0, 'value')
          .insertRow(1)
          .insertColumn(2)
          .deleteRow(0)
          .deleteColumn(0)
          .copyWith(header: true);

      expect(result.id, source.id);
      expect(result.header, isTrue);
      expect(result.rowCount, 2);
      expect(result.columnCount, 2);
      expect(result.rows.every((row) => row.length == 2), isTrue);
    },
  );

  test('plain-text projection uses tab and newline cell boundaries', () {
    final table = NoteTable(
      id: 'id',
      rows: const [
        ['alpha', 'beta'],
        ['gamma', 'delta'],
      ],
    );
    final document = Document.fromDelta(
      Delta()
        ..insert('before\n')
        ..insert(NoteTableCodec.encodeInsert(table))
        ..insert('\nafter\n'),
    );

    expect(
      NoteDocumentProjection.toPlainText(document),
      'before\nalpha\tbeta\ngamma\tdelta\nafter\n',
    );
  });

  test('note serialization keeps raw Delta and projects searchable cells', () {
    final table = NoteTable(
      id: 'id',
      rows: const [
        ['one', 'two'],
      ],
    );
    final content = jsonEncode([
      {'insert': NoteTableCodec.encodeInsert(table)},
      {'insert': '\n'},
    ]);
    final note = Note(title: 'Table', content: content);
    final locked = Note(title: 'Locked table', content: content, locked: true);

    expect(note.toJson()['content'], content);
    expect(note.toJson()['plain_text'], 'one\ttwo\n');
    expect(locked.toJson()['content'], content);
    expect(locked.toJson()['plain_text'], isEmpty);
  });

  group('NoteTableMarkdownCodec', () {
    test('round-trips header tables as escaped GFM', () {
      final table = NoteTable(
        id: 'id',
        header: true,
        rows: const [
          ['Name', 'Path'],
          ['first\nsecond', r'a\b|c'],
        ],
      );

      final markdown = NoteTableMarkdownCodec.encode(table);
      final extraction = NoteTableMarkdownCodec.extract(markdown);
      final decoded = extraction.tables.values.single;

      expect(markdown, contains('| Name | Path |'));
      expect(decoded.header, isTrue);
      expect(decoded.rows, table.rows);
    });

    test('round-trips headerless tables as Better Keep HTML', () {
      final table = NoteTable(
        id: 'id',
        rows: const [
          ['<one>', 'two & three'],
          ['line one\nline two', '"quoted"'],
        ],
      );

      final markdown = NoteTableMarkdownCodec.encode(table);
      final decoded = NoteTableMarkdownCodec.extract(
        markdown,
      ).tables.values.single;

      expect(markdown, startsWith('<table data-better-keep-table="1">'));
      expect(decoded.header, isFalse);
      expect(decoded.rows, table.rows);
    });

    test('leaves oversized GFM source unchanged', () {
      final markdown = [
        '| Head |',
        '| --- |',
        ...List.generate(NoteTableCodec.maxRows, (index) => '| $index |'),
      ].join('\n');

      final extraction = NoteTableMarkdownCodec.extract(markdown);

      expect(extraction.tables, isEmpty);
      expect(extraction.markdown, markdown);
    });

    test('leaves oversized Better Keep HTML source unchanged', () {
      final rows = List.generate(
        NoteTableCodec.maxRows + 1,
        (index) => '<tr><td>$index</td></tr>',
      ).join();
      final markdown =
          '<table data-better-keep-table="1"><tbody>$rows</tbody></table>';

      final extraction = NoteTableMarkdownCodec.extract(markdown);

      expect(extraction.tables, isEmpty);
      expect(extraction.markdown, markdown);
    });
  });

  test('note Markdown export emits tables without a synthetic header', () {
    final table = NoteTable(
      id: 'id',
      rows: const [
        ['one', 'two'],
      ],
    );
    final note = Note(
      title: 'Table',
      content: jsonEncode([
        {'insert': NoteTableCodec.encodeInsert(table)},
        {'insert': '\n'},
      ]),
    );

    final markdown = ExportDataService().noteToMarkdown(
      note,
      includeMetadata: false,
    );

    expect(markdown, contains('<table data-better-keep-table="1">'));
    expect(markdown, isNot(contains('| --- |')));
  });
}
