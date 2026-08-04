import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

typedef NoteOrderContextForView =
    NoteOrderContext? Function(NoteViewMode viewMode);

class NoteDisplayOptionsButton extends StatelessWidget {
  const NoteDisplayOptionsButton({
    super.key,
    this.showViewOptions = true,
    this.showSortOptions = true,
    this.orderContext,
    this.contextForView,
    this.contextLabel,
    this.onSortChanged,
    this.persistSortMode,
  });

  final bool showViewOptions;
  final bool showSortOptions;
  final NoteOrderContext? orderContext;
  final NoteOrderContextForView? contextForView;
  final String? contextLabel;
  final ValueChanged<NoteSortMode>? onSortChanged;
  final Future<void> Function(NoteSortMode mode)? persistSortMode;

  NoteOrderContext? _contextFor(NoteViewMode viewMode) {
    return contextForView?.call(viewMode) ??
        orderContext ??
        switch (viewMode) {
          NoteViewMode.grid => const NoteOrderContext.mainGrid(),
          NoteViewMode.list => const NoteOrderContext.mainList(),
          NoteViewMode.folderLabels || NoteViewMode.folderColors => null,
        };
  }

  Future<void> _showOptions(BuildContext context) async {
    final initialViewMode = AppState.notesViewMode;
    final initialOrderContext = _contextFor(initialViewMode);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _NoteDisplayOptionsDialog(
        showViewOptions: showViewOptions,
        showSortOptions: showSortOptions,
        initialViewMode: initialViewMode,
        initialOrderContext: initialOrderContext,
        contextForView: _contextFor,
        onSave: (selection) async {
          final viewChanged =
              showViewOptions && selection.viewMode != initialViewMode;
          final targetContext = selection.orderContext;
          final initialMode = targetContext == null
              ? null
              : NoteSortService().snapshotFor(targetContext).mode;
          final sortChanged =
              showSortOptions &&
              targetContext != null &&
              selection.sortMode != initialMode;

          if (sortChanged) {
            final injectedPersistence = persistSortMode;
            if (injectedPersistence != null) {
              await injectedPersistence(selection.sortMode);
            } else {
              await NoteSortService().setMode(
                targetContext,
                selection.sortMode,
              );
            }
          }
          if (viewChanged) {
            AppState.notesViewMode = selection.viewMode;
          }
          if (sortChanged) {
            onSortChanged?.call(selection.sortMode);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeContext = _contextFor(AppState.notesViewMode);
    final activeMode = activeContext == null
        ? null
        : NoteSortService().snapshotFor(activeContext).mode;
    final defaultMode = activeContext == null
        ? null
        : NoteSortService.defaultSortModeFor(activeContext);
    final modeLabel = activeMode == null
        ? null
        : _sortLabel(context, activeMode);
    final tooltipDetails = [
      if (contextLabel != null && contextLabel!.isNotEmpty) contextLabel!,
      ?modeLabel,
    ];
    final tooltip = tooltipDetails.isEmpty
        ? context.l10n.noteDisplayOptions
        : '${context.l10n.noteDisplayOptions} · ${tooltipDetails.join(' · ')}';
    return Semantics(
      label: tooltip,
      button: true,
      child: IconButton(
        key: const ValueKey('note-display-options-button'),
        tooltip: tooltip,
        onPressed: () => _showOptions(context),
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.tune),
            if (activeMode != null && activeMode != defaultMode)
              PositionedDirectional(
                key: const ValueKey('note-sort-non-default-indicator'),
                end: -2,
                bottom: -2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoteDisplayOptionsSelection {
  const _NoteDisplayOptionsSelection({
    required this.viewMode,
    required this.orderContext,
    required this.sortMode,
  });

  final NoteViewMode viewMode;
  final NoteOrderContext? orderContext;
  final NoteSortMode sortMode;
}

class _NoteDisplayOptionsDialog extends StatefulWidget {
  const _NoteDisplayOptionsDialog({
    required this.showViewOptions,
    required this.showSortOptions,
    required this.initialViewMode,
    required this.initialOrderContext,
    required this.contextForView,
    required this.onSave,
  });

  final bool showViewOptions;
  final bool showSortOptions;
  final NoteViewMode initialViewMode;
  final NoteOrderContext? initialOrderContext;
  final NoteOrderContextForView contextForView;
  final Future<void> Function(_NoteDisplayOptionsSelection selection) onSave;

  @override
  State<_NoteDisplayOptionsDialog> createState() =>
      _NoteDisplayOptionsDialogState();
}

class _NoteDisplayOptionsDialogState extends State<_NoteDisplayOptionsDialog> {
  late NoteViewMode _viewMode;
  late NoteOrderContext? _orderContext;
  late NoteSortMode _sortMode;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _viewMode = widget.initialViewMode;
    _orderContext = widget.initialOrderContext;
    _sortMode = _orderContext == null
        ? NoteSortMode.updatedNewest
        : NoteSortService().snapshotFor(_orderContext!).mode;
  }

  bool get _sortVisible => widget.showSortOptions && _orderContext != null;

  bool get _sortChanged {
    final context = _orderContext;
    if (!_sortVisible || context == null) return false;
    return _sortMode != NoteSortService().snapshotFor(context).mode;
  }

  bool get _hasChanges =>
      _sortChanged ||
      (widget.showViewOptions && _viewMode != widget.initialViewMode);

  void _selectViewMode(NoteViewMode? mode) {
    if (_saving || mode == null) return;
    final nextContext = widget.contextForView(mode);
    setState(() {
      _viewMode = mode;
      _orderContext = nextContext;
      _sortMode = nextContext == null
          ? NoteSortMode.updatedNewest
          : NoteSortService().snapshotFor(nextContext).mode;
      _saveFailed = false;
    });
  }

  void _selectSortMode(NoteSortMode? mode) {
    if (_saving || mode == null) return;
    if (_orderContext?.reorderable == false && mode == NoteSortMode.custom) {
      return;
    }
    setState(() {
      _sortMode = mode;
      _saveFailed = false;
    });
  }

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.onSave(
        _NoteDisplayOptionsSelection(
          viewMode: _viewMode,
          orderContext: _orderContext,
          sortMode: _sortMode,
        ),
      );
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        context.l10n.noteDisplayOptionsSaved,
        Directionality.of(context),
      );
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_DISPLAY_OPTIONS] Failed to save options',
        error,
        stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  Widget _sectionTitle(BuildContext context, String label) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
      ),
    );
  }

  Widget _reorderGuidance(BuildContext context) {
    final custom = _sortMode == NoteSortMode.custom;
    final colorScheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 160),
        child: Container(
          key: ValueKey(custom),
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                custom ? Icons.open_with : Icons.info_outline,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  custom
                      ? context.l10n.reorderCustomHint
                      : context.l10n.reorderDateSortHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(context.l10n.noteDisplayOptions),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showViewOptions) ...[
                _sectionTitle(context, context.l10n.selectView),
                RadioGroup<NoteViewMode>(
                  groupValue: _viewMode,
                  onChanged: _selectViewMode,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final mode in NoteViewMode.values)
                        RadioListTile<NoteViewMode>(
                          value: mode,
                          enabled: !_saving,
                          selected: _viewMode == mode,
                          secondary: Icon(_viewIcon(mode)),
                          title: Text(_viewLabel(context, mode)),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          dense: true,
                        ),
                    ],
                  ),
                ),
                if (_sortVisible) const Divider(),
              ],
              if (_sortVisible) ...[
                _sectionTitle(context, context.l10n.sortBy),
                RadioGroup<NoteSortMode>(
                  groupValue: _sortMode,
                  onChanged: _selectSortMode,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final mode in NoteSortMode.values)
                        if (mode != NoteSortMode.custom ||
                            _orderContext!.reorderable)
                          RadioListTile<NoteSortMode>(
                            value: mode,
                            enabled: !_saving,
                            selected: _sortMode == mode,
                            secondary: Icon(_sortIcon(mode)),
                            title: Text(_sortLabel(context, mode)),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            dense: true,
                          ),
                    ],
                  ),
                ),
                if (_orderContext!.reorderable) _reorderGuidance(context),
              ],
              if (_saveFailed)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    key: const ValueKey('note-display-options-error'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      context.l10n.noteDisplayOptionsSaveFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: !_hasChanges || _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.save),
          ),
        ],
      ),
    );
  }
}

String _viewLabel(BuildContext context, NoteViewMode mode) => switch (mode) {
  NoteViewMode.grid => context.l10n.viewModeGrid,
  NoteViewMode.list => context.l10n.viewModeList,
  NoteViewMode.folderLabels => context.l10n.labels,
  NoteViewMode.folderColors => context.l10n.viewModeColors,
};

IconData _viewIcon(NoteViewMode mode) => switch (mode) {
  NoteViewMode.grid => Icons.grid_view,
  NoteViewMode.list => Icons.list,
  NoteViewMode.folderLabels => Icons.label_outline,
  NoteViewMode.folderColors => Icons.palette_outlined,
};

String _sortLabel(BuildContext context, NoteSortMode mode) => switch (mode) {
  NoteSortMode.custom => context.l10n.sortCustom,
  NoteSortMode.createdNewest => context.l10n.sortCreatedNewest,
  NoteSortMode.updatedNewest => context.l10n.sortUpdatedNewest,
};

IconData _sortIcon(NoteSortMode mode) => switch (mode) {
  NoteSortMode.custom => Icons.open_with,
  NoteSortMode.createdNewest => Icons.calendar_today_outlined,
  NoteSortMode.updatedNewest => Icons.update,
};
