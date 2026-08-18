import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/note_find_controller.dart';
import 'package:better_keep/services/note_search_delta_composer.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

abstract final class NoteFindDeltaComposer {
  static Delta build(Document document, NoteFindReplacementPlan plan) {
    if (!plan.isValid || plan.edits.isEmpty) return Delta();

    final bodyEdits = <NoteSearchTextEdit>[];
    final tableEdits = <String, List<NoteFindReplacementEdit>>{};
    for (final edit in plan.edits) {
      final address = edit.target.cell;
      if (address == null) {
        bodyEdits.add(
          NoteSearchTextEdit(
            start: edit.target.match.start,
            end: edit.target.match.end,
            replacement: edit.replacement,
          ),
        );
      } else {
        tableEdits.putIfAbsent(address.tableId, () => []).add(edit);
      }
    }

    final bodyTransaction = NoteSearchDeltaComposer.build(
      document,
      NoteSearchReplacementPlan(edits: bodyEdits),
    );
    final tableLocations = _tableLocations(document);
    final replacements = <({int offset, NoteTable table})>[];
    for (final entry in tableEdits.entries) {
      final location = tableLocations[entry.key];
      if (location == null) {
        throw ArgumentError('A table search result is stale.');
      }
      var table = location.table;
      final byCell = <NoteTableCellAddress, List<NoteFindReplacementEdit>>{};
      for (final edit in entry.value) {
        byCell.putIfAbsent(edit.target.cell!, () => []).add(edit);
      }
      for (final cellEntry in byCell.entries) {
        final address = cellEntry.key;
        if (address.row >= table.rowCount ||
            address.column >= table.columnCount) {
          throw ArgumentError('A table search result is stale.');
        }
        var value = table.cellAt(address.row, address.column);
        final edits = cellEntry.value
          ..sort(
            (a, b) => b.target.match.start.compareTo(a.target.match.start),
          );
        var previousStart = value.length;
        for (final edit in edits) {
          final match = edit.target.match;
          if (match.start < 0 ||
              match.end > previousStart ||
              match.end > value.length) {
            throw ArgumentError('Table search ranges overlap or are stale.');
          }
          value = value.replaceRange(match.start, match.end, edit.replacement);
          previousStart = match.start;
        }
        table = table.updateCell(address.row, address.column, value);
      }
      replacements.add((offset: location.offset, table: table));
    }

    if (replacements.isEmpty) return bodyTransaction;
    replacements.sort((a, b) => a.offset.compareTo(b.offset));
    final tableTransaction = Delta();
    var cursor = 0;
    for (final replacement in replacements) {
      final offset = bodyTransaction.transformPosition(
        replacement.offset,
        force: false,
      );
      if (offset < cursor) throw ArgumentError('Table locations overlap.');
      if (offset > cursor) tableTransaction.retain(offset - cursor);
      tableTransaction
        ..delete(1)
        ..insert(NoteTableCodec.encodeInsert(replacement.table));
      cursor = offset + 1;
    }
    return bodyTransaction.isEmpty
        ? tableTransaction
        : bodyTransaction.compose(tableTransaction);
  }

  static Map<String, ({int offset, NoteTable table})> _tableLocations(
    Document document,
  ) {
    final result = <String, ({int offset, NoteTable table})>{};
    var offset = 0;
    for (final operation in document.toDelta().toList()) {
      if (!operation.isInsert) continue;
      final table = NoteTableCodec.tryDecodeInsert(operation.data);
      if (table != null) result[table.id] = (offset: offset, table: table);
      offset += operation.length ?? 0;
    }
    return result;
  }
}
