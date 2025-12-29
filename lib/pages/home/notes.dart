import 'dart:async';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/labels.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

class Notes extends StatefulWidget {
  final String? searchQuery;
  final bool searchMode;
  const Notes({super.key, this.searchQuery, this.searchMode = false});

  @override
  State<Notes> createState() => _NotesState();
}

class _NotesState extends State<Notes> {
  static const _gap = 8.0;

  late bool _selectionMode;
  final ScrollController _scrollController = ScrollController();

  Iterable<Note>? _notes;
  double _pendingOffset = 0.0;
  bool _showLoader = false;
  Timer? _updateShowLoaderTimeout;

  @override
  void initState() {
    _fetchNotes();

    _selectionMode = AppState.selectedNotes.isNotEmpty;
    _scrollController.addListener(() {
      _pendingOffset = _scrollController.offset;
    });

    Note.on("changed", _notesListener);
    AppState.subscribe("show_notes", _showNotesListener);
    AppState.subscribe("selected_notes", _selectedNotesListener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_pendingOffset);
    });

    super.initState();
  }

  @override
  void didUpdateWidget(Notes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery ||
        oldWidget.searchMode != widget.searchMode) {
      _fetchNotes();
    }
  }

  Future<void> _fetchNotes() async {
    _startLoading();
    final fetchedNotes = await Note.get(
      AppState.showNotes,
      AppState.filterLabels,
      widget.searchQuery,
    );
    _stopLoading();
    if (mounted) {
      setState(() {
        _notes = fetchedNotes;
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    Note.off("changed", _notesListener);
    AppState.unsubscribe("show_notes", _showNotesListener);
    AppState.unsubscribe("selected_notes", _selectedNotesListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return RefreshIndicator(
          onRefresh: () async {
            await NoteSyncService().refresh();
            await _fetchNotes();
          },
          child: SingleChildScrollView(
            key: PageStorageKey('notes_scroll_view'),
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: 0, bottom: 0),
            scrollDirection: Axis.vertical,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 1200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (AppState.showNotes == NoteType.all) _buildLabelList(),
                      _buildNotesView(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Returns appropriate icon and message for empty state based on current view
  (IconData, String) _getEmptyStateContent() {
    if (widget.searchMode) {
      return (Icons.search_off, 'No matching notes');
    }
    return switch (AppState.showNotes) {
      NoteType.all => (Icons.note_outlined, 'No notes yet'),
      NoteType.archived => (Icons.archive_outlined, 'No archived notes'),
      NoteType.trashed => (Icons.delete_outline, 'Trash is empty'),
      NoteType.pinned => (Icons.push_pin_outlined, 'No pinned notes'),
      NoteType.locked => (Icons.lock_outline, 'No locked notes'),
      NoteType.reminder => (Icons.notifications_none, 'No reminders set'),
    };
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

  void _showNotesListener(dynamic payload) async {
    setState(() {
      _notes = null;
      _pendingOffset = 0.0;
    });

    _fetchNotes();
  }

  void _selectedNotesListener(dynamic payload) {
    final selectedNotes = payload as List<Note>;
    setState(() {
      _selectionMode = selectedNotes.isNotEmpty;
    });
  }

  /// Sorts notes with pinned notes first, then by updated_at, then by created_at
  List<Note> _sortNotes(List<Note> notes) {
    final sorted = [...notes];
    sorted.sort((a, b) {
      // 1. Pinned first
      if (a.pinned != b.pinned) return b.pinned ? 1 : -1;

      // 2. Updated at (newer first)
      final updatedA = a.updatedAt ?? DateTime(1970);
      final updatedB = b.updatedAt ?? DateTime(1970);
      final updatedCmp = updatedB.compareTo(updatedA);
      if (updatedCmp != 0) return updatedCmp;

      // 3. Created at (newer first)
      final createdA = a.createdAt ?? DateTime(1970);
      final createdB = b.createdAt ?? DateTime(1970);
      return createdB.compareTo(createdA);
    });
    return sorted;
  }

  void _notesListener(NoteEvent event) {
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      _fetchNotes();
      return;
    }

    if (AppState.selectedNotes.isNotEmpty) {
      AppState.selectedNotes = [];
    }

    // If notes haven't loaded yet, we can't update the list.
    // We'll just let _fetchNotes handle it when it completes.
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
                // Only remove if completed AND not a repeating reminder
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
        // Insert new note at appropriate position based on pinned status
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

  Widget _buildLabelList() {
    if (!_selectionMode && !widget.searchMode) {
      return Labels(
        key: Key('labels_widget'),
        onSelect: (selectedLabel) async {
          setState(() {
            _notes = null;
            _pendingOffset = 0.0;
          });
          _startLoading();
          final notes = await Note.get(
            AppState.showNotes,
            selectedLabel.map((e) => e.name).toList(),
          );
          _stopLoading();
          if (context.mounted) {
            setState(() {
              _notes = notes;
            });
          }
        },
      );
    }

    return SizedBox.shrink();
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
                child: const Text('Create your first note'),
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _gap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Use actual available width instead of screen width
          // to properly account for sidebar on big screens
          final availableWidth = constraints.maxWidth;
          final crossAxisCount = availableWidth > 900
              ? 4
              : availableWidth > 600
              ? 3
              : 2;

          // Sort notes with proper priority order
          // (pinned first, then by updatedAt, then createdAt)
          final sortedNotes = _sortNotes(_notes!.toList());

          // Create a key based on note order to force layout refresh when order changes
          final orderKey = sortedNotes.map((n) => n.id).join('-');

          // MasonryGridView places items in shortest column first
          // First/most important notes appear at top-left area
          // Cards maintain their natural height (no stretching)
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
}
