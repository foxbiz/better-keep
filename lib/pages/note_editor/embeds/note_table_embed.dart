import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:better_keep/models/note.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_builders.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/note_embed_rules.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class NoteTableEmbedBuilder extends EmbedBuilder {
  const NoteTableEmbedBuilder({
    required this.note,
    this.editing,
    this.previewMaxHeight,
  });
  final Note note;
  final NoteEmbedEditing? editing;

  /// Unscaled viewport limit; non-null opts into a static card preview.
  final double? previewMaxHeight;
  @override
  String get key => NoteTableData.type;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = NoteTableData.fromJson(embedContext.node.value.data);
    final offset = embedContext.node.documentOffset;
    final child = NoteTableView(
      key: ValueKey(table.id),
      table: table,
      note: note,
      readOnly: embedContext.readOnly || editing == null,
      editing: editing,
      previewMaxHeight: previewMaxHeight,
      onChanged: (value) => replaceNoteEmbed(
        embedContext.controller,
        key,
        table.id,
        value?.toJson(),
        offsetHint: offset,
      ),
    );
    final focus = context
        .findAncestorWidgetOfExactType<QuillEditor>()
        ?.focusNode;
    if (embedContext.readOnly || editing == null || focus == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: child,
      );
    }
    final owner = embedContext.controller;
    final text = owner.document.toPlainText();
    final previousStart = offset > 1
        ? text.lastIndexOf('\n', offset - 2) + 1
        : 0;
    final after = offset + 2;
    final nextEnd = after < text.length ? text.indexOf('\n', after) : -1;
    bool hasNoText(String paragraph) =>
        paragraph.replaceAll('\uFFFC', '').trim().isEmpty;
    Widget boundary(bool before) {
      final empty = before
          ? offset == 0 || hasNoText(text.substring(previousStart, offset - 1))
          : nextEnd < 0 || hasNoText(text.substring(after, nextEnd));
      return MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          key: ValueKey('table_${before ? 'before' : 'after'}_${table.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => focusBesideNoteTable(
            owner,
            focus,
            table.id,
            before: before,
            offsetHint: offset,
          ),
          child: SizedBox(height: empty ? 40 : 10),
        ),
      );
    }

    return NoteEmbedGestureRegion(
      editing: editing!,
      owner: owner,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [boundary(true), child, boundary(false)],
      ),
    );
  }
}

class NoteTableView extends StatefulWidget {
  const NoteTableView({
    super.key,
    required this.table,
    required this.note,
    required this.readOnly,
    required this.onChanged,
    this.editing,
    this.previewMaxHeight,
  });
  final NoteTableData table;
  final Note note;
  final bool readOnly;
  final NoteEmbedEditing? editing;
  final double? previewMaxHeight;
  final ValueChanged<NoteTableData?> onChanged;
  @override
  State<NoteTableView> createState() => _NoteTableViewState();
}

class _NoteTableViewState extends State<NoteTableView> {
  static const _edge = 32.0;
  static const _dragDevices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  String? _activeCell;
  QuillController? _activeController;
  NoteTableData? _resizeBase;
  double _resizeOrigin = 0;
  double _resizeSize = 0;
  NoteTableData? _resizing;
  late NoteTableData _current;
  int _structureRevision = 0;
  NoteTableData get _table => _resizing ?? _current;
  bool get _hasActiveCell =>
      !widget.readOnly &&
      _activeCell != null &&
      _activeController != null &&
      identical(widget.editing?.controller, _activeController);

  @override
  void initState() {
    super.initState();
    _current = widget.table;
    AppState.tableHeadersNotifier.addListener(_refresh);
    widget.editing?.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _commit(NoteTableData? value) {
    if (value != null) _current = value;
    widget.onChanged(value);
  }

  @override
  void didUpdateWidget(NoteTableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _current = widget.table;
    if (oldWidget.editing != widget.editing) {
      oldWidget.editing?.removeListener(_refresh);
      widget.editing?.addListener(_refresh);
    }
    if (oldWidget.table.rows != widget.table.rows ||
        oldWidget.table.columns != widget.table.columns) {
      _structureRevision++;
      _activeCell = null;
    }
  }

  @override
  void dispose() {
    AppState.tableHeadersNotifier.removeListener(_refresh);
    widget.editing?.removeListener(_refresh);
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _changeAxis(bool row, int index, String action) {
    if (widget.readOnly) return;
    if (action == 'delete-table') {
      _commit(null);
      return;
    }
    if (action == 'fit') {
      _commit(_table.fitColumns());
      return;
    }
    final delete = action == 'delete';
    final duplicate = action == 'duplicate';
    final at = action == 'after' ? index + 1 : index;
    final next = _table.changeAxis(
      row: row,
      index: at,
      delete: delete,
      duplicate: duplicate,
    );
    if (!identical(next, _table)) _commit(next);
  }

  Widget _menu({required bool row, required int index}) {
    final l10n = context.l10n;
    final count = row ? _table.rows : _table.columns;
    return PopupMenuButton<String>(
      key: ValueKey('table_${row ? 'row' : 'column'}_$index'),
      tooltip: row
          ? l10n.tableRowOptions(index + 1)
          : l10n.tableColumnOptions(index + 1),
      onSelected: (action) => _changeAxis(row, index, action),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'before',
          enabled: count < NoteTableData.maxDimension,
          child: Text(row ? l10n.insertRowAbove : l10n.insertColumnBefore),
        ),
        PopupMenuItem(
          value: 'after',
          enabled: count < NoteTableData.maxDimension,
          child: Text(row ? l10n.insertRowBelow : l10n.insertColumnAfter),
        ),
        PopupMenuItem(
          value: 'duplicate',
          enabled: count < NoteTableData.maxDimension,
          child: Text(row ? l10n.duplicateRow : l10n.duplicateColumn),
        ),
        PopupMenuItem(
          value: 'delete',
          enabled: count > 1,
          child: Text(row ? l10n.deleteRow : l10n.deleteColumn),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'fit', child: Text(l10n.fitTableColumns)),
        PopupMenuItem(value: 'delete-table', child: Text(l10n.deleteTable)),
      ],
      child: Align(
        alignment: row ? Alignment.centerLeft : Alignment.topCenter,
        child: Container(
          width: row ? 10 : 28,
          height: row ? 28 : 10,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: OverflowBox(
            minWidth: 18,
            maxWidth: 18,
            minHeight: 18,
            maxHeight: 18,
            child: Icon(row ? Icons.more_vert : Icons.more_horiz, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _resizeHandle({
    required bool row,
    required int index,
    required double size,
  }) {
    void start(DragStartDetails details) {
      _resizeBase = _table;
      _resizeOrigin = row
          ? details.globalPosition.dy
          : details.globalPosition.dx;
      _resizeSize = size;
    }

    void update(DragUpdateDetails details) {
      final base = _resizeBase;
      if (base == null) return;
      final position = row
          ? details.globalPosition.dy
          : details.globalPosition.dx;
      final next = (_resizeSize + position - _resizeOrigin).clamp(
        row ? NoteTableData.minRowHeight : NoteTableData.minColumnWidth,
        4096.0,
      );
      setState(
        () => _resizing = row
            ? base.resizeRow(index, next)
            : base.resizeColumn(index, next),
      );
    }

    return MouseRegion(
      cursor: row
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      child: Tooltip(
        message: row ? context.l10n.resizeRow : context.l10n.resizeColumn,
        child: RawGestureDetector(
          key: ValueKey('table_resize_${row ? 'row' : 'column'}_$index'),
          behavior: HitTestBehavior.opaque,
          gestures: {
            _TableResizeGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _TableResizeGestureRecognizer
                >(
                  _TableResizeGestureRecognizer.new,
                  (recognizer) => recognizer
                    ..dragStartBehavior = DragStartBehavior.down
                    ..onStart = start
                    ..onUpdate = update
                    ..onCancel = _finishResize
                    ..onEnd = ((_) => _finishResize()),
                ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _resizeGrip({required bool row}) => IgnorePointer(
    child: Align(
      alignment: row ? Alignment.bottomCenter : Alignment.centerRight,
      child: Container(
        width: row ? 24 : 3,
        height: row ? 3 : 24,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );

  void _finishResize() {
    final value = _resizing;
    _resizeBase = null;
    if (value == null) return;
    setState(() => _resizing = null);
    _commit(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final showHeaders = AppState.tableHeaders;
    final edge = showHeaders ? _edge : 0.0;
    final activeIndices = _hasActiveCell
        ? _activeCell!.split(':').map(int.parse).toList()
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final preview = widget.previewMaxHeight != null;
        final maxHeight = widget.previewMaxHeight ?? 432.0;
        final heights = List.generate(
          _table.rows,
          (i) => _table.rowHeights[i] ?? 72.0,
        );
        final ys = <double>[edge];
        for (final height in heights) {
          ys.add(ys.last + height);
        }
        final border = showHeaders ? 2.0 : 0.0;
        final viewportHeight = math.min(ys.last, maxHeight - border);
        final verticalOverflow = ys.last > viewportHeight;
        final verticalGutter = !preview && verticalOverflow ? 16.0 : 0.0;
        final available =
            (constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0) -
            verticalGutter;
        final defaultWidth = math.max(
          NoteTableData.minColumnWidth,
          (available - edge - 2) / _table.columns,
        );
        final widths = List.generate(
          _table.columns,
          (i) => _table.columnWidths[i] ?? defaultWidth,
        );
        final xs = <double>[edge];
        for (final width in widths) {
          xs.add(xs.last + width);
        }
        final horizontalOverflow = xs.last > available;
        final horizontalGutter = !preview && horizontalOverflow ? 16.0 : 0.0;
        Widget grid = DecoratedBox(
          decoration: BoxDecoration(
            border: showHeaders
                ? Border.all(color: colors.outlineVariant)
                : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(showHeaders ? 9 : 0),
            child: SizedBox(
              width: available,
              height: viewportHeight + border,
              child: SingleChildScrollView(
                key: ValueKey('table_horizontal_${_table.id}'),
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                physics: preview ? const NeverScrollableScrollPhysics() : null,
                child: SizedBox(
                  width: xs.last,
                  child: SingleChildScrollView(
                    key: ValueKey('table_vertical_${_table.id}'),
                    controller: _vertical,
                    physics: preview
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_horizontal, _vertical]),
                      builder: (context, _) {
                        final left = _horizontal.hasClients
                            ? _horizontal.offset
                            : 0.0;
                        final top = _vertical.hasClients
                            ? _vertical.offset
                            : 0.0;
                        final columns = [
                          for (var c = 0; c < widths.length; c++)
                            if (xs[c + 1] >= left && xs[c] <= left + available)
                              c,
                        ];
                        final rows = [
                          for (var r = 0; r < heights.length; r++)
                            if (ys[r + 1] >= top &&
                                ys[r] <= top + viewportHeight)
                              r,
                        ];
                        final cells = <String>{
                          for (final r in rows)
                            for (final c in columns) '$r:$c',
                          ?_activeCell,
                        };
                        return SizedBox(
                          width: xs.last,
                          height: ys.last,
                          child: Stack(
                            children: [
                              for (final position in cells)
                                _buildCell(
                                  position,
                                  xs,
                                  ys,
                                  widths,
                                  heights,
                                  colors,
                                ),
                              if (showHeaders) ...[
                                for (final c in columns)
                                  Positioned(
                                    left: xs[c],
                                    top: top,
                                    width: widths[c],
                                    height: edge,
                                    child: ColoredBox(
                                      color: colors.surfaceContainerHigh,
                                      child: Center(
                                        child: Text(
                                          _columnLabel(c),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                      ),
                                    ),
                                  ),
                                for (final r in rows)
                                  Positioned(
                                    left: left,
                                    top: ys[r],
                                    width: edge,
                                    height: heights[r],
                                    child: ColoredBox(
                                      color: colors.surfaceContainerHigh,
                                      child: Center(
                                        child: Text(
                                          '${r + 1}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                              if (!widget.readOnly) ...[
                                for (final c in columns)
                                  Positioned(
                                    key: ValueKey('table_column_divider_$c'),
                                    left:
                                        xs[c + 1] -
                                        (c == widths.length - 1 ? 20 : 10),
                                    top: edge,
                                    width: 20,
                                    height: ys.last - edge,
                                    child: _resizeHandle(
                                      row: false,
                                      index: c,
                                      size: widths[c],
                                    ),
                                  ),
                                for (final r in rows)
                                  Positioned(
                                    key: ValueKey('table_row_divider_$r'),
                                    left: edge,
                                    top:
                                        ys[r + 1] -
                                        (r == heights.length - 1 ? 20 : 10),
                                    width: xs.last - edge,
                                    height: 20,
                                    child: _resizeHandle(
                                      row: true,
                                      index: r,
                                      size: heights[r],
                                    ),
                                  ),
                              ],
                              if (activeIndices != null) ...[
                                // Only the selected cell exposes edge actions and border grips.
                                Positioned(
                                  left:
                                      xs[activeIndices[1]] +
                                      (widths[activeIndices[1]] - 32) / 2,
                                  top: top + edge,
                                  width: 32,
                                  height: 24,
                                  child: _menu(
                                    row: false,
                                    index: activeIndices[1],
                                  ),
                                ),
                                Positioned(
                                  left: left + edge,
                                  top:
                                      ys[activeIndices[0]] +
                                      (heights[activeIndices[0]] - 32) / 2,
                                  width: 24,
                                  height: 32,
                                  child: _menu(
                                    row: true,
                                    index: activeIndices[0],
                                  ),
                                ),
                                Positioned(
                                  left: xs[activeIndices[1] + 1] - 16,
                                  top: ys[activeIndices[0]] + 8,
                                  width: 16,
                                  height: heights[activeIndices[0]] - 24,
                                  child: _resizeGrip(row: false),
                                ),
                                Positioned(
                                  left: xs[activeIndices[1]] + 8,
                                  top: ys[activeIndices[0] + 1] - 16,
                                  width: widths[activeIndices[1]] - 24,
                                  height: 16,
                                  child: _resizeGrip(row: true),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Keep these wrappers mounted when overflow changes during a drag, so
        // scroll positions and divider recognizers retain their identity.
        if (!preview) {
          grid = _scrollbar(
            row: true,
            visible: horizontalOverflow,
            child: Padding(
              padding: EdgeInsets.only(bottom: horizontalGutter),
              child: grid,
            ),
          );
          grid = _scrollbar(
            row: false,
            visible: verticalOverflow,
            bottomPadding: horizontalGutter,
            child: Padding(
              padding: EdgeInsets.only(right: verticalGutter),
              child: grid,
            ),
          );
        }
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(scrollbars: false, dragDevices: _dragDevices),
          child: preview ? IgnorePointer(child: grid) : grid,
        );
      },
    );
  }

  Widget _scrollbar({
    required bool row,
    required bool visible,
    required Widget child,
    double bottomPadding = 0,
  }) => RawScrollbar(
    key: ValueKey(
      'table_${row ? 'horizontal' : 'vertical'}_scrollbar_${_table.id}',
    ),
    controller: row ? _horizontal : _vertical,
    thumbVisibility: visible,
    interactive: visible,
    thickness: 4,
    radius: const Radius.circular(2),
    thumbColor: Theme.of(
      context,
    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
    crossAxisMargin: 6,
    mainAxisMargin: 4,
    padding: EdgeInsets.only(bottom: bottomPadding),
    scrollbarOrientation: row
        ? ScrollbarOrientation.bottom
        : ScrollbarOrientation.right,
    notificationPredicate: (notification) =>
        notification.depth == (row ? 0 : 1) &&
        notification.metrics.axis == (row ? Axis.horizontal : Axis.vertical),
    child: child,
  );

  Widget _buildCell(
    String position,
    List<double> xs,
    List<double> ys,
    List<double> widths,
    List<double> heights,
    ColorScheme colors,
  ) {
    final indices = position.split(':').map(int.parse).toList();
    final row = indices[0];
    final column = indices[1];
    return Positioned(
      key: ValueKey('$_structureRevision:$position'),
      left: xs[column],
      top: ys[row],
      width: widths[column],
      height: heights[row],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _hasActiveCell && _activeCell == position
              ? colors.primary.withValues(alpha: 0.035)
              : null,
          border: _hasActiveCell && _activeCell == position
              ? Border.all(color: colors.primary, width: 1.5)
              : Border(
                  top: row == 0
                      ? BorderSide(color: colors.outlineVariant)
                      : BorderSide.none,
                  left: column == 0
                      ? BorderSide(color: colors.outlineVariant)
                      : BorderSide.none,
                  right: BorderSide(color: colors.outlineVariant),
                  bottom: BorderSide(color: colors.outlineVariant),
                ),
        ),
        child: ScrollConfiguration(
          // Suppress automatic bars for the grid, but retain the containing
          // editor's cell-scroll behavior outside compact previews.
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: widget.previewMaxHeight != null ? false : null,
            dragDevices: _dragDevices,
          ),
          child: _TableCell(
            delta: _table.cell(row, column),
            note: widget.note,
            readOnly: widget.readOnly,
            editing: widget.editing,
            previewMaxHeight: widget.previewMaxHeight,
            label: context.l10n.tableCellLabel(row + 1, column + 1),
            width: widths[column] - 16,
            height: heights[row] - 16,
            onFocus: (controller) {
              setState(() {
                _activeCell = position;
                _activeController = controller;
              });
            },
            onChanged: (delta) {
              var next = _table.withCell(row, column, delta);
              if (delta.any(
                    (op) =>
                        op is Map &&
                        op['insert'] is Map &&
                        (op['insert'] as Map).containsKey(NoteTableData.type),
                  ) &&
                  !next.rowHeights.containsKey(row)) {
                next = next.resizeRow(row, 240);
              }
              _commit(next);
            },
          ),
        ),
      ),
    );
  }
}

String _columnLabel(int index) {
  var label = '';
  for (var value = index + 1; value > 0; value = (value - 1) ~/ 26) {
    label = String.fromCharCode(65 + (value - 1) % 26) + label;
  }
  return label;
}

class _TableCell extends StatefulWidget {
  const _TableCell({
    required this.delta,
    required this.note,
    required this.readOnly,
    required this.editing,
    required this.onChanged,
    required this.onFocus,
    required this.label,
    required this.width,
    required this.height,
    this.previewMaxHeight,
  });
  final List<dynamic> delta;
  final Note note;
  final bool readOnly;
  final NoteEmbedEditing? editing;
  final ValueChanged<List<dynamic>> onChanged;
  final ValueChanged<QuillController> onFocus;
  final String label;
  final double width;
  final double height;
  final double? previewMaxHeight;
  @override
  State<_TableCell> createState() => _TableCellState();
}

class _TableCellState extends State<_TableCell> {
  late final QuillController _controller;
  final _focus = FocusNode();
  final _editorKey = GlobalKey<EditorState>();
  final _scroll = ScrollController();
  late StreamSubscription<DocChange> _changes;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _controller = NoteEditorController(
      document: documentFromJsonSafe(widget.delta)
        ..setCustomRules(customQuillRules),
      selection: const TextSelection.collapsed(offset: 0),
      readOnly: widget.readOnly,
    );
    _listen();
    _focus.addListener(_focused);
  }

  void _listen() {
    _changes = _controller.changes.listen((_) {
      if (!_applying && !widget.readOnly) {
        widget.onChanged(_controller.document.toDelta().toJson());
      }
    });
  }

  void _focused() {
    if (!_focus.hasPrimaryFocus || widget.readOnly) return;
    widget.editing?.activate(_controller, _focus);
    widget.onFocus(_controller);
  }

  bool get _matchesSnapshot =>
      jsonEncode(_controller.document.toDelta().toJson()) ==
      jsonEncode(normalizeNoteBlocks(Delta.fromJson(widget.delta)).toJson());

  @override
  void didUpdateWidget(_TableCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.readOnly = widget.readOnly;
    if (widget.readOnly) widget.editing?.release(_controller);
    if (!_matchesSnapshot) {
      // Undo updates the parent during build. Notify the shared toolbar only
      // once the frame is complete, using the latest cell snapshot.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _matchesSnapshot) return;
        _applySnapshot();
      });
    }
  }

  void _applySnapshot() {
    _applying = true;
    _changes.cancel();
    final selection = _controller.selection;
    final previousDocument = _controller.document;
    _controller.document = documentFromJsonSafe(widget.delta)
      ..setCustomRules(customQuillRules);
    _controller.updateSelection(
      TextSelection.collapsed(
        offset: selection.baseOffset.clamp(0, _controller.document.length - 1),
      ),
      ChangeSource.remote,
    );
    previousDocument.close();
    _listen();
    _applying = false;
  }

  @override
  void dispose() {
    widget.editing?.release(_controller);
    _focus.removeListener(_focused);
    _changes.cancel();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.readOnly ? null : _focus.requestFocus,
      child: ListenableBuilder(
        listenable: widget.editing ?? _focus,
        builder: (context, _) => QuillEditor(
          controller: _controller,
          focusNode: _focus,
          scrollController: _scroll,
          config: QuillEditorConfig(
            editorKey: _editorKey,
            padding: const EdgeInsets.all(8),
            scrollable: true,
            expands: true,
            autoFocus: false,
            showCursor:
                !widget.readOnly &&
                identical(widget.editing?.controller, _controller),
            enableSelectionToolbar:
                widget.editing?.controller == null ||
                identical(widget.editing?.controller, _controller),
            onTapDown: (details, _) =>
                widget.editing?.handlesTapDown(
                  _controller,
                  details,
                  _editorKey.currentState,
                  _focus,
                ) ??
                false,
            onTapUp: (details, _) =>
                widget.editing?.handlesTapUp(
                  _controller,
                  details,
                  _focus,
                  _editorKey.currentState,
                ) ??
                false,
            onSingleLongTapStart: (details, _) =>
                widget.editing?.handlesGesture(
                  _controller,
                  details.globalPosition,
                ) ??
                false,
            onSingleLongTapMoveUpdate: (details, _) =>
                widget.editing?.handlesGesture(
                  _controller,
                  details.globalPosition,
                ) ??
                false,
            onSingleLongTapEnd: (details, _) =>
                widget.editing?.handlesGesture(
                  _controller,
                  details.globalPosition,
                ) ??
                false,
            customActions: widget.editing?.rootController == null
                ? null
                : {
                    UndoTextIntent: CallbackAction<UndoTextIntent>(
                      onInvoke: (_) {
                        if (!widget.readOnly) {
                          widget.editing!.rootController!.undo();
                        }
                        return null;
                      },
                    ),
                    RedoTextIntent: CallbackAction<RedoTextIntent>(
                      onInvoke: (_) {
                        if (!widget.readOnly) {
                          widget.editing!.rootController!.redo();
                        }
                        return null;
                      },
                    ),
                  },
            customLeadingBlockBuilder: customLeadingBlockBuilder,
            customStyles: buildQuillStyles(
              foregroundColor:
                  DefaultTextStyle.of(context).style.color ??
                  Theme.of(context).colorScheme.onSurface,
              backgroundColor: widget.note.color,
            ),
            embedBuilders: noteEmbedBuilders(
              note: widget.note,
              editing: widget.editing,
              inlineWidth: widget.width,
              tablePreviewMaxHeight: widget.previewMaxHeight,
              // Leave room for the embed's padding and the text line descent.
              mediaMaxHeight: math.max(1, widget.height - 16),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A drag that starts on a cell divider belongs to resizing even if the first
/// movement is diagonal. Scrolling remains available through the cell bodies.
class _TableResizeGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
