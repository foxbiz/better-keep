import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/services/markdown_import_service.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/markdown_converter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixtures = [
    _MarkdownTableFixture(
      name: 'GFM',
      markdown: '''
| Name | Notes |
| --- | --- |
| Alpha | line one<br>line two |
''',
      header: true,
      rows: [
        ['Name', 'Notes'],
        ['Alpha', 'line one\nline two'],
      ],
    ),
    _MarkdownTableFixture(
      name: 'Better Keep HTML',
      markdown: '''
<table data-better-keep-table="1">
  <tbody>
    <tr><td>Alpha</td><td>one &amp; two</td></tr>
    <tr><td>Beta<br>continued</td><td>&lt;three&gt;</td></tr>
  </tbody>
</table>
''',
      header: false,
      rows: [
        ['Alpha', 'one & two'],
        ['Beta\ncontinued', '<three>'],
      ],
    ),
  ];

  for (final fixture in fixtures) {
    test('MarkdownConverter imports ${fixture.name} tables', () {
      final delta = MarkdownConverter.markdownToQuillDelta(fixture.markdown);

      final table = _tableFromDelta(delta);
      expect(table.header, fixture.header);
      expect(table.rows, fixture.rows);
    });

    test('MarkdownImportService persists ${fixture.name} tables', () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      AppState.db = database;
      Note.syncTriggerOverride = () {};
      addTearDown(() async {
        Note.syncTriggerOverride = null;
        await database.close();
      });
      await Note.createTable(database);
      await NoteSyncTrack.createTable(database);

      final note = await MarkdownImportService.importMarkdown(
        title: fixture.name,
        markdownContent: fixture.markdown,
      );
      await pumpEventQueue(times: 20);

      final delta = (jsonDecode(note.content!) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final table = _tableFromDelta(delta);
      expect(table.header, fixture.header);
      expect(table.rows, fixture.rows);
      expect(
        note.plainText,
        contains(fixture.rows.map((row) => row.join('\t')).join('\n')),
      );
      expect(await database.query(Note.model), hasLength(1));
    });
  }
}

NoteTable _tableFromDelta(List<Map<String, dynamic>> delta) {
  for (final operation in delta) {
    final table = NoteTableCodec.tryDecodeInsert(operation['insert']);
    if (table != null) return table;
  }
  throw StateError('Expected a Better Keep table embed.');
}

class _MarkdownTableFixture {
  const _MarkdownTableFixture({
    required this.name,
    required this.markdown,
    required this.header,
    required this.rows,
  });

  final String name;
  final String markdown;
  final bool header;
  final List<List<String>> rows;
}
