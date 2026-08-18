import 'dart:math' as math;

import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:uuid/uuid.dart';

class NoteTableButton extends StatelessWidget {
  const NoteTableButton({
    super.key,
    required this.controller,
    required this.readOnly,
    required this.tableController,
  });

  final QuillController controller;
  final bool readOnly;
  final NoteTableController tableController;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('insert_table_button'),
      icon: const Icon(Icons.table_chart_outlined),
      tooltip: context.l10n.insertTable,
      onPressed: readOnly ? null : () => _insert(context),
    );
  }

  Future<void> _insert(BuildContext context) async {
    final table = await showInsertTableSheet(context);
    if (table == null || !context.mounted) return;
    NoteTableInsertion.insert(controller: controller, table: table);
    tableController.requestCell(
      NoteTableCellAddress(tableId: table.id, row: 0, column: 0),
    );
  }
}

Future<NoteTable?> showInsertTableSheet(BuildContext context) {
  final viewport = MediaQuery.sizeOf(context);
  return showModalBottomSheet<NoteTable>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxWidth: 440,
      maxHeight: viewport.height * 0.9,
    ),
    builder: (_) => const _InsertTableSheet(),
  );
}

class _InsertTableSheet extends StatefulWidget {
  const _InsertTableSheet();

  @override
  State<_InsertTableSheet> createState() => _InsertTableSheetState();
}

class _InsertTableSheetState extends State<_InsertTableSheet> {
  static const _quickRows = 5;
  static const _quickColumns = 5;

  late final TextEditingController _rowsController;
  late final TextEditingController _columnsController;
  int _rows = 2;
  int _columns = 2;
  bool _header = false;

  @override
  void initState() {
    super.initState();
    _rowsController = TextEditingController(text: '2');
    _columnsController = TextEditingController(text: '2');
  }

  @override
  void dispose() {
    _rowsController.dispose();
    _columnsController.dispose();
    super.dispose();
  }

  bool get _valid =>
      _rows >= 1 &&
      _rows <= NoteTableCodec.maxRows &&
      _columns >= 1 &&
      _columns <= NoteTableCodec.maxColumns;

  void _select(int rows, int columns) {
    setState(() {
      _rows = rows;
      _columns = columns;
      _rowsController.text = '$rows';
      _columnsController.text = '$columns';
    });
  }

  void _parseCustom() {
    setState(() {
      _rows = int.tryParse(_rowsController.text) ?? 0;
      _columns = int.tryParse(_columnsController.text) ?? 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('insert_table_sheet_scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      context.l10n.insertTable,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      context.l10n.tableQuickSize,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    _QuickTableGrid(
                      rows: _quickRows,
                      columns: _quickColumns,
                      selectedRows: _rows.clamp(1, _quickRows),
                      selectedColumns: _columns.clamp(1, _quickColumns),
                      onSelected: _select,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.tableSize(_rows, _columns),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      context.l10n.tableCustomSize,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _DimensionField(
                          key: const ValueKey('table_rows_control'),
                          fieldKey: const ValueKey('table_rows_input'),
                          decrementKey: const ValueKey('table_rows_decrement'),
                          incrementKey: const ValueKey('table_rows_increment'),
                          label: context.l10n.tableRows,
                          helper: context.l10n.tableRowsLimit(
                            NoteTableCodec.maxRows,
                          ),
                          controller: _rowsController,
                          value: _rows,
                          max: NoteTableCodec.maxRows,
                          onChanged: _parseCustom,
                          onStep: (value) => _select(value, _columns),
                        ),
                        _DimensionField(
                          key: const ValueKey('table_columns_control'),
                          fieldKey: const ValueKey('table_columns_input'),
                          decrementKey: const ValueKey(
                            'table_columns_decrement',
                          ),
                          incrementKey: const ValueKey(
                            'table_columns_increment',
                          ),
                          label: context.l10n.tableColumns,
                          helper: context.l10n.tableColumnsLimit(
                            NoteTableCodec.maxColumns,
                          ),
                          controller: _columnsController,
                          value: _columns,
                          max: NoteTableCodec.maxColumns,
                          onChanged: _parseCustom,
                          onStep: (value) => _select(_rows, value),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.l10n.tableHeaderRow),
                      value: _header,
                      onChanged: (value) => setState(() => _header = value),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            ColoredBox(
              color: colors.surface,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: FilledButton.icon(
                  key: const ValueKey('insert_table_confirm'),
                  onPressed: _valid
                      ? () => Navigator.of(context).pop(
                          NoteTable.empty(
                            id: const Uuid().v4(),
                            rowCount: _rows,
                            columnCount: _columns,
                            header: _header,
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.table_chart_outlined),
                  label: Text(context.l10n.insertTable),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickTableGrid extends StatelessWidget {
  const _QuickTableGrid({
    required this.rows,
    required this.columns,
    required this.selectedRows,
    required this.selectedColumns,
    required this.onSelected,
  });

  final int rows;
  final int columns;
  final int selectedRows;
  final int selectedColumns;
  final void Function(int rows, int columns) onSelected;

  void _selectFromPosition(Offset position, Size size) {
    final column = (position.dx / (size.width / columns)).floor().clamp(
      0,
      columns - 1,
    );
    final row = (position.dy / (size.height / rows)).floor().clamp(0, rows - 1);
    onSelected(row + 1, column + 1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: context.l10n.tableSize(selectedRows, selectedColumns),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : 240.0;
          final dimension = math.min(availableWidth, 240.0);
          final size = Size.square(dimension);
          return Align(
            alignment: Alignment.center,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) =>
                  _selectFromPosition(details.localPosition, size),
              onPanUpdate: (details) =>
                  _selectFromPosition(details.localPosition, size),
              onTapUp: (details) =>
                  _selectFromPosition(details.localPosition, size),
              child: SizedBox.square(
                key: const ValueKey('table_quick_picker'),
                dimension: dimension,
                child: GridView.builder(
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: rows * columns,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                  ),
                  itemBuilder: (context, index) {
                    final row = index ~/ columns;
                    final column = index % columns;
                    final selected =
                        row < selectedRows && column < selectedColumns;
                    return MouseRegion(
                      onEnter: (_) => onSelected(row + 1, column + 1),
                      child: Semantics(
                        button: true,
                        selected: selected,
                        label: context.l10n.tableSize(row + 1, column + 1),
                        child: AnimatedContainer(
                          key: ValueKey(
                            'table_quick_cell_${row + 1}_${column + 1}',
                          ),
                          duration: const Duration(milliseconds: 80),
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: selected
                                ? colors.primaryContainer
                                : colors.surfaceContainerHighest,
                            border: Border.all(
                              color: selected
                                  ? colors.primary
                                  : colors.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DimensionField extends StatelessWidget {
  const _DimensionField({
    super.key,
    required this.fieldKey,
    required this.decrementKey,
    required this.incrementKey,
    required this.label,
    required this.helper,
    required this.controller,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.onStep,
  });

  final Key fieldKey;
  final Key decrementKey;
  final Key incrementKey;
  final String label;
  final String helper;
  final TextEditingController controller;
  final int value;
  final int max;
  final VoidCallback onChanged;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 128,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 2),
          Text(
            helper,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Container(
            height: 44,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _DimensionStepButton(
                  key: decrementKey,
                  label: '$label −',
                  icon: Icons.remove,
                  enabled: value > 1,
                  onPressed: () => onStep((value - 1).clamp(1, max)),
                ),
                Expanded(
                  child: Semantics(
                    label: label,
                    textField: true,
                    child: TextField(
                      key: fieldKey,
                      controller: controller,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(max.toString().length),
                      ],
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                      onChanged: (_) => onChanged(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 9),
                      ),
                    ),
                  ),
                ),
                _DimensionStepButton(
                  key: incrementKey,
                  label: '$label +',
                  icon: Icons.add,
                  enabled: value < max,
                  onPressed: () => onStep((value + 1).clamp(1, max)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DimensionStepButton extends StatelessWidget {
  const _DimensionStepButton({
    super.key,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = enabled
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant.withValues(alpha: 0.38);
    return IconButton(
      tooltip: label,
      onPressed: enabled ? onPressed : null,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: colors.primaryContainer,
        disabledForegroundColor: foreground,
        disabledBackgroundColor: colors.surfaceContainerHighest,
        minimumSize: const Size.square(40),
        maximumSize: const Size.square(40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: Icon(icon, size: 18, color: foreground),
    );
  }
}
