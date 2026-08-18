import 'package:flutter/foundation.dart';

@immutable
class NoteTableCellAddress {
  const NoteTableCellAddress({
    required this.tableId,
    required this.row,
    required this.column,
  });

  final String tableId;
  final int row;
  final int column;

  @override
  bool operator ==(Object other) =>
      other is NoteTableCellAddress &&
      other.tableId == tableId &&
      other.row == row &&
      other.column == column;

  @override
  int get hashCode => Object.hash(tableId, row, column);
}

@immutable
class NoteTableTextMatch {
  const NoteTableTextMatch({
    required this.address,
    required this.start,
    required this.end,
    this.active = false,
  });

  final NoteTableCellAddress address;
  final int start;
  final int end;
  final bool active;
}

@immutable
class NoteTable {
  NoteTable({
    required this.id,
    required List<List<String>> rows,
    this.header = false,
  }) : assert(id.isNotEmpty),
       assert(rows.isNotEmpty),
       assert(rows.first.isNotEmpty),
       assert(rows.every((row) => row.length == rows.first.length)),
       rows = List.unmodifiable(
         rows.map((row) => List<String>.unmodifiable(row)),
       );

  factory NoteTable.empty({
    required String id,
    required int rowCount,
    required int columnCount,
    bool header = false,
  }) {
    return NoteTable(
      id: id,
      header: header,
      rows: List.generate(
        rowCount,
        (_) => List.filled(columnCount, '', growable: false),
        growable: false,
      ),
    );
  }

  final String id;
  final bool header;
  final List<List<String>> rows;

  int get rowCount => rows.length;
  int get columnCount => rows.first.length;
  bool get hasContent => rows.any((row) => row.any((cell) => cell.isNotEmpty));

  String cellAt(int row, int column) => rows[row][column];

  NoteTable copyWith({String? id, bool? header, List<List<String>>? rows}) {
    return NoteTable(
      id: id ?? this.id,
      header: header ?? this.header,
      rows: rows ?? this.rows,
    );
  }

  NoteTable updateCell(int row, int column, String value) {
    final next = _mutableRows();
    next[row][column] = value;
    return copyWith(rows: next);
  }

  NoteTable insertRow(int index) {
    final next = _mutableRows()
      ..insert(index, List.filled(columnCount, '', growable: false));
    return copyWith(rows: next);
  }

  NoteTable deleteRow(int index) {
    if (rowCount == 1) return this;
    final next = _mutableRows()..removeAt(index);
    return copyWith(rows: next);
  }

  NoteTable insertColumn(int index) {
    final next = _mutableRows();
    for (final row in next) {
      row.insert(index, '');
    }
    return copyWith(rows: next);
  }

  NoteTable deleteColumn(int index) {
    if (columnCount == 1) return this;
    final next = _mutableRows();
    for (final row in next) {
      row.removeAt(index);
    }
    return copyWith(rows: next);
  }

  String toPlainText() => rows.map((row) => row.join('\t')).join('\n');

  List<List<String>> _mutableRows() => rows
      .map((row) => List<String>.from(row, growable: true))
      .toList(growable: true);

  @override
  bool operator ==(Object other) {
    if (other is! NoteTable ||
        other.id != id ||
        other.header != header ||
        other.rowCount != rowCount ||
        other.columnCount != columnCount) {
      return false;
    }
    for (var row = 0; row < rowCount; row++) {
      if (!listEquals(rows[row], other.rows[row])) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(id, header, Object.hashAll(rows.map(Object.hashAll)));
}
