import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<NoteTableData?> showInsertTableDialog(BuildContext context) =>
    showDialog<NoteTableData>(
      context: context,
      builder: (_) => const _InsertTableDialog(),
    );

class _InsertTableDialog extends StatefulWidget {
  const _InsertTableDialog();
  @override
  State<_InsertTableDialog> createState() => _InsertTableDialogState();
}

class _InsertTableDialogState extends State<_InsertTableDialog> {
  final _rows = TextEditingController(text: '3');
  final _columns = TextEditingController(text: '3');
  int _previewRows = 3;
  int _previewColumns = 3;

  bool get _valid => [_rows, _columns].every((field) {
    final value = int.tryParse(field.text);
    return value != null && value >= 1 && value <= NoteTableData.maxDimension;
  });

  @override
  void dispose() {
    _rows.dispose();
    _columns.dispose();
    super.dispose();
  }

  void _add([int? rows, int? columns]) {
    if (rows == null && !_valid) return;
    Navigator.pop(
      context,
      NoteTableData(
        rows: rows ?? int.parse(_rows.text),
        columns: columns ?? int.parse(_columns.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.insertTable),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.tablePickerHint,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              for (var row = 1; row <= 5; row++)
                Row(
                  children: [
                    for (var column = 1; column <= 6; column++)
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Semantics(
                              label: l10n.tableDimensions(row, column),
                              button: true,
                              child: MouseRegion(
                                onEnter: (_) => setState(() {
                                  _previewRows = row;
                                  _previewColumns = column;
                                  _rows.text = '$row';
                                  _columns.text = '$column';
                                }),
                                child: Material(
                                  color:
                                      row <= _previewRows &&
                                          column <= _previewColumns
                                      ? colors.primaryContainer
                                      : colors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(5),
                                  child: InkWell(
                                    key: ValueKey(
                                      'table_picker_${row}_$column',
                                    ),
                                    borderRadius: BorderRadius.circular(5),
                                    onTap: () => _add(row, column),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Text(
                l10n.tableDimensions(_previewRows, _previewColumns),
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _field(_rows, l10n.tableRows, 'table_custom_rows'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('×'),
                  ),
                  Expanded(
                    child: _field(
                      _columns,
                      l10n.tableColumns,
                      'table_custom_columns',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.tableSizeLimit,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _valid ? colors.onSurfaceVariant : colors.error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _valid ? _add : null, child: Text(l10n.add)),
      ],
    );
  }

  Widget _field(TextEditingController controller, String label, String key) =>
      TextField(
        key: ValueKey(key),
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => setState(() {
          _previewRows = int.tryParse(_rows.text) ?? 0;
          _previewColumns = int.tryParse(_columns.text) ?? 0;
        }),
        onSubmitted: (_) {
          if (_valid) _add();
        },
      );
}
