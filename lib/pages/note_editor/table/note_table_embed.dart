import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

enum NoteTablePresentation { editor, card }

class NoteTableEmbedBuilder extends EmbedBuilder {
  const NoteTableEmbedBuilder({
    required this.parentColor,
    this.tableController,
    this.presentation = NoteTablePresentation.editor,
  });

  final Color parentColor;
  final NoteTableController? tableController;
  final NoteTablePresentation presentation;

  @override
  String get key => NoteTableCodec.embedType;

  @override
  String toPlainText(Embed node) =>
      NoteTableCodec.tryDecodeData(node.value.data)?.toPlainText() ??
      Embed.kObjectReplacementCharacter;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = NoteTableCodec.tryDecodeData(embedContext.node.value.data);
    if (table == null) {
      return const _UnsupportedNoteEmbed(icon: Icons.table_chart_outlined);
    }
    return NoteTableEmbed(
      key: ValueKey('note-table-${table.id}'),
      table: table,
      readOnly: embedContext.readOnly || tableController == null,
      parentColor: parentColor,
      tableController: tableController,
      presentation: presentation,
    );
  }
}

class UnknownNoteEmbedBuilder extends EmbedBuilder {
  const UnknownNoteEmbedBuilder();

  @override
  String get key => 'better-keep-unsupported';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const _UnsupportedNoteEmbed(icon: Icons.extension_off_outlined);
}

class _UnsupportedNoteEmbed extends StatelessWidget {
  const _UnsupportedNoteEmbed({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: context.l10n.tableUnsupported,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.tableUnsupported,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps Flutter's built-in text editing actions inside the nested cell
/// editor. Flutter's TextField actions are intentionally overridable, so the
/// surrounding Quill editor would otherwise receive delete, selection, and
/// undo intents from the cell.
class _CellTextEditingAction<T extends Intent> extends Action<T> {
  @override
  Object? invoke(T intent) => callingAction?.invoke(intent);

  @override
  bool get isActionEnabled => callingAction?.isActionEnabled ?? false;

  @override
  bool consumesKey(T intent) => callingAction?.consumesKey(intent) ?? false;
}

class NoteTableEmbed extends StatefulWidget {
  const NoteTableEmbed({
    super.key,
    required this.table,
    required this.readOnly,
    required this.parentColor,
    required this.presentation,
    this.tableController,
  });

  final NoteTable table;
  final bool readOnly;
  final Color parentColor;
  final NoteTablePresentation presentation;
  final NoteTableController? tableController;

  @override
  State<NoteTableEmbed> createState() => _NoteTableEmbedState();
}

class _NoteTableEmbedState extends State<NoteTableEmbed> {
  late NoteTable _table;
  late final TextEditingController _cellController;
  late final FocusNode _cellFocusNode;
  final Map<String, GlobalKey> _cellKeys = {};
  late final Map<Type, Action<Intent>> _cellTextEditingActions = {
    DeleteCharacterIntent: _CellTextEditingAction<DeleteCharacterIntent>(),
    DeleteToNextWordBoundaryIntent:
        _CellTextEditingAction<DeleteToNextWordBoundaryIntent>(),
    DeleteToLineBreakIntent: _CellTextEditingAction<DeleteToLineBreakIntent>(),
    ExtendSelectionByCharacterIntent:
        _CellTextEditingAction<ExtendSelectionByCharacterIntent>(),
    ExtendSelectionToNextWordBoundaryIntent:
        _CellTextEditingAction<ExtendSelectionToNextWordBoundaryIntent>(),
    ExtendSelectionToLineBreakIntent:
        _CellTextEditingAction<ExtendSelectionToLineBreakIntent>(),
    ExtendSelectionVerticallyToAdjacentLineIntent:
        _CellTextEditingAction<ExtendSelectionVerticallyToAdjacentLineIntent>(),
    ExtendSelectionToDocumentBoundaryIntent:
        _CellTextEditingAction<ExtendSelectionToDocumentBoundaryIntent>(),
    ExtendSelectionToNextWordBoundaryOrCaretLocationIntent:
        _CellTextEditingAction<
          ExtendSelectionToNextWordBoundaryOrCaretLocationIntent
        >(),
    ExpandSelectionToDocumentBoundaryIntent:
        _CellTextEditingAction<ExpandSelectionToDocumentBoundaryIntent>(),
    ExpandSelectionToLineBreakIntent:
        _CellTextEditingAction<ExpandSelectionToLineBreakIntent>(),
    ExtendSelectionVerticallyToAdjacentPageIntent:
        _CellTextEditingAction<ExtendSelectionVerticallyToAdjacentPageIntent>(),
    ScrollToDocumentBoundaryIntent:
        _CellTextEditingAction<ScrollToDocumentBoundaryIntent>(),
    SelectAllTextIntent: _CellTextEditingAction<SelectAllTextIntent>(),
    CopySelectionTextIntent: _CellTextEditingAction<CopySelectionTextIntent>(),
    PasteTextIntent: _CellTextEditingAction<PasteTextIntent>(),
    UndoTextIntent: _CellTextEditingAction<UndoTextIntent>(),
    RedoTextIntent: _CellTextEditingAction<RedoTextIntent>(),
  };
  NoteTableCellAddress? _editingAddress;
  bool _keyboardEditingRequested = false;
  bool _hasUncommittedDraft = false;

  NoteTableController? get _coordinator => widget.tableController;

  @override
  void initState() {
    super.initState();
    _table = widget.table;
    _cellController = TextEditingController();
    _cellFocusNode = FocusNode(
      debugLabel: 'Table cell',
      onKeyEvent: _handleCellKey,
    );
    _cellFocusNode.addListener(_handleCellFocusChanged);
    _coordinator?.addListener(_handleCoordinatorChanged);
    _register();
  }

  @override
  void didUpdateWidget(covariant NoteTableEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tableController != widget.tableController) {
      oldWidget.tableController?.setCellInputFocus(oldWidget.table.id, false);
      oldWidget.tableController?.removeListener(_handleCoordinatorChanged);
      oldWidget.tableController?.unregisterTable(oldWidget.table.id, _flush);
      _coordinator?.addListener(_handleCoordinatorChanged);
      _register();
    }
    if (widget.table != _table) {
      final editing = _editingAddress;
      _table = widget.table;
      if (editing != null &&
          editing.row < _table.rowCount &&
          editing.column < _table.columnCount &&
          !_hasUncommittedDraft) {
        _syncEditingValueFromTable(editing);
      }
    }
  }

  void _register() {
    _coordinator?.registerTable(
      tableId: widget.table.id,
      flush: _flush,
      focus: _focusFromCoordinator,
    );
  }

  @override
  void dispose() {
    _flush();
    _coordinator?.removeListener(_handleCoordinatorChanged);
    _coordinator?.unregisterTable(widget.table.id, _flush);
    _cellController.dispose();
    _cellFocusNode.removeListener(_handleCellFocusChanged);
    _cellFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleCellKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        _coordinator?.moveToNextCell(
          backwards: HardwareKeyboard.instance.isShiftPressed,
        );
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _coordinator?.deactivate(restoreParentFocus: true);
        return KeyEventResult.handled;
      }
    }

    final isTextEvent = event is KeyDownEvent || event is KeyRepeatEvent;
    final hasCommandModifier =
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isTextEvent &&
        !hasCommandModifier &&
        event.character != null &&
        event.character!.isNotEmpty &&
        event.character != '\n') {
      // Prevent Quill's ancestor character/space rules from observing cell
      // input while still allowing the platform text input client to insert it.
      return KeyEventResult.skipRemainingHandlers;
    }
    return KeyEventResult.ignored;
  }

  void _handleCoordinatorChanged() {
    if (!mounted) return;
    final active = _coordinator?.activeCell;
    if (active?.tableId != _table.id) {
      if (_editingAddress != null) {
        _flush();
        _editingAddress = null;
        _cellFocusNode.unfocus();
      }
      setState(() {});
      return;
    }
    if (active != null && active != _editingAddress) {
      _activateCell(active, requestKeyboardFocus: false);
      return;
    }
    setState(() {});
  }

  void _focusFromCoordinator(
    NoteTableCellAddress address, {
    TextSelection? selection,
    bool requestKeyboardFocus = true,
    bool syncFromDocument = false,
  }) {
    if (!mounted || address.tableId != _table.id) return;
    if (syncFromDocument) {
      final latest = _coordinator?.findTable(address.tableId)?.table;
      if (latest == null) return;
      _table = latest;
      _hasUncommittedDraft = false;
    }
    _activateCell(
      address,
      selection: selection,
      requestKeyboardFocus: requestKeyboardFocus,
      syncFromDocument: syncFromDocument,
    );
  }

  void _activateCell(
    NoteTableCellAddress address, {
    TextSelection? selection,
    required bool requestKeyboardFocus,
    bool syncFromDocument = false,
  }) {
    if (widget.readOnly ||
        address.row < 0 ||
        address.row >= _table.rowCount ||
        address.column < 0 ||
        address.column >= _table.columnCount) {
      return;
    }
    final isNewCell = _editingAddress != address;
    if (isNewCell || syncFromDocument) {
      if (!syncFromDocument) _flush();
      _editingAddress = address;
      _keyboardEditingRequested = requestKeyboardFocus;
      _hasUncommittedDraft = false;
      final textLength = _table.cellAt(address.row, address.column).length;
      _syncEditingValueFromTable(
        address,
        selection:
            selection ??
            (isNewCell ? TextSelection.collapsed(offset: textLength) : null),
      );
      setState(() {});
    } else if (selection != null) {
      _cellController.selection = selection;
      if (_keyboardEditingRequested != requestKeyboardFocus) {
        _keyboardEditingRequested = requestKeyboardFocus;
        setState(() {});
      }
    } else if (requestKeyboardFocus && !_keyboardEditingRequested) {
      _keyboardEditingRequested = true;
      setState(() {});
    }
    _coordinator?.activate(address);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingAddress != address) return;
      if (requestKeyboardFocus) _cellFocusNode.requestFocus();
      final context =
          _cellKeys[_cellKey(address.row, address.column)]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.35,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _onCellChanged(String value) {
    final address = _editingAddress;
    if (address == null) return;
    _hasUncommittedDraft = value != _table.cellAt(address.row, address.column);
    _coordinator?.markDraftChanged();
  }

  void _handleCellFocusChanged() {
    _coordinator?.setCellInputFocus(_table.id, _cellFocusNode.hasPrimaryFocus);
    if (!_cellFocusNode.hasFocus) {
      _keyboardEditingRequested = false;
      _flush();
    }
    if (mounted) setState(() {});
  }

  void _flush() {
    final address = _editingAddress;
    if (address == null ||
        address.row >= _table.rowCount ||
        address.column >= _table.columnCount) {
      return;
    }
    final value = _cellController.text;
    if (_table.cellAt(address.row, address.column) == value) {
      _hasUncommittedDraft = false;
      return;
    }
    _table = _table.updateCell(address.row, address.column, value);
    _hasUncommittedDraft = false;
    _coordinator?.replaceTable(_table);
  }

  void _syncEditingValueFromTable(
    NoteTableCellAddress address, {
    TextSelection? selection,
  }) {
    final text = _table.cellAt(address.row, address.column);
    final current = _cellController.value;
    if (current.text == text && selection == null) return;
    final nextSelection = _clampSelection(
      selection ?? current.selection,
      text.length,
    );
    final nextComposing = current.text == text
        ? _clampComposing(current.composing, text.length)
        : TextRange.empty;
    _cellController.value = TextEditingValue(
      text: text,
      selection: nextSelection,
      composing: nextComposing,
    );
  }

  TextSelection _clampSelection(TextSelection selection, int textLength) {
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: textLength);
    }
    return TextSelection(
      baseOffset: selection.baseOffset.clamp(0, textLength),
      extentOffset: selection.extentOffset.clamp(0, textLength),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextRange _clampComposing(TextRange composing, int textLength) {
    if (!composing.isValid || composing.isCollapsed) return TextRange.empty;
    return TextRange(
      start: composing.start.clamp(0, textLength),
      end: composing.end.clamp(0, textLength),
    );
  }

  String _cellKey(int row, int column) => '$row:$column';

  @override
  Widget build(BuildContext context) {
    final foreground = isDark(widget.parentColor) ? Colors.white : Colors.black;
    final border = foreground.withValues(alpha: 0.3);
    final headerColor = foreground.withValues(alpha: 0.08);
    final activeColor = Theme.of(context).colorScheme.primary;
    final visibleRows = widget.presentation == NoteTablePresentation.card
        ? _table.rows.take(3).toList(growable: false)
        : _table.rows;
    final table = Table(
      border: TableBorder.all(color: border),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      columnWidths: {
        for (var column = 0; column < _table.columnCount; column++)
          column: const FlexColumnWidth(),
      },
      children: [
        for (var row = 0; row < visibleRows.length; row++)
          TableRow(
            decoration: row == 0 && _table.header
                ? BoxDecoration(color: headerColor)
                : null,
            children: [
              for (var column = 0; column < _table.columnCount; column++)
                _buildCell(
                  context,
                  row: row,
                  column: column,
                  foreground: foreground,
                  activeColor: activeColor,
                ),
            ],
          ),
      ],
    );

    Widget result = Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          table,
          if (widget.presentation == NoteTablePresentation.card &&
              _table.rowCount > visibleRows.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                context.l10n.tableMoreRows(
                  _table.rowCount - visibleRows.length,
                ),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.65),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.readOnly && widget.presentation != NoteTablePresentation.card) {
      result = SelectionArea(child: result);
    }
    return result;
  }

  Widget _buildCell(
    BuildContext context, {
    required int row,
    required int column,
    required Color foreground,
    required Color activeColor,
  }) {
    final address = NoteTableCellAddress(
      tableId: _table.id,
      row: row,
      column: column,
    );
    final active = !widget.readOnly && _editingAddress == address;
    final editing =
        active && (_cellFocusNode.hasFocus || _keyboardEditingRequested);
    final searchMatches = _coordinator?.matchesFor(address) ?? const [];
    final key = _cellKeys.putIfAbsent(_cellKey(row, column), GlobalKey.new);
    final style = TextStyle(
      color: foreground,
      fontWeight: row == 0 && _table.header
          ? FontWeight.w600
          : FontWeight.normal,
      height: 1.25,
    );
    final content = editing
        ? KeyedSubtree(
            key: ValueKey('note_table_cell_editor_${row}_$column'),
            child: Actions(
              actions: _cellTextEditingActions,
              child: TextField(
                key: const ValueKey('note_table_active_cell'),
                controller: _cellController,
                focusNode: _cellFocusNode,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 1,
                maxLines: null,
                style: style,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: _onCellChanged,
              ),
            ),
          )
        : Text.rich(
            _highlightedCellSpan(
              context,
              text: _table.cellAt(row, column),
              style: style,
              matches: searchMatches,
            ),
            softWrap: true,
          );

    return Semantics(
      key: key,
      label: context.l10n.tableCell(row + 1, column + 1),
      button: !widget.readOnly,
      textField: editing,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.readOnly
            ? null
            : () => _activateCell(address, requestKeyboardFocus: true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 42),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: active
              ? BoxDecoration(border: Border.all(color: activeColor, width: 2))
              : null,
          alignment: AlignmentDirectional.topStart,
          child: content,
        ),
      ),
    );
  }

  TextSpan _highlightedCellSpan(
    BuildContext context, {
    required String text,
    required TextStyle style,
    required List<NoteTableTextMatch> matches,
  }) {
    if (matches.isEmpty) return TextSpan(text: text, style: style);
    final valid =
        matches
            .where((match) => match.start >= 0 && match.end <= text.length)
            .toList(growable: false)
          ..sort((a, b) => a.start.compareTo(b.start));
    if (valid.isEmpty) return TextSpan(text: text, style: style);

    final children = <InlineSpan>[];
    var cursor = 0;
    final colors = Theme.of(context).colorScheme;
    for (final match in valid) {
      if (match.start < cursor) continue;
      if (match.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      children.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: match.active
                ? colors.tertiaryContainer
                : Colors.yellow.withValues(alpha: 0.55),
            color: match.active ? colors.onTertiaryContainer : null,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }
}
