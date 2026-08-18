import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:uuid/uuid.dart';

class NoteTableMarkdownExtraction {
  const NoteTableMarkdownExtraction({
    required this.markdown,
    required this.tables,
  });

  final String markdown;
  final Map<String, NoteTable> tables;
}

abstract final class NoteTableMarkdownCodec {
  static const String placeholderPrefix = '{{BETTER_KEEP_TABLE_';
  static final RegExp _placeholderPattern = RegExp(
    r'^\{\{BETTER_KEEP_TABLE_(\d+)\}\}$',
  );

  static String encode(NoteTable table) {
    NoteTableCodec.validate(table);
    return table.header ? _encodeGfm(table) : _encodeHtml(table);
  }

  static NoteTable? tableForPlaceholder(
    String line,
    Map<String, NoteTable> tables,
  ) {
    if (!_placeholderPattern.hasMatch(line.trim())) return null;
    return tables[line.trim()];
  }

  static NoteTableMarkdownExtraction extract(String markdown) {
    final tables = <String, NoteTable>{};
    var nextIndex = 0;
    String add(NoteTable table) {
      final marker = '$placeholderPrefix${nextIndex++}}}';
      tables[marker] = table;
      return marker;
    }

    var processed = markdown.replaceAllMapped(
      RegExp(
        r'<table\s+data-better-keep-table="1"[^>]*>[\s\S]*?</table>',
        caseSensitive: false,
      ),
      (match) {
        final table = _tryDecodeHtml(match.group(0)!);
        return table == null ? match.group(0)! : add(table);
      },
    );

    final lines = processed.split('\n');
    final output = <String>[];
    var index = 0;
    while (index < lines.length) {
      if (index + 1 < lines.length) {
        final header = _parseGfmRow(lines[index]);
        final separator = _parseSeparator(lines[index + 1]);
        if (header != null &&
            separator != null &&
            header.length == separator &&
            header.length <= NoteTableCodec.maxColumns) {
          final rows = <List<String>>[header];
          var cursor = index + 2;
          while (cursor < lines.length) {
            final row = _parseGfmRow(lines[cursor]);
            if (row == null || row.length != header.length) break;
            rows.add(row);
            cursor++;
          }
          if (rows.length <= NoteTableCodec.maxRows) {
            output.add(
              add(NoteTable(id: const Uuid().v4(), header: true, rows: rows)),
            );
            index = cursor;
            continue;
          }
        }
      }
      output.add(lines[index]);
      index++;
    }
    processed = output.join('\n');
    return NoteTableMarkdownExtraction(markdown: processed, tables: tables);
  }

  static String _encodeGfm(NoteTable table) {
    final buffer = StringBuffer();
    buffer.writeln(_gfmRow(table.rows.first));
    buffer.writeln(_gfmRow(List.filled(table.columnCount, '---')));
    for (final row in table.rows.skip(1)) {
      buffer.writeln(_gfmRow(row));
    }
    return buffer.toString().trimRight();
  }

  static String _encodeHtml(NoteTable table) {
    final buffer = StringBuffer()
      ..writeln('<table data-better-keep-table="1">')
      ..writeln('  <tbody>');
    for (final row in table.rows) {
      buffer.writeln('    <tr>');
      for (final cell in row) {
        buffer.writeln('      <td>${_escapeHtml(cell)}</td>');
      }
      buffer.writeln('    </tr>');
    }
    buffer
      ..writeln('  </tbody>')
      ..write('</table>');
    return buffer.toString();
  }

  static String _gfmRow(List<String> cells) =>
      '| ${cells.map(_escapeGfm).join(' | ')} |';

  static String _escapeGfm(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('|', r'\|')
      .replaceAll('\n', '<br>');

  static String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('\n', '<br>');

  static String _decodeCell(String value) => value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&gt;', '>')
      .replaceAll('&lt;', '<')
      .replaceAll('&amp;', '&');

  static List<String>? _parseGfmRow(String line) {
    final trimmed = line.trim();
    if (!trimmed.contains('|')) return null;
    var source = trimmed;
    if (source.startsWith('|')) source = source.substring(1);
    if (source.endsWith('|') && !source.endsWith(r'\|')) {
      source = source.substring(0, source.length - 1);
    }
    final cells = <String>[];
    final buffer = StringBuffer();
    var escaped = false;
    for (var index = 0; index < source.length; index++) {
      final character = source[index];
      if (escaped) {
        buffer.write(character);
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == '|') {
        cells.add(_decodeCell(buffer.toString().trim()));
        buffer.clear();
      } else {
        buffer.write(character);
      }
    }
    if (escaped) buffer.write('\\');
    cells.add(_decodeCell(buffer.toString().trim()));
    return cells.isEmpty ? null : cells;
  }

  static int? _parseSeparator(String line) {
    final cells = _parseGfmRow(line);
    if (cells == null ||
        cells.any((cell) => !RegExp(r'^:?-{3,}:?$').hasMatch(cell))) {
      return null;
    }
    return cells.length;
  }

  static NoteTable? _tryDecodeHtml(String source) {
    try {
      final rows = <List<String>>[];
      final rowMatches = RegExp(
        r'<tr[^>]*>([\s\S]*?)</tr>',
        caseSensitive: false,
      ).allMatches(source);
      for (final rowMatch in rowMatches) {
        final cells =
            RegExp(r'<t[dh][^>]*>([\s\S]*?)</t[dh]>', caseSensitive: false)
                .allMatches(rowMatch.group(1)!)
                .map((match) {
                  final cell = match
                      .group(1)!
                      .replaceAll(
                        RegExp(r'<br\s*/?>', caseSensitive: false),
                        '\u0000',
                      )
                      .replaceAll(RegExp(r'<[^>]+>'), '')
                      .replaceAll('\u0000', '<br>');
                  return _decodeCell(cell);
                })
                .toList(growable: false);
        if (cells.isNotEmpty) rows.add(cells);
      }
      if (rows.isEmpty ||
          rows.length > NoteTableCodec.maxRows ||
          rows.first.length > NoteTableCodec.maxColumns ||
          rows.any((row) => row.length != rows.first.length)) {
        return null;
      }
      return NoteTable(id: const Uuid().v4(), rows: rows);
    } on Object {
      return null;
    }
  }
}
