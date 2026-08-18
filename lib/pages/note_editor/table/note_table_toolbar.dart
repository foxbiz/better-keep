import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

enum _RowAction { insertAbove, insertBelow, delete }

enum _ColumnAction { insertBefore, insertAfter, delete }

class NoteTableToolbar extends StatelessWidget {
  const NoteTableToolbar({
    super.key,
    required this.controller,
    required this.parentColor,
    required this.showKeyboardHide,
    required this.onHideKeyboard,
  });

  final NoteTableController controller;
  final Color parentColor;
  final bool showKeyboardHide;
  final VoidCallback onHideKeyboard;

  @override
  Widget build(BuildContext context) {
    final table = controller.activeTable;
    if (table == null) return const SizedBox.shrink();
    final canAddRow = table.rowCount < NoteTableCodec.maxRows;
    final canAddColumn = table.columnCount < NoteTableCodec.maxColumns;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
    return AdaptiveToolbar(
      key: const ValueKey('note_table_toolbar'),
      parentColor: parentColor,
      children: [
        if (isIOS && showKeyboardHide)
          IconButton(
            icon: const Icon(Icons.keyboard_hide),
            onPressed: onHideKeyboard,
            tooltip: context.l10n.hideKeyboard,
          ),
        NoteEditorHistoryButtons(
          binding: NoteEditorHistoryBinding(
            listenable: controller.controller,
            canUndo: () => controller.controller.hasUndo,
            canRedo: () => controller.controller.hasRedo,
            undo: controller.undo,
            redo: controller.redo,
          ),
          readOnly: false,
        ),
        PopupMenuButton<_RowAction>(
          key: const ValueKey('table_row_actions'),
          tooltip: context.l10n.tableRows,
          icon: const Icon(Icons.table_rows_outlined),
          onSelected: (action) {
            switch (action) {
              case _RowAction.insertAbove:
                controller.insertRow(after: false);
              case _RowAction.insertBelow:
                controller.insertRow(after: true);
              case _RowAction.delete:
                controller.deleteRow();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _RowAction.insertAbove,
              enabled: canAddRow,
              child: Tooltip(
                message: canAddRow
                    ? context.l10n.insertRowAbove
                    : context.l10n.tableRowsLimit(NoteTableCodec.maxRows),
                child: Text(context.l10n.insertRowAbove),
              ),
            ),
            PopupMenuItem(
              value: _RowAction.insertBelow,
              enabled: canAddRow,
              child: Tooltip(
                message: canAddRow
                    ? context.l10n.insertRowBelow
                    : context.l10n.tableRowsLimit(NoteTableCodec.maxRows),
                child: Text(context.l10n.insertRowBelow),
              ),
            ),
            PopupMenuItem(
              value: _RowAction.delete,
              enabled: table.rowCount > 1,
              child: Tooltip(
                message: context.l10n.deleteRow,
                child: Text(context.l10n.deleteRow),
              ),
            ),
          ],
        ),
        PopupMenuButton<_ColumnAction>(
          key: const ValueKey('table_column_actions'),
          tooltip: context.l10n.tableColumns,
          icon: const Icon(Icons.view_column_outlined),
          onSelected: (action) {
            switch (action) {
              case _ColumnAction.insertBefore:
                controller.insertColumn(after: false);
              case _ColumnAction.insertAfter:
                controller.insertColumn(after: true);
              case _ColumnAction.delete:
                controller.deleteColumn();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _ColumnAction.insertBefore,
              enabled: canAddColumn,
              child: Tooltip(
                message: canAddColumn
                    ? context.l10n.insertColumnBefore
                    : context.l10n.tableColumnsLimit(NoteTableCodec.maxColumns),
                child: Text(context.l10n.insertColumnBefore),
              ),
            ),
            PopupMenuItem(
              value: _ColumnAction.insertAfter,
              enabled: canAddColumn,
              child: Tooltip(
                message: canAddColumn
                    ? context.l10n.insertColumnAfter
                    : context.l10n.tableColumnsLimit(NoteTableCodec.maxColumns),
                child: Text(context.l10n.insertColumnAfter),
              ),
            ),
            PopupMenuItem(
              value: _ColumnAction.delete,
              enabled: table.columnCount > 1,
              child: Tooltip(
                message: context.l10n.deleteColumn,
                child: Text(context.l10n.deleteColumn),
              ),
            ),
          ],
        ),
        IconButton(
          key: const ValueKey('table_header_toggle'),
          isSelected: table.header,
          icon: const Icon(Icons.view_headline_outlined),
          tooltip: context.l10n.tableHeaderRow,
          onPressed: controller.toggleHeader,
        ),
        IconButton(
          key: const ValueKey('delete_table_button'),
          icon: const Icon(Icons.delete_outline),
          tooltip: context.l10n.deleteTable,
          onPressed: controller.deleteTable,
        ),
      ],
    );
  }
}
