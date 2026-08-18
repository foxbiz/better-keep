import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

typedef NoteTableFlushCallback = void Function();
typedef NoteTableFocusCallback =
    void Function(
      NoteTableCellAddress address, {
      TextSelection? selection,
      bool requestKeyboardFocus,
      bool syncFromDocument,
    });

@immutable
class NoteTableLocation {
  const NoteTableLocation({required this.offset, required this.table});

  final int offset;
  final NoteTable table;
}

class NoteTableController extends ChangeNotifier {
  NoteTableController({
    required this.controller,
    required this.parentFocusNode,
    this.onDraftChanged,
  });

  final QuillController controller;
  final FocusNode parentFocusNode;
  final VoidCallback? onDraftChanged;

  final Map<String, NoteTableFlushCallback> _flushCallbacks = {};
  final Map<String, NoteTableFocusCallback> _focusCallbacks = {};
  NoteTableCellAddress? _activeCell;
  NoteTableCellAddress? _pendingFocus;
  TextSelection? _pendingSelection;
  bool _pendingKeyboardFocus = true;
  bool _pendingDocumentSync = false;
  String? _focusedTableId;
  bool _cellInputFocused = false;
  List<NoteTableTextMatch> _searchMatches = const [];

  NoteTableCellAddress? get activeCell => _activeCell;
  bool get hasActiveCell => _activeCell != null;
  bool get isCellInputFocused => _cellInputFocused;
  List<NoteTableTextMatch> matchesFor(NoteTableCellAddress address) =>
      _searchMatches
          .where((match) => match.address == address)
          .toList(growable: false);

  void setSearchMatches(List<NoteTableTextMatch> matches) {
    _searchMatches = List.unmodifiable(matches);
    notifyListeners();
  }

  NoteTable? get activeTable {
    final id = _activeCell?.tableId;
    return id == null ? null : findTable(id)?.table;
  }

  void registerTable({
    required String tableId,
    required NoteTableFlushCallback flush,
    required NoteTableFocusCallback focus,
  }) {
    _flushCallbacks[tableId] = flush;
    _focusCallbacks[tableId] = focus;
    final pending = _pendingFocus;
    if (pending != null && pending.tableId == tableId) {
      final selection = _pendingSelection;
      final requestKeyboardFocus = _pendingKeyboardFocus;
      final syncFromDocument = _pendingDocumentSync;
      _pendingFocus = null;
      _pendingSelection = null;
      _pendingDocumentSync = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final callback = _focusCallbacks[tableId];
        if (callback != null) {
          callback(
            pending,
            selection: selection,
            requestKeyboardFocus: requestKeyboardFocus,
            syncFromDocument: syncFromDocument,
          );
        }
      });
    }
  }

  void unregisterTable(String tableId, NoteTableFlushCallback flush) {
    if (identical(_flushCallbacks[tableId], flush)) {
      _flushCallbacks.remove(tableId);
      _focusCallbacks.remove(tableId);
      setCellInputFocus(tableId, false);
    }
  }

  void markDraftChanged() => onDraftChanged?.call();

  void setCellInputFocus(String tableId, bool focused) {
    if (focused) {
      if (_focusedTableId == tableId && _cellInputFocused) return;
      _focusedTableId = tableId;
      _cellInputFocused = true;
      notifyListeners();
      return;
    }
    if (_focusedTableId != tableId || !_cellInputFocused) return;
    _focusedTableId = null;
    _cellInputFocused = false;
    notifyListeners();
  }

  void activate(NoteTableCellAddress address) {
    if (_activeCell == address) return;
    final previousId = _activeCell?.tableId;
    if (previousId != null && previousId != address.tableId) {
      _flushCallbacks[previousId]?.call();
    }
    _activeCell = address;
    notifyListeners();
  }

  void deactivate({bool restoreParentFocus = false}) {
    flushActive();
    if (_activeCell == null) return;
    final location = findTable(_activeCell!.tableId);
    _activeCell = null;
    _focusedTableId = null;
    _cellInputFocused = false;
    notifyListeners();
    if (restoreParentFocus && location != null) {
      controller.updateSelection(
        TextSelection.collapsed(offset: location.offset + 1),
        ChangeSource.local,
      );
      parentFocusNode.requestFocus();
    }
  }

  void flushActive() {
    final id = _activeCell?.tableId;
    if (id != null) _flushCallbacks[id]?.call();
  }

  void requestCell(
    NoteTableCellAddress address, {
    TextSelection? selection,
    bool requestKeyboardFocus = true,
    bool syncFromDocument = false,
  }) {
    _activeCell = address;
    notifyListeners();
    final callback = _focusCallbacks[address.tableId];
    if (callback != null) {
      callback(
        address,
        selection: selection,
        requestKeyboardFocus: requestKeyboardFocus,
        syncFromDocument: syncFromDocument,
      );
      return;
    }
    _pendingFocus = address;
    _pendingSelection = selection;
    _pendingKeyboardFocus = requestKeyboardFocus;
    _pendingDocumentSync = syncFromDocument;
  }

  void undo() => _performHistoryAction(controller.undo);

  void redo() => _performHistoryAction(controller.redo);

  void _performHistoryAction(VoidCallback action) {
    final address = _activeCell;
    final restoreKeyboardFocus = _cellInputFocused;
    flushActive();
    action();
    if (address == null) return;

    final location = findTable(address.tableId);
    if (location == null) {
      _activeCell = null;
      _focusedTableId = null;
      _cellInputFocused = false;
      notifyListeners();
      parentFocusNode.requestFocus();
      return;
    }

    final reconciled = NoteTableCellAddress(
      tableId: address.tableId,
      row: address.row.clamp(0, location.table.rowCount - 1),
      column: address.column.clamp(0, location.table.columnCount - 1),
    );
    requestCell(
      reconciled,
      requestKeyboardFocus: restoreKeyboardFocus,
      syncFromDocument: true,
    );
  }

  NoteTableLocation? findTable(String id) {
    var offset = 0;
    for (final operation in controller.document.toDelta().toList()) {
      if (!operation.isInsert) continue;
      final data = operation.data;
      if (data is Map) {
        final table = NoteTableCodec.tryDecodeInsert(data);
        if (table?.id == id) {
          return NoteTableLocation(offset: offset, table: table!);
        }
      }
      offset += operation.length ?? 0;
    }
    return null;
  }

  void replaceTable(NoteTable table) {
    final location = findTable(table.id);
    if (location == null || location.table == table) return;
    controller.replaceText(
      location.offset,
      1,
      NoteTableCodec.encode(table),
      null,
      ignoreFocus: true,
    );
  }

  void mutateActive(NoteTable Function(NoteTable table) transform) {
    flushActive();
    final address = _activeCell;
    final table = activeTable;
    if (address == null || table == null) return;
    final next = transform(table);
    if (next == table) return;
    replaceTable(next);
  }

  void insertRow({required bool after}) {
    final address = _activeCell;
    final table = activeTable;
    if (address == null ||
        table == null ||
        table.rowCount >= NoteTableCodec.maxRows) {
      return;
    }
    flushActive();
    final index = address.row + (after ? 1 : 0);
    replaceTable(table.insertRow(index));
    requestCell(
      NoteTableCellAddress(
        tableId: table.id,
        row: index,
        column: address.column,
      ),
    );
  }

  void deleteRow() {
    final address = _activeCell;
    final table = activeTable;
    if (address == null || table == null || table.rowCount == 1) return;
    flushActive();
    final next = table.deleteRow(address.row);
    replaceTable(next);
    requestCell(
      NoteTableCellAddress(
        tableId: table.id,
        row: address.row.clamp(0, next.rowCount - 1),
        column: address.column,
      ),
    );
  }

  void insertColumn({required bool after}) {
    final address = _activeCell;
    final table = activeTable;
    if (address == null ||
        table == null ||
        table.columnCount >= NoteTableCodec.maxColumns) {
      return;
    }
    flushActive();
    final index = address.column + (after ? 1 : 0);
    replaceTable(table.insertColumn(index));
    requestCell(
      NoteTableCellAddress(tableId: table.id, row: address.row, column: index),
    );
  }

  void deleteColumn() {
    final address = _activeCell;
    final table = activeTable;
    if (address == null || table == null || table.columnCount == 1) return;
    flushActive();
    final next = table.deleteColumn(address.column);
    replaceTable(next);
    requestCell(
      NoteTableCellAddress(
        tableId: table.id,
        row: address.row,
        column: address.column.clamp(0, next.columnCount - 1),
      ),
    );
  }

  void toggleHeader() {
    mutateActive((table) => table.copyWith(header: !table.header));
  }

  void deleteTable() {
    flushActive();
    final id = _activeCell?.tableId;
    final location = id == null ? null : findTable(id);
    if (location == null) return;
    controller.replaceText(
      location.offset,
      1,
      '',
      TextSelection.collapsed(offset: location.offset),
    );
    _activeCell = null;
    _focusedTableId = null;
    _cellInputFocused = false;
    notifyListeners();
    controller.updateSelection(
      TextSelection.collapsed(
        offset: location.offset.clamp(0, controller.document.length - 1),
      ),
      ChangeSource.local,
    );
    parentFocusNode.requestFocus();
  }

  void moveToNextCell({required bool backwards}) {
    flushActive();
    final address = _activeCell;
    var table = activeTable;
    if (address == null || table == null) return;
    var flat = address.row * table.columnCount + address.column;
    flat += backwards ? -1 : 1;
    if (flat < 0) flat = table.rowCount * table.columnCount - 1;
    if (flat >= table.rowCount * table.columnCount) {
      if (table.rowCount < NoteTableCodec.maxRows) {
        table = table.insertRow(table.rowCount);
        replaceTable(table);
        flat = (table.rowCount - 1) * table.columnCount;
      } else {
        deactivate(restoreParentFocus: true);
        return;
      }
    }
    requestCell(
      NoteTableCellAddress(
        tableId: table.id,
        row: flat ~/ table.columnCount,
        column: flat % table.columnCount,
      ),
    );
  }

  @override
  void dispose() {
    flushActive();
    _flushCallbacks.clear();
    _focusCallbacks.clear();
    super.dispose();
  }
}

abstract final class NoteTableInsertion {
  static int insert({
    required QuillController controller,
    required NoteTable table,
  }) {
    final selection = controller.selection;
    final index = selection.isValid
        ? selection.end.clamp(0, controller.document.length - 1)
        : controller.document.length - 1;
    final plainText = controller.document.toPlainText();
    final atLineStart = index == 0 || plainText[index - 1] == '\n';
    final atLineEnd = index >= plainText.length || plainText[index] == '\n';
    final transaction = Delta()..retain(index);
    if (!atLineStart) transaction.insert('\n');
    transaction.insert(NoteTableCodec.encodeInsert(table));
    if (!atLineEnd) transaction.insert('\n');
    controller.compose(transaction, selection, ChangeSource.local);
    final tableOffset = index + (atLineStart ? 0 : 1);
    controller.updateSelection(
      TextSelection.collapsed(offset: tableOffset + 1),
      ChangeSource.local,
    );
    return tableOffset;
  }
}
