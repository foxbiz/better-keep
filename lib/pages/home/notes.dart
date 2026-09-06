import 'dart:async';
import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:better_keep/components/google_keep_import_card.dart';
import 'package:better_keep/components/note_display_options_button.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/pages/home/folder_breadcrumb.dart';
import 'package:better_keep/pages/home/google_keep_import_visibility.dart';
import 'package:better_keep/components/folder_tile.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/pages/home/labels.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

@visibleForTesting
Future<void> runNotesRefreshSequence({
  required Future<void> Function() refreshNotes,
  required Future<void> Function() refreshLabels,
  required Future<void> Function() reloadNotes,
}) async {
  try {
    await refreshNotes();
    await refreshLabels();
  } finally {
    await reloadNotes();
  }
}

class Notes extends StatefulWidget {
  final String? searchQuery;
  final bool searchMode;

  const Notes({super.key, this.searchQuery, this.searchMode = false});

  @override
  State<Notes> createState() => NotesState();
}

class NotesState extends State<Notes> with SingleTickerProviderStateMixin {
  static const _gap = 8.0;

  late bool _selectionMode;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _stickyHeaderKey = GlobalKey();

  Iterable<Note>? _notes;
  Iterable<Label>? _labels;
  Iterable<NoteColor>? _colors;
  int? _notesCountWithoutLabels;
  int _loadGeneration = 0;
  int _noteRevision = 0;
  bool _hasStoredNotes = true;
  double _pendingOffset = 0.0;
  bool _showLoader = false;
  Timer? _updateShowLoaderTimeout;
  Timer? _folderUpdateDebounce;
  final MasonryLayoutController _pinnedLayoutController =
      MasonryLayoutController();
  final MasonryLayoutController _otherLayoutController =
      MasonryLayoutController();
  final MasonryLayoutController _unsectionedLayoutController =
      MasonryLayoutController();
  final NoteReorderController _pinnedReorderController =
      NoteReorderController();
  final NoteReorderController _otherReorderController = NoteReorderController();
  NoteReorderController? _activeReorderController;
  MasonryLayoutController? _activeLayoutController;
  bool? _activePinnedSection;
  int? _draggingNoteId;
  Offset? _dragGlobalPosition;
  Offset _dragAnchor = Offset.zero;
  bool _invalidPinnedTarget = false;
  DateTime? _lastCandidateHaptic;
  Offset? _pendingDragEvaluationPosition;
  bool _dragEvaluationScheduled = false;
  late final Ticker _autoScrollTicker;
  Duration? _lastAutoScrollElapsed;
  double _autoScrollVelocity = 0;
  bool _pendingRefreshAfterDrag = false;
  int? _lastNoteCrossAxisCount;

  @override
  void initState() {
    _autoScrollTicker = createTicker(_onAutoScrollTick);
    _fetchData();

    _selectionMode = AppState.selectedNotes.isNotEmpty;
    _scrollController.addListener(() {
      _pendingOffset = _scrollController.offset;
    });

    Label.on("changed", _fetchData);
    Note.on("changed", _notesListener);
    AppState.subscribe("show_notes", _showNotesListener);
    AppState.subscribe("filter_labels", _labelFilterListener);
    AppState.subscribe("match_all_labels", _labelFilterListener);
    AppState.subscribe("notes_view_mode", _viewModeListener);
    AppState.subscribe("selected_notes", _selectedNotesListener);
    AppState.subscribe("current_folder", _updateCurrentFolderListener);
    NoteSortService().snapshots.addListener(_sortStateListener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_pendingOffset);
    });

    super.initState();
  }

  @override
  void dispose() {
    _loadGeneration++;
    if (_activeReorderController != null) {
      final orderContext = _activeOrderContext;
      if (orderContext != null) {
        unawaited(NoteSortService().endDrag(orderContext, committed: false));
      }
      _activeReorderController?.clear();
    }
    _autoScrollTicker.dispose();
    _folderUpdateDebounce?.cancel();
    _updateShowLoaderTimeout?.cancel();
    _scrollController.dispose();
    Label.off("changed", _fetchData);
    Note.off("changed", _notesListener);
    AppState.unsubscribe("show_notes", _showNotesListener);
    AppState.unsubscribe("filter_labels", _labelFilterListener);
    AppState.unsubscribe("match_all_labels", _labelFilterListener);
    AppState.unsubscribe("notes_view_mode", _viewModeListener);
    AppState.unsubscribe("selected_notes", _selectedNotesListener);
    AppState.unsubscribe("current_folder", _updateCurrentFolderListener);
    NoteSortService().snapshots.removeListener(_sortStateListener);
    super.dispose();
  }

  @override
  void didUpdateWidget(Notes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery ||
        oldWidget.searchMode != widget.searchMode) {
      _fetchData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppState.notesViewMode.isFolderMode ||
        widget.searchMode ||
        AppState.showNotes != NoteType.all) {
      return _buildDefaultLayout();
    }

    return _buildFolderModeLayout();
  }

  Widget _buildFolderModeLayout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget content;
        if (_notes == null) {
          if (!_showLoader) {
            content = SizedBox.shrink();
          } else {
            content = Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).colorScheme.primary,
              ),
            );
          }
        } else if (AppState.currentFolder != null) {
          content = _buildNotesView();
        } else {
          content = _buildFoldersGrid();
        }

        return RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: _StickyHeaderDelegate(
                  child: Padding(
                    key: _stickyHeaderKey,
                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: FolderBreadcrumb(
                            location: AppState.currentFolder,
                          ),
                        ),
                        NoteDisplayOptionsButton(
                          orderContext: _activeOrderContext,
                          showSortOptions: AppState.currentFolder != null,
                          contextForView: _contextForView,
                          contextLabel: _activeContextLabel,
                          onSortChanged: handleSortModeChanged,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 1200),
                      child: content,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDefaultLayout() {
    final viewMode = AppState.notesViewMode;

    return LayoutBuilder(
      key: ValueKey('default_layout_$viewMode'),
      builder: (context, constraints) {
        return RefreshIndicator(
          onRefresh: refresh,
          child: CustomScrollView(
            key: PageStorageKey('notes_scroll_view_$viewMode'),
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            scrollDirection: Axis.vertical,
            slivers: [
              if (!_selectionMode &&
                  AppState.showNotes == NoteType.all &&
                  (!widget.searchMode || AppState.filterLabels.isNotEmpty))
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StickyHeaderDelegate(
                    child: Padding(
                      key: _stickyHeaderKey,
                      padding: const EdgeInsets.symmetric(horizontal: 6.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Labels(
                              key: Key('labels_widget'),
                              selectedLabels: AppState.filterLabels,
                              readOnly: widget.searchMode,
                              onSelect: (selectedLabels) {
                                AppState.filterLabels = selectedLabels
                                    .map((e) => e.name)
                                    .toList();
                              },
                            ),
                          ),
                          if (!widget.searchMode &&
                              AppState.filterLabels.isNotEmpty)
                            IconButton(
                              key: const ValueKey('clear-label-filters-button'),
                              tooltip: context.l10n.clear,
                              icon: const Icon(Icons.close),
                              onPressed: () => AppState.filterLabels = [],
                            )
                          else if (!widget.searchMode)
                            NoteDisplayOptionsButton(
                              showLabelFilterOptions: true,
                              orderContext: _activeOrderContext,
                              contextForView: _contextForView,
                              contextLabel: _activeContextLabel,
                              onSortChanged: handleSortModeChanged,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 1200),
                      child: _buildNotesView(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  (IconData, String) _getEmptyStateContent() {
    if (widget.searchMode) {
      return (Icons.search_off, context.l10n.noMatchingNotes);
    }
    return switch (AppState.showNotes) {
      NoteType.all => (Icons.note_outlined, context.l10n.noNotesYet),
      NoteType.archived => (
        Icons.archive_outlined,
        context.l10n.noArchivedNotes,
      ),
      NoteType.trashed => (Icons.delete_outline, context.l10n.trashIsEmpty),
      NoteType.pinned => (Icons.push_pin_outlined, context.l10n.noPinnedNotes),
      NoteType.locked => (Icons.lock_outline, context.l10n.noLockedNotes),
      NoteType.reminder => (
        Icons.notifications_none,
        context.l10n.noRemindersSet,
      ),
    };
  }

  bool get _showGoogleKeepImportAction => shouldShowGoogleKeepImportAction(
    isSearchMode: widget.searchMode,
    isAllNotesView: AppState.showNotes == NoteType.all,
    hasLabelFilters: AppState.filterLabels.isNotEmpty,
    isInsideFolder: AppState.currentFolder != null,
    isFolderMode: AppState.notesViewMode.isFolderMode,
    hasStoredNotes: _hasStoredNotes,
  );

  Future<void> refresh() async {
    try {
      _scrollController.jumpTo(0.0);
      await runNotesRefreshSequence(
        refreshNotes: NoteSyncService().refresh,
        refreshLabels: LabelSyncService().refresh,
        reloadNotes: _fetchData,
      );
    } catch (e) {
      AppLogger.error("[REFRESH] Error refreshing data: $e");
    }
  }

  Future<void> _fetchData([dynamic _]) async {
    final generation = ++_loadGeneration;
    final noteRevision = _noteRevision;
    final orderContext = _activeOrderContext;
    _startLoading();
    final notes = await _fetchNotes();
    if (!_isCurrentLoad(generation)) return;
    final hasStoredNotes = await _loadHasStoredNotes();
    if (!_isCurrentLoad(generation)) return;
    final colors = await Note.getAllColors();
    if (!_isCurrentLoad(generation)) return;
    final labels = await Label.get(countNotes: true);
    if (!_isCurrentLoad(generation)) return;
    final notesCountWithoutLabels = await Note.countByLabels(null);
    if (!_isCurrentLoad(generation)) return;
    if (!widget.searchMode && orderContext != null) {
      await NoteSortService().ensureContext(orderContext, visibleNotes: notes);
    }
    if (!_isCurrentLoad(generation)) return;
    // A note may change while its older snapshot is being decoded or metadata
    // is loading. Coalesce those events into one fresh load before publishing.
    if (noteRevision != _noteRevision) {
      await _fetchData();
      return;
    }
    _notes = notes;
    _hasStoredNotes = hasStoredNotes;
    _colors = colors;
    _labels = labels;
    _notesCountWithoutLabels = notesCountWithoutLabels;
    _stopLoading();
    setState(() {});
  }

  bool _isCurrentLoad(int generation) =>
      mounted && generation == _loadGeneration;

  Future<List<Note>> _fetchNotes() async {
    final location = AppState.currentFolder;
    if (widget.searchMode ||
        location == null ||
        AppState.showNotes != NoteType.all) {
      return await Note.get(
        AppState.showNotes,
        AppState.filterLabels,
        widget.searchQuery,
        AppState.matchAllLabels,
      );
    }

    final Iterable<Note> notes;
    if (location.isPinned) {
      notes = await Note.get(NoteType.pinned);
    } else if (location.labelName != null) {
      notes = await Note.filterByLabels(
        location.labelName!.isEmpty ? null : [location.labelName!],
        matchAllLabels: AppState.matchAllLabels,
      );
    } else if (location.color != null) {
      notes = await Note.filterByColor(location.color!);
    } else {
      notes = [];
    }

    return notes.toList();
  }

  Future<bool> _loadHasStoredNotes() async {
    final rows = await AppState.db.rawQuery(
      'SELECT EXISTS(SELECT 1 FROM ${Note.model} LIMIT 1) AS has_notes',
    );
    return rows.first['has_notes'] == 1;
  }

  Future<void> _refreshHasStoredNotes() async {
    final hasStoredNotes = await _loadHasStoredNotes();
    if (!mounted) return;
    setState(() => _hasStoredNotes = hasStoredNotes);
  }

  void _startLoading() {
    _updateShowLoaderTimeout?.cancel();
    _showLoader = false;
    _updateShowLoaderTimeout = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _showLoader = true);
    });
  }

  void _stopLoading() {
    _updateShowLoaderTimeout?.cancel();
    if (mounted && _showLoader) setState(() => _showLoader = false);
  }

  void _selectedNotesListener(dynamic payload) {
    final selectedNotes = payload as List<Note>;
    setState(() {
      _selectionMode = selectedNotes.isNotEmpty;
    });
  }

  void _sortStateListener() {
    if (!mounted) return;
    setState(() {});
  }

  void handleSortModeChanged(NoteSortMode mode) {
    if (_activeReorderController != null) {
      unawaited(_cancelDrag());
    }
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _viewModeListener(dynamic payload) async {
    _loadGeneration++;
    if (_activeReorderController != null) await _cancelDrag();
    if (!mounted) return;
    AppState.currentFolder = null;
    _showNotesListener(payload);
  }

  void _showNotesListener(dynamic _) {
    if (AppState.filterLabels.isNotEmpty) {
      AppState.filterLabels = [];
    } else {
      unawaited(_fetchData());
    }
  }

  Future<void> _labelFilterListener(dynamic _) async {
    final generation = ++_loadGeneration;
    if (!mounted) return;
    setState(() {});
    if (_activeReorderController != null) await _cancelDrag();
    if (!_isCurrentLoad(generation)) return;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _fetchData();
  }

  void _updateCurrentFolderListener(dynamic payload) {
    if (_activeReorderController != null) {
      unawaited(_cancelDrag());
    }
    if (!mounted) return;
    setState(() {});
  }

  NoteOrderContext? get _activeOrderContext {
    if (widget.searchMode) return null;
    if (AppState.showNotes != NoteType.all) {
      return NoteOrderContext.system(AppState.showNotes.name);
    }
    final location = AppState.currentFolder;
    if (location != null) {
      if (location.isPinned) return const NoteOrderContext.pinned();
      if (location.color != null) {
        return NoteOrderContext.color(location.color!.toARGB32());
      }
      if (location.labelName != null) {
        final stableId =
            location.labelSyncId ??
            _labels
                ?.where((label) => label.name == location.labelName)
                .firstOrNull
                ?.syncId ??
            (location.labelName!.isEmpty
                ? '__unlabeled__'
                : 'legacy-name:${location.labelName}');
        return NoteOrderContext.label(stableId);
      }
    }
    if (AppState.notesViewMode.isFolderMode) return null;
    return AppState.notesViewMode == NoteViewMode.list
        ? const NoteOrderContext.mainList()
        : const NoteOrderContext.mainGrid();
  }

  NoteOrderContext? _contextForView(NoteViewMode viewMode) {
    if (viewMode == NoteViewMode.grid) {
      return const NoteOrderContext.mainGrid();
    }
    if (viewMode == NoteViewMode.list) {
      return const NoteOrderContext.mainList();
    }
    if (viewMode == AppState.notesViewMode && AppState.currentFolder != null) {
      return _activeOrderContext;
    }
    return null;
  }

  String? get _activeContextLabel {
    final location = AppState.currentFolder;
    if (location != null) {
      if (location.isPinned) return context.l10n.pinnedNotes;
      if (location.labelName != null) {
        return location.labelName!.isEmpty
            ? context.l10n.labels
            : location.labelName;
      }
      if (location.color != null) return context.l10n.viewModeColors;
    }
    if (AppState.showNotes != NoteType.all) {
      return _getEmptyStateContent().$2;
    }
    return AppState.notesViewMode == NoteViewMode.list
        ? context.l10n.viewModeList
        : context.l10n.viewModeGrid;
  }

  List<Note> _sortNotes(List<Note> notes) {
    final orderContext = _activeOrderContext;
    return orderContext == null
        ? notes
        : NoteSortService().sortNotes(orderContext, notes);
  }

  bool get _canReorder {
    final orderContext = _activeOrderContext;
    return orderContext != null &&
        orderContext.reorderable &&
        NoteSortService().snapshotFor(orderContext).mode ==
            NoteSortMode.custom &&
        !widget.searchMode &&
        !_selectionMode &&
        AppState.showNotes == NoteType.all &&
        (!AppState.notesViewMode.isFolderMode ||
            AppState.currentFolder != null);
  }

  NoteReorderController _reorderControllerFor(bool pinned) {
    return pinned ? _pinnedReorderController : _otherReorderController;
  }

  MasonryLayoutController _layoutControllerFor(bool pinned) {
    return pinned ? _pinnedLayoutController : _otherLayoutController;
  }

  List<Note> _sectionNotes(Iterable<Note> notes, bool pinned) {
    final section = notes.where((note) => note.pinned == pinned).toList();
    final controller = _reorderControllerFor(pinned);
    if (!controller.active) return section;
    final byId = <int, Note>{
      for (final note in section)
        if (note.id != null) note.id!: note,
    };
    return [for (final id in controller.previewIds) ?byId[id]];
  }

  void _liftNote(Note note, Offset globalPosition) {
    final noteId = note.id;
    final orderContext = _activeOrderContext;
    if (!_canReorder ||
        orderContext == null ||
        noteId == null ||
        _activeReorderController != null) {
      return;
    }
    final sorted = _sortNotes(_notes?.toList() ?? const <Note>[]);
    final sectionNotes = sorted.where((item) => item.pinned == note.pinned);
    final controller = _reorderControllerFor(note.pinned);
    final layoutController = _layoutControllerFor(note.pinned);
    controller.begin(
      ids: sectionNotes.map((item) => item.id).nonNulls,
      draggedId: noteId,
    );
    final cardRect = layoutController.globalRectFor(noteId);

    NoteSortService().beginDrag(orderContext);
    HapticFeedback.mediumImpact();
    setState(() {
      _activeReorderController = controller;
      _activeLayoutController = layoutController;
      _activePinnedSection = note.pinned;
      _draggingNoteId = noteId;
      _dragGlobalPosition = globalPosition;
      _dragAnchor = cardRect == null
          ? Offset.zero
          : globalPosition - cardRect.topLeft;
      _invalidPinnedTarget = false;
    });
  }

  void _moveDrag(Offset globalPosition) {
    final controller = _activeReorderController;
    final layoutController = _activeLayoutController;
    final draggedId = _draggingNoteId;
    if (controller == null || layoutController == null || draggedId == null) {
      return;
    }

    _dragGlobalPosition = globalPosition;
    layoutController.updateDragPosition(globalPosition);
    _updateAutoScrollVelocity(globalPosition);
    _scheduleDragEvaluation(globalPosition);
  }

  void _scheduleDragEvaluation(Offset globalPosition) {
    _pendingDragEvaluationPosition = globalPosition;
    if (_dragEvaluationScheduled) return;
    _dragEvaluationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dragEvaluationScheduled = false;
      final pendingPosition = _pendingDragEvaluationPosition;
      _pendingDragEvaluationPosition = null;
      if (!mounted || pendingPosition == null) return;
      _evaluateDrag(pendingPosition);
    });
  }

  void _evaluateDrag(Offset globalPosition) {
    final controller = _activeReorderController;
    final layoutController = _activeLayoutController;
    final draggedId = _draggingNoteId;
    if (controller == null || layoutController == null || draggedId == null) {
      return;
    }

    final otherLayout = _activePinnedSection == true
        ? _otherLayoutController
        : _pinnedLayoutController;
    final activeBounds = layoutController.globalBounds;
    final otherBounds = otherLayout.globalBounds;
    final crossedSectionBoundary =
        activeBounds != null &&
        otherBounds != null &&
        (_activePinnedSection == true
            ? globalPosition.dy > activeBounds.bottom
            : globalPosition.dy < activeBounds.top);
    final invalidTarget =
        otherLayout.containsGlobalPosition(globalPosition) ||
        crossedSectionBoundary;
    var orderChanged = false;
    if (!invalidTarget) {
      final resolution = layoutController.resolveInsertion(
        globalPosition: globalPosition,
        excludingId: draggedId,
        previousResolution: controller.dropResolution,
      );
      final currentInsertionIndex = controller.currentInsertionIndex;
      final movesBackwardDuringAutoScroll =
          resolution != null &&
          !NoteReorderController.allowsInsertionDuringAutoScroll(
            currentInsertionIndex: currentInsertionIndex,
            candidateInsertionIndex: resolution.insertionIndex,
            scrollVelocity: _autoScrollVelocity,
          );
      if (resolution != null && !movesBackwardDuringAutoScroll) {
        orderChanged = controller.accept(resolution);
      }
    }

    if (orderChanged) {
      final now = DateTime.now();
      if (_lastCandidateHaptic == null ||
          now.difference(_lastCandidateHaptic!) >
              const Duration(milliseconds: 45)) {
        _lastCandidateHaptic = now;
        HapticFeedback.selectionClick();
      }
    } else if (invalidTarget && !_invalidPinnedTarget) {
      HapticFeedback.selectionClick();
    }
    final invalidStateChanged = invalidTarget != _invalidPinnedTarget;
    _invalidPinnedTarget = invalidTarget;
    if (mounted && (orderChanged || invalidStateChanged)) {
      setState(() {
        // Rebuild only when layout order or boundary decoration changes.
      });
    }
  }

  Future<void> _dropDrag(Offset globalPosition) async {
    final controller = _activeReorderController;
    final draggedId = _draggingNoteId;
    if (controller == null || draggedId == null) return;
    final orderContext = _activeOrderContext;
    if (orderContext == null) {
      await _cancelDrag();
      return;
    }
    _pendingDragEvaluationPosition = null;
    _activeLayoutController?.updateDragPosition(globalPosition);
    _stopAutoScroll();
    _evaluateDrag(globalPosition);

    final otherLayout = _activePinnedSection == true
        ? _otherLayoutController
        : _pinnedLayoutController;
    if (_invalidPinnedTarget ||
        otherLayout.containsGlobalPosition(globalPosition)) {
      await _cancelDrag(showPinnedBoundary: true);
      return;
    }
    if (!controller.changed) {
      await _cancelDrag();
      return;
    }

    final preview = controller.previewIds;
    final draggedIndex = preview.indexOf(draggedId);
    final int targetId;
    final bool placeAfter;
    if (draggedIndex > 0) {
      targetId = preview[draggedIndex - 1];
      placeAfter = true;
    } else if (preview.length > 1) {
      targetId = preview[1];
      placeAfter = false;
    } else {
      await _cancelDrag();
      return;
    }

    _activeLayoutController?.updateDragPosition(null);
    if (mounted) setState(() => _dragGlobalPosition = null);
    try {
      await NoteSortService().reorderVisibleNotes(
        context: orderContext,
        draggedId: draggedId,
        targetId: targetId,
        placeAfter: placeAfter,
        visibleNotes: _notes ?? const <Note>[],
      );
      await NoteSortService().endDrag(orderContext, committed: true);
    } on PinnedSectionReorderException {
      await NoteSortService().endDrag(orderContext, committed: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.pinnedReorderBoundary)),
        );
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_SORT] Failed to persist drag order',
        error,
        stackTrace,
      );
      await NoteSortService().endDrag(orderContext, committed: false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.reorderSaveFailed)));
      }
    } finally {
      _clearDragState();
    }
  }

  Future<void> _cancelDrag({bool showPinnedBoundary = false}) async {
    if (_activeReorderController == null) return;
    _stopAutoScroll();
    final orderContext = _activeOrderContext;
    if (orderContext != null) {
      await NoteSortService().endDrag(orderContext, committed: false);
    }
    _clearDragState();
    if (showPinnedBoundary && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.pinnedReorderBoundary)),
      );
    }
  }

  void _clearDragState() {
    _activeReorderController?.clear();
    _activeReorderController = null;
    _activeLayoutController = null;
    _activePinnedSection = null;
    _draggingNoteId = null;
    _dragGlobalPosition = null;
    _dragAnchor = Offset.zero;
    _invalidPinnedTarget = false;
    _lastCandidateHaptic = null;
    _pendingDragEvaluationPosition = null;
    if (mounted) setState(() {});
    if (_pendingRefreshAfterDrag) {
      _pendingRefreshAfterDrag = false;
      unawaited(_fetchData());
    }
  }

  double _autoScrollVelocityFor(Offset globalPosition) {
    if (!_scrollController.hasClients) return 0;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return 0;
    }
    var top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = viewport.localToGlobal(Offset(0, viewport.size.height)).dy;
    final header = _stickyHeaderKey.currentContext?.findRenderObject();
    if (header is RenderBox && header.attached && header.hasSize) {
      top = header
          .localToGlobal(Offset(0, header.size.height))
          .dy
          .clamp(top, bottom);
    }
    // Keep the zones inside the visible notes area, even in a short window.
    final edge = ((bottom - top) / 2).clamp(0.0, 96.0);
    if (edge == 0) return 0;
    var velocity = 0.0;
    if (globalPosition.dy < top + edge) {
      final proximity = ((top + edge - globalPosition.dy) / edge).clamp(
        0.0,
        1.0,
      );
      velocity = -(100 + 800 * proximity * proximity);
    } else if (globalPosition.dy > bottom - edge) {
      final proximity = ((globalPosition.dy - (bottom - edge)) / edge).clamp(
        0.0,
        1.0,
      );
      velocity = 100 + 800 * proximity * proximity;
    }
    final position = _scrollController.position;
    if ((velocity < 0 && position.pixels <= position.minScrollExtent) ||
        (velocity > 0 && position.pixels >= position.maxScrollExtent)) {
      return 0;
    }
    return velocity;
  }

  void _updateAutoScrollVelocity(Offset globalPosition) {
    _autoScrollVelocity = _autoScrollVelocityFor(globalPosition);
    if (_autoScrollVelocity == 0) {
      _stopAutoScroll();
    } else if (!_autoScrollTicker.isActive) {
      _lastAutoScrollElapsed = null;
      _autoScrollTicker.start();
    }
  }

  void _onAutoScrollTick(Duration elapsed) {
    final dragPosition = _dragGlobalPosition;
    if (dragPosition == null) {
      _stopAutoScroll();
      return;
    }
    // Layout can change while the finger/cursor stays still.
    _updateAutoScrollVelocity(dragPosition);
    if (!_autoScrollTicker.isActive) return;
    final previous = _lastAutoScrollElapsed;
    _lastAutoScrollElapsed = elapsed;
    if (previous == null) return;
    final seconds = (elapsed - previous).inMicroseconds / 1000000;
    if (seconds <= 0) return;
    final position = _scrollController.position;
    final next = (_scrollController.offset + _autoScrollVelocity * seconds)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == _scrollController.offset) {
      _stopAutoScroll();
      return;
    }
    _scrollController.jumpTo(next);
    _scheduleDragEvaluation(dragPosition);
  }

  void _stopAutoScroll() {
    _autoScrollVelocity = 0;
    _lastAutoScrollElapsed = null;
    if (_autoScrollTicker.isActive) _autoScrollTicker.stop();
  }

  Future<void> _moveNoteWithKeyboard(Note note, int direction) async {
    final id = note.id;
    final orderContext = _activeOrderContext;
    if (id == null || orderContext == null) return;
    try {
      await NoteSortService().moveVisibleNote(
        context: orderContext,
        noteId: id,
        direction: direction,
        visibleNotes: _notes ?? const <Note>[],
      );
    } catch (error, stackTrace) {
      AppLogger.error('[NOTE_SORT] Keyboard reorder failed', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.reorderSaveFailed)));
      }
    }
  }

  Widget _buildNoteCard(Note note, int index) {
    final id = note.id;
    return NoteCard(
      key: ValueKey('note_card_$id'),
      note: note,
      index: index,
      reorderConfig: !_canReorder || id == null
          ? null
          : NoteCardReorderConfig(
              enabled: true,
              dragging: id == _draggingNoteId,
              dragLabel: context.l10n.dragToReorder,
              moveBeforeLabel: context.l10n.moveNoteBefore,
              moveAfterLabel: context.l10n.moveNoteAfter,
              onLift: (position) => _liftNote(note, position),
              onMove: _moveDrag,
              onDrop: (position) => unawaited(_dropDrag(position)),
              onCancel: () => unawaited(_cancelDrag()),
              onMoveBefore: () => unawaited(_moveNoteWithKeyboard(note, -1)),
              onMoveAfter: () => unawaited(_moveNoteWithKeyboard(note, 1)),
            ),
    );
  }

  void _notesListener(NoteEvent event) {
    _noteRevision++;
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      _fetchData();
      return;
    }

    if (_activeReorderController != null) {
      _pendingRefreshAfterDrag = true;
      final activeNoteChangedSection =
          event.note.id == _draggingNoteId &&
          (event.event == 'deleted' ||
              event.note.pinned != _activePinnedSection);
      if (activeNoteChangedSection) {
        unawaited(_cancelDrag());
      }
      return;
    }

    if (AppState.notesViewMode.isFolderMode) {
      _folderUpdateDebounce?.cancel();
      _folderUpdateDebounce = Timer(
        const Duration(milliseconds: 300),
        () async {
          _colors = await Note.getAllColors();
          _labels = await Label.get(countNotes: true);
          if (mounted) {
            setState(() {});
          }
        },
      );
    }

    if (AppState.selectedNotes.isNotEmpty) {
      AppState.selectedNotes = [];
    }

    if (event.event == 'deleted') {
      unawaited(_refreshHasStoredNotes());
    } else {
      _hasStoredNotes = true;
    }

    if (_notes == null) {
      return;
    }

    int index = _notes!.toList().indexWhere((note) => note.id == event.note.id);
    final newNote = event.note;

    final shouldRemove =
        event.event == "deleted" ||
        !newNote.matchesLabels(
          AppState.filterLabels,
          matchAllLabels: AppState.matchAllLabels,
        ) ||
        switch (AppState.showNotes) {
          NoteType.archived => !newNote.archived || newNote.trashed,
          NoteType.trashed => !newNote.trashed,
          NoteType.locked => !newNote.locked || newNote.trashed,
          NoteType.pinned => !newNote.pinned || newNote.trashed,
          NoteType.reminder =>
            newNote.trashed ||
                newNote.reminder == null ||
                (newNote.completed &&
                    !(newNote.reminder?.isRepeating ?? false)),
          _ => newNote.trashed || newNote.archived,
        };

    if (shouldRemove) {
      _notes = _notes!.where((note) => note.id != event.note.id);
    } else if (event.event == "updated") {
      final notesList = _notes!.toList();

      if (index != -1) {
        notesList[index] = newNote;
      } else {
        final insertIndex = newNote.pinned
            ? 0
            : notesList.indexWhere((n) => !n.pinned);
        notesList.insert(
          insertIndex == -1 ? notesList.length : insertIndex,
          newNote,
        );
      }

      _notes = _sortNotes(notesList);
    } else {
      // New note - insert and sort properly
      final notesList = _notes?.toList() ?? [];
      notesList.add(newNote);
      _notes = _sortNotes(notesList);
    }

    setState(() {});
  }

  Widget _buildNotesView() {
    if (_notes == null) {
      if (!_showLoader) {
        return SizedBox.shrink();
      }

      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }

    if (_notes!.isEmpty) {
      final (icon, message) = _getEmptyStateContent();
      return SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 48, color: Colors.grey),
                const SizedBox(width: 16),
                Text(
                  message,
                  style: const TextStyle(fontSize: 24, color: Colors.grey),
                ),
              ],
            ),
            if (AppState.showNotes == NoteType.all) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  final currentFolder = AppState.currentFolder;
                  final labels = <String>[];
                  Color color = Colors.transparent;
                  if (currentFolder != null) {
                    if (currentFolder.labelName != null &&
                        currentFolder.labelName!.isNotEmpty) {
                      labels.add(currentFolder.labelName!);
                    }
                    if (currentFolder.color != null) {
                      color = currentFolder.color!;
                    }
                  }
                  showPage(
                    context,
                    NoteEditor(
                      note: Note(
                        content: '[]',
                        labels: labels.join(','),
                        color: color,
                      ),
                    ),
                    allowFullScreen: true,
                  );
                },
                child: Text(context.l10n.createYourFirstNote),
              ),
            ],
            if (_showGoogleKeepImportAction) ...[
              const SizedBox(height: 8),
              const GoogleKeepImportButton(),
            ],
          ],
        ),
      );
    }

    return _buildNotesLayout();
  }

  Widget _buildNotesLayout() {
    final sortedNotes = _sortNotes(_notes!.toList());
    final listMode =
        !widget.searchMode && AppState.notesViewMode == NoteViewMode.list;

    return Padding(
      padding: const EdgeInsets.fromLTRB(_gap, 0, _gap, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: listMode ? 600 : 1200),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.maxWidth;
              final crossAxisCount = listMode
                  ? 1
                  : availableWidth > 900
                  ? 4
                  : availableWidth > 600
                  ? 3
                  : 2;
              if (_activeReorderController != null &&
                  _lastNoteCrossAxisCount != null &&
                  _lastNoteCrossAxisCount != crossAxisCount) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _activeReorderController != null) {
                    unawaited(_cancelDrag());
                  }
                });
              }
              _lastNoteCrossAxisCount = crossAxisCount;
              final partition = NoteSectionPartition.from(
                sortedNotes,
                isPinned: (note) => note.pinned,
              );
              final pinned = _sectionNotes(partition.pinned, true);
              final others = _sectionNotes(partition.others, false);
              final separateSections =
                  !widget.searchMode &&
                  AppState.showNotes == NoteType.all &&
                  partition.hasBoth;

              if (!separateSections) {
                final sectionNotes = pinned.isNotEmpty && others.isEmpty
                    ? pinned
                    : others.isNotEmpty && pinned.isEmpty
                    ? others
                    : sortedNotes;
                final controller = pinned.isNotEmpty && others.isEmpty
                    ? _pinnedLayoutController
                    : others.isNotEmpty && pinned.isEmpty
                    ? _otherLayoutController
                    : _unsectionedLayoutController;
                return _buildMasonrySection(
                  notes: sectionNotes,
                  controller: controller,
                  crossAxisCount: crossAxisCount,
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionHeading(
                    key: const ValueKey('pinned_notes_heading'),
                    label: context.l10n.pinnedNotes,
                  ),
                  _buildMasonrySection(
                    notes: pinned,
                    controller: _pinnedLayoutController,
                    crossAxisCount: crossAxisCount,
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeading(
                    key: const ValueKey('other_notes_heading'),
                    label: context.l10n.otherNotes,
                  ),
                  _buildMasonrySection(
                    notes: others,
                    controller: _otherLayoutController,
                    crossAxisCount: crossAxisCount,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeading({required Key key, required String label}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }

  Widget _buildMasonrySection({
    required List<Note> notes,
    required MasonryLayoutController controller,
    required int crossAxisCount,
  }) {
    final activeInSection = identical(_activeLayoutController, controller);
    return AnimatedMasonryReorderLayout(
      controller: controller,
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: _gap,
      crossAxisSpacing: _gap,
      activeId: activeInSection ? _draggingNoteId : null,
      dragGlobalPosition: activeInSection ? _dragGlobalPosition : null,
      dragAnchor: activeInSection ? _dragAnchor : Offset.zero,
      placeholderColor:
          (activeInSection && _invalidPinnedTarget
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary)
              .withValues(alpha: 0.12),
      children: [
        for (final (index, note) in notes.indexed)
          MasonryReorderItem(
            key: ValueKey('masonry_note_${note.id}'),
            id: note.id ?? -identityHashCode(note),
            child: _buildNoteCard(note, index),
          ),
      ],
    );
  }

  Widget _buildFoldersGrid() {
    final folders = <Widget>[];

    folders.add(
      FolderTile(
        type: FolderType.pinned,
        noteCount: 0,
        onTap: () => _openFolder(const FolderLocation.pinned()),
      ),
    );

    if (AppState.notesViewMode == NoteViewMode.folderLabels &&
        _labels != null) {
      folders.add(
        FolderTile(
          type: FolderType.unlabeled,
          noteCount: _notesCountWithoutLabels ?? 0,
          onTap: () => _openFolder(
            const FolderLocation.label('', syncId: '__unlabeled__'),
          ),
        ),
      );

      for (final label in _labels!) {
        folders.add(
          FolderTile(
            type: FolderType.label,
            labelName: label.name,
            noteCount: label.notesCount ?? 0,
            onTap: () => _openFolder(
              FolderLocation.label(label.name, syncId: label.syncId),
            ),
          ),
        );
      }
    } else if (AppState.notesViewMode == NoteViewMode.folderColors &&
        _colors != null) {
      for (final color in _colors!) {
        folders.add(
          FolderTile(
            type: FolderType.color,
            color: color.value,
            noteCount: color.count,
            onTap: () => _openFolder(FolderLocation.color(color.value)),
          ),
        );
      }
    }

    if (folders.isEmpty) {
      return _buildEmptyState();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _gap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final crossAxisCount = availableWidth > 900
              ? 6
              : availableWidth > 600
              ? 4
              : 3;

          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1.1,
            ),
            itemCount: folders.length,
            itemBuilder: (context, index) => folders[index],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_open_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            AppState.notesViewMode == NoteViewMode.folderLabels
                ? context.l10n.noLabelsYet
                : context.l10n.noColoredNotesYet,
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            AppState.notesViewMode == NoteViewMode.folderLabels
                ? context.l10n.addLabelsToOrganize
                : context.l10n.addColorsToOrganize,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _openFolder(FolderLocation location) async {
    _loadGeneration++;
    AppState.currentFolder = location;

    _notes = null;
    _scrollController.jumpTo(0.0);
    await _fetchData();
  }
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  static const height = 48.0;

  _StickyHeaderDelegate({required this.child});

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final isScrolled = shrinkOffset > 0;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: isScrolled ? colorScheme.surfaceContainer : colorScheme.surface,
      margin: EdgeInsets.only(bottom: 8),
      height: height,
      child: child,
    );
  }

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _StickyHeaderDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}
