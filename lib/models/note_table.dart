import 'package:uuid/uuid.dart';

/// A sparse table stored inside the note Delta. Empty cells cost no documents.
/// Cell documents use the same Delta format, including nested table embeds.
class NoteTableData {
  static const type = 'note-table';
  static const maxDimension = 256;
  static const minColumnWidth = 96.0;
  static const minRowHeight = 56.0;

  final String id;
  final int rows;
  final int columns;
  final Map<String, List<dynamic>> cells;
  final Map<int, double> columnWidths;
  final Map<int, double> rowHeights;

  NoteTableData({
    String? id,
    required this.rows,
    required this.columns,
    Map<String, List<dynamic>>? cells,
    Map<int, double>? columnWidths,
    Map<int, double>? rowHeights,
  }) : id = id ?? const Uuid().v4(),
       cells = cells ?? {},
       columnWidths = columnWidths ?? {},
       rowHeights = rowHeights ?? {} {
    if (rows < 1 ||
        rows > maxDimension ||
        columns < 1 ||
        columns > maxDimension) {
      throw const FormatException('Table dimensions must be between 1 and 256');
    }
  }

  factory NoteTableData.fromJson(dynamic value) {
    final json = Map<String, dynamic>.from(value as Map);
    Map<int, double> sizes(String key, double minimum) => {
      for (final entry in (json[key] as Map? ?? {}).entries)
        if (int.tryParse(entry.key.toString()) != null &&
            entry.value is num &&
            (entry.value as num).isFinite)
          int.parse(entry.key.toString()): (entry.value as num)
              .toDouble()
              .clamp(minimum, 4096),
    };
    return NoteTableData(
      id: json['id'] as String,
      rows: json['rows'] as int,
      columns: json['columns'] as int,
      cells: {
        for (final entry in (json['cells'] as Map? ?? {}).entries)
          entry.key as String: List<dynamic>.from(entry.value as List),
      },
      columnWidths: sizes('widths', minColumnWidth),
      rowHeights: sizes('heights', minRowHeight),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'rows': rows,
    'columns': columns,
    if (cells.isNotEmpty) 'cells': cells,
    if (columnWidths.isNotEmpty)
      'widths': {for (final e in columnWidths.entries) '${e.key}': e.value},
    if (rowHeights.isNotEmpty)
      'heights': {for (final e in rowHeights.entries) '${e.key}': e.value},
  };

  List<dynamic> cell(int row, int column) =>
      cells['$row:$column'] ??
      const [
        {'insert': '\n'},
      ];

  NoteTableData withCell(int row, int column, List<dynamic> delta) {
    final next = {...cells};
    if (delta.length == 1 &&
        delta.first is Map &&
        (delta.first as Map)['insert'] == '\n' &&
        !(delta.first as Map).containsKey('attributes')) {
      next.remove('$row:$column');
    } else {
      next['$row:$column'] = delta;
    }
    return _copy(cells: next);
  }

  NoteTableData resizeColumn(int column, double width) => _copy(
    widths: {...columnWidths, column: width.clamp(minColumnWidth, 4096)},
  );
  NoteTableData resizeRow(int row, double height) =>
      _copy(heights: {...rowHeights, row: height.clamp(minRowHeight, 4096)});
  NoteTableData fitColumns() => _copy(widths: {});

  /// Insert, duplicate, or remove one axis without disturbing rich cell data.
  NoteTableData changeAxis({
    required bool row,
    required int index,
    bool delete = false,
    bool duplicate = false,
  }) {
    final count = row ? rows : columns;
    if ((delete && count == 1) || (!delete && count == maxDimension)) {
      return this;
    }
    if (index < 0 || index > (delete || duplicate ? count - 1 : count)) {
      return this;
    }
    final insertion = duplicate ? index + 1 : index;
    final next = <String, List<dynamic>>{};
    for (final entry in cells.entries) {
      final position = entry.key.split(':').map(int.parse).toList();
      final axis = row ? 0 : 1;
      final current = position[axis];
      if (delete && current == index) continue;
      if (duplicate && current == index) {
        final copy = [...position];
        copy[axis]++;
        // Nested table IDs must be unique within the duplicated cell document.
        next['${copy[0]}:${copy[1]}'] = _duplicateDelta(entry.value);
      }
      if (delete ? current > index : current >= insertion) {
        position[axis] += delete ? -1 : 1;
      }
      next['${position[0]}:${position[1]}'] = entry.value;
    }
    Map<int, double> shiftSizes(Map<int, double> sizes) => {
      for (final entry in sizes.entries)
        if (!delete || entry.key != index)
          (delete
                  ? (entry.key > index ? entry.key - 1 : entry.key)
                  : (entry.key >= insertion ? entry.key + 1 : entry.key)):
              entry.value,
      if (duplicate && sizes.containsKey(index)) insertion: sizes[index]!,
    };
    return NoteTableData(
      id: id,
      rows: rows + (row ? (delete ? -1 : 1) : 0),
      columns: columns + (!row ? (delete ? -1 : 1) : 0),
      cells: next,
      columnWidths: row ? columnWidths : shiftSizes(columnWidths),
      rowHeights: row ? shiftSizes(rowHeights) : rowHeights,
    );
  }

  NoteTableData _copy({
    Map<String, List<dynamic>>? cells,
    Map<int, double>? widths,
    Map<int, double>? heights,
  }) => NoteTableData(
    id: id,
    rows: rows,
    columns: columns,
    cells: cells ?? this.cells,
    columnWidths: widths ?? columnWidths,
    rowHeights: heights ?? rowHeights,
  );
}

List<dynamic> _duplicateDelta(List<dynamic> delta) => [
  for (final op in delta)
    if (op is Map &&
        op['insert'] is Map &&
        (op['insert'] as Map).containsKey(NoteTableData.type))
      {
        ...op,
        'insert': {
          NoteTableData.type: {
            ...Map<String, dynamic>.from(
              (op['insert'] as Map)[NoteTableData.type] as Map,
            ),
            'id': const Uuid().v4(),
          },
        },
      }
    else
      op,
];

/// Unlike Quill's object replacement character, this also indexes cell text.
String noteDeltaPlainText(List<dynamic> delta) {
  final text = StringBuffer();
  for (final op in delta) {
    if (op is! Map) continue;
    final insert = op['insert'];
    if (insert is String) {
      text.write(insert);
    } else if (insert is Map && insert.containsKey(NoteTableData.type)) {
      final table = NoteTableData.fromJson(insert[NoteTableData.type]);
      // Preserve an empty table as meaningful note content for autosave.
      text.write('\n\uFFFC');
      // Visit populated cells only, even for a 256 x 256 empty table.
      final positions = table.cells.keys.toList()
        ..sort((a, b) {
          final x = a.split(':').map(int.parse).toList();
          final y = b.split(':').map(int.parse).toList();
          return x[0] == y[0] ? x[1].compareTo(y[1]) : x[0].compareTo(y[0]);
        });
      for (final key in positions) {
        text.write(noteDeltaPlainText(table.cells[key]!).trim());
        text.write('\t');
      }
      text.write('\n');
    } else if (insert is Map) {
      text.write('\uFFFC');
    }
  }
  return text.toString();
}
