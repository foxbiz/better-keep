import 'dart:convert';

import 'package:better_keep/models/note_table.dart';
import 'package:flutter_quill/flutter_quill.dart';

class NoteTableFormatException implements Exception {
  const NoteTableFormatException(this.message);

  final String message;

  @override
  String toString() => 'NoteTableFormatException: $message';
}

class BetterKeepTableBlockEmbed extends CustomBlockEmbed {
  const BetterKeepTableBlockEmbed(String data)
    : super(NoteTableCodec.embedType, data);
}

abstract final class NoteTableCodec {
  static const String embedType = 'better-keep-table';
  static const int currentVersion = 1;
  static const int maxRows = 20;
  static const int maxColumns = 6;

  static BetterKeepTableBlockEmbed encode(NoteTable table) {
    validate(table);
    return BetterKeepTableBlockEmbed(
      jsonEncode({
        'version': currentVersion,
        'id': table.id,
        'header': table.header,
        'rows': table.rows,
      }),
    );
  }

  static Map<String, dynamic> encodeInsert(NoteTable table) =>
      encode(table).toJson();

  static NoteTable? tryDecodeData(Object? data) {
    try {
      return decodeData(data);
    } on Object {
      return null;
    }
  }

  static NoteTable decodeData(Object? data) {
    if (data is! String) {
      throw const NoteTableFormatException('Table payload must be a string.');
    }
    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      throw const NoteTableFormatException('Table payload must be an object.');
    }
    final version = decoded['version'];
    if (version != currentVersion) {
      throw NoteTableFormatException('Unsupported table version: $version.');
    }
    final id = decoded['id'];
    final header = decoded['header'];
    final sourceRows = decoded['rows'];
    if (id is! String || id.isEmpty) {
      throw const NoteTableFormatException('Table id is missing.');
    }
    if (header is! bool) {
      throw const NoteTableFormatException('Table header flag is invalid.');
    }
    if (sourceRows is! List || sourceRows.isEmpty) {
      throw const NoteTableFormatException('Table must contain rows.');
    }

    final rows = <List<String>>[];
    int? columnCount;
    for (final sourceRow in sourceRows) {
      if (sourceRow is! List || sourceRow.isEmpty) {
        throw const NoteTableFormatException('Table row is invalid.');
      }
      final row = <String>[];
      for (final cell in sourceRow) {
        if (cell is! String) {
          throw const NoteTableFormatException('Table cell is not text.');
        }
        row.add(cell);
      }
      columnCount ??= row.length;
      if (row.length != columnCount) {
        throw const NoteTableFormatException('Table rows are not rectangular.');
      }
      rows.add(row);
    }

    final table = NoteTable(id: id, header: header, rows: rows);
    validate(table);
    return table;
  }

  static NoteTable? tryDecodeInsert(Object? insert) {
    if (insert is! Map || !insert.containsKey(embedType)) return null;
    return tryDecodeData(insert[embedType]);
  }

  static NoteTable? tryDecodeEmbeddable(Embeddable value) {
    if (value.type != embedType) return null;
    return tryDecodeData(value.data);
  }

  static void validate(NoteTable table) {
    if (table.rowCount < 1 || table.rowCount > maxRows) {
      throw NoteTableFormatException(
        'Table rows must be between 1 and $maxRows.',
      );
    }
    if (table.columnCount < 1 || table.columnCount > maxColumns) {
      throw NoteTableFormatException(
        'Table columns must be between 1 and $maxColumns.',
      );
    }
    if (table.rows.any((row) => row.length != table.columnCount)) {
      throw const NoteTableFormatException('Table rows are not rectangular.');
    }
  }
}
