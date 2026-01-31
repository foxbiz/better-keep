import 'dart:async';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/pages/home/folder_breadcrumb.dart';
import 'package:better_keep/components/folder_tile.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/labels.dart';
import 'package:better_keep/pages/home/view_mode_toggle.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

class Notes extends StatefulWidget {
  final String? searchQuery;
  final bool searchMode;

  const Notes({super.key, this.searchQuery, this.searchMode = false});

  @override
  State<Notes> createState() => NotesState();
}

class NotesState extends State<Notes> {
  static const _gap = 8.0;

  late bool _selectionMode;
  final ScrollController _scrollController = ScrollController();

  Iterable<Note>? _notes;
  Iterable<Label>? _labels;
  Iterable<NoteColor>? _colors;
  int? _notesCountWithoutLabels;
  double _pendingOffset = 0.0;
  bool _showLoader = false;
  Timer? _updateShowLoaderTimeout;
  Timer? _folderUpdateDebounce;

  @override
  void initState() {
    _fetchData();

    _selectionMode = AppState.selectedNotes.isNotEmpty;
    _scrollController.addListener(() {
      _pendingOffset = _scrollController.offset;
    });

    Label.on("changed", _fetchData);
    Note.on("changed", _notesListener);
    AppState.subscribe("show_notes", _fetchData);
    AppState.subscribe("notes_view_mode", _viewModeListener);
    AppState.subscribe("selected_notes", _selectedNotesListener);
    AppState.subscribe("current_folder", _updateCurrentFolderListener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_pendingOffset);
    });

    super.initState();
  }

  @override
  void dispose() {
    _folderUpdateDebounce?.cancel();
    _updateShowLoaderTimeout?.cancel();
    _scrollController.dispose();
    Label.off("changed", _fetchData);
    Note.off("changed", _notesListener);
    AppState.unsubscribe("show_notes", _fetchData);
    AppState.unsubscribe("notes_view_mode", _viewModeListener);
    AppState.unsubscribe("selected_notes", _selectedNotesListener);
    AppState.unsubscribe("current_folder", _updateCurrentFolderListener);
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
                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                    child: Row(
                      children: [
                        ViewModeToggle(),
                        FolderBreadcrumb(location: AppState.currentFolder),
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
              if (AppState.showNotes == NoteType.all &&
                  !widget.searchMode &&
                  !_selectionMode)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StickyHeaderDelegate(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ViewModeToggle(),
                          Expanded(
                            child: Labels(
                              key: Key('labels_widget'),
                              onSelect: (selectedLabel) async {
                                _scrollController.jumpTo(0.0);
                                _startLoading();
                                _notes = await Note.get(
                                  AppState.showNotes,
                                  selectedLabel.map((e) => e.name).toList(),
                                );
                                _stopLoading();
                                if (context.mounted) {
                                  setState(() {});
                                }
                              },
                            ),
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

  Future<void> refresh() async {
    try {
      _scrollController.jumpTo(0.0);
      await Label.fixLabels();
      await NoteSyncService().refresh();
      await LabelSyncService().refresh();
    } catch (e) {
      AppLogger.error("[REFRESH] Error refreshing data: $e");
    }
    await _fetchData();
  }

  Future<void> _fetchData([dynamic _]) async {
    _startLoading();
    _notes = await _fetchNotes();
    _colors = await Note.getAllColors();
    _labels = await Label.get(countNotes: true);
    _notesCountWithoutLabels = await Note.countByLabels(null);
    _stopLoading();
    if (mounted) {
      setState(() {});
    }
  }

  Future<List<Note>> _fetchNotes() async {
    final location = AppState.currentFolder;
    if (widget.searchMode ||
        location == null ||
        AppState.showNotes != NoteType.all) {
      return await Note.get(
        AppState.showNotes,
        AppState.filterLabels,
        widget.searchQuery,
      );
    }

    final Iterable<Note> notes;
    if (location.isPinned) {
      notes = await Note.get(NoteType.pinned);
    } else if (location.labelName != null) {
      notes = await Note.filterByLabels(
        location.labelName!.isEmpty ? null : [location.labelName!],
      );
    } else if (location.color != null) {
      notes = await Note.filterByColor(location.color!);
    } else {
      notes = [];
    }

    return notes.toList();
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
    if (_showLoader) setState(() => _showLoader = false);
  }

  void _selectedNotesListener(dynamic payload) {
    final selectedNotes = payload as List<Note>;
    setState(() {
      _selectionMode = selectedNotes.isNotEmpty;
    });
  }

  void _viewModeListener(dynamic payload) async {
    AppState.currentFolder = null;
    await _fetchData();
  }

  void _updateCurrentFolderListener(dynamic payload) {
    if (!mounted) return;
    setState(() {});
  }

  List<Note> _sortNotes(List<Note> notes) {
    final sorted = [...notes];
    sorted.sort((a, b) {
      if (a.pinned != b.pinned) return b.pinned ? 1 : -1;
      final updatedA = a.updatedAt ?? DateTime(1970);
      final updatedB = b.updatedAt ?? DateTime(1970);
      final updatedCmp = updatedB.compareTo(updatedA);
      if (updatedCmp != 0) return updatedCmp;
      final createdA = a.createdAt ?? DateTime(1970);
      final createdB = b.createdAt ?? DateTime(1970);
      return createdB.compareTo(createdA);
    });
    return sorted;
  }

  void _notesListener(NoteEvent event) {
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      _fetchData();
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

    if (_notes == null) {
      return;
    }

    int index = _notes!.toList().indexWhere((note) => note.id == event.note.id);
    final newNote = event.note;

    final shouldRemove =
        event.event == "deleted" ||
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
                  showPage(context, NoteEditor());
                },
                child: Text(context.l10n.createYourFirstNote),
              ),
            ],
          ],
        ),
      );
    }

    if (widget.searchMode) {
      return _buildGridView();
    }

    if (AppState.notesViewMode == NoteViewMode.list) {
      final sortedNotes = _sortNotes(_notes!.toList());

      return Padding(
        padding: const EdgeInsets.fromLTRB(_gap, 0, _gap, 24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sortedNotes.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final note = sortedNotes[index];
                return NoteCard(
                  key: ValueKey(note.id),
                  note: note,
                  index: index,
                );
              },
            ),
          ),
        ),
      );
    }

    return _buildGridView();
  }

  Widget _buildGridView() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_gap, 0, _gap, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final crossAxisCount = availableWidth > 900
              ? 4
              : availableWidth > 600
              ? 3
              : 2;

          final sortedNotes = _sortNotes(_notes!.toList());
          final orderKey = sortedNotes.map((n) => n.id).join('-');

          return MasonryGridView.count(
            key: ValueKey(orderKey),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
            itemCount: sortedNotes.length,
            itemBuilder: (context, index) {
              final note = sortedNotes[index];
              return NoteCard(key: ValueKey(note.id), note: note, index: index);
            },
          );
        },
      ),
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
          onTap: () => _openFolder(FolderLocation.label('')),
        ),
      );

      for (final label in _labels!) {
        folders.add(
          FolderTile(
            type: FolderType.label,
            labelName: label.name,
            noteCount: label.notesCount ?? 0,
            onTap: () => _openFolder(FolderLocation.label(label.name)),
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
    AppState.currentFolder = location;

    _notes = null;
    _scrollController.jumpTo(0.0);
    _startLoading();
    _notes = await _fetchNotes();
    _stopLoading();
    if (mounted) {
      setState(() {});
    }
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
