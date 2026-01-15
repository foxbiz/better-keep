import 'package:better_keep/components/folder_breadcrumb.dart';
import 'package:better_keep/components/folder_tile.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/note_grouping.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Grouping mode for folder view
enum FolderGroupBy { labels, colors }

/// Folder view mode for notes.
/// Groups notes by labels or colors and displays them as folders.
class FolderView extends StatefulWidget {
  /// The notes to display (will be converted to list internally)
  final Iterable<Note> notes;

  /// Whether we're in selection mode
  final bool selectionMode;

  /// Whether the view is in search mode
  final bool searchMode;

  /// Callback when folder navigation changes (for back gesture handling)
  final ValueChanged<bool>? onInsideFolder;

  const FolderView({
    super.key,
    required this.notes,
    this.selectionMode = false,
    this.searchMode = false,
    this.onInsideFolder,
  });

  @override
  State<FolderView> createState() => FolderViewState();
}

class FolderViewState extends State<FolderView> {
  static const _gap = 8.0;

  /// Current folder location (null = at root/folder list)
  FolderLocation? _currentFolder;

  /// Current grouping mode
  late FolderGroupBy _groupBy;

  /// Flag to prevent double navigation when folder becomes empty
  bool _pendingEmptyFolderNavigation = false;

  /// Get note groups for the current notes
  NoteGroups _getGroups() {
    return createNoteGroups(widget.notes.toList());
  }

  @override
  void initState() {
    super.initState();
    _groupBy = _loadGroupBy();
    AppState.subscribe("folder_group_by", _onGroupByChanged);
  }

  @override
  void dispose() {
    AppState.unsubscribe("folder_group_by", _onGroupByChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(FolderView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Check if current folder is still valid after notes change
    if (_currentFolder != null && !_pendingEmptyFolderNavigation) {
      final groups = _getGroups();
      final notesInFolder = _getNotesForFolder(groups, _currentFolder!);
      if (notesInFolder.isEmpty) {
        // Folder is now empty, navigate back to root
        _pendingEmptyFolderNavigation = true;
        final folderToCheck = _currentFolder;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _pendingEmptyFolderNavigation = false;
          // Re-verify folder is still empty (notes may have been added)
          if (_currentFolder != folderToCheck) return;
          final currentGroups = _getGroups();
          final currentNotes = _getNotesForFolder(
            currentGroups,
            _currentFolder!,
          );
          if (currentNotes.isEmpty) {
            snackbar('Folder is now empty');
            _navigateToRoot();
          }
        });
      }
    }
  }

  FolderGroupBy _loadGroupBy() {
    final stored = AppState.folderGroupBy;
    return stored == 'colors' ? FolderGroupBy.colors : FolderGroupBy.labels;
  }

  void _onGroupByChanged(dynamic value) {
    if (!mounted) return;
    setState(() {
      _groupBy = value == 'colors'
          ? FolderGroupBy.colors
          : FolderGroupBy.labels;
      _currentFolder = null; // Reset to root when grouping changes
    });
    widget.onInsideFolder?.call(false);
  }

  void _setGroupBy(FolderGroupBy groupBy) {
    setState(() {
      _groupBy = groupBy;
      _currentFolder = null;
    });
    AppState.folderGroupBy = groupBy == FolderGroupBy.colors
        ? 'colors'
        : 'labels';
    widget.onInsideFolder?.call(false);
  }

  void _openFolder(FolderLocation location) {
    setState(() {
      _currentFolder = location;
    });
    widget.onInsideFolder?.call(true);
  }

  void _navigateToRoot() {
    setState(() {
      _currentFolder = null;
    });
    widget.onInsideFolder?.call(false);
  }

  /// Handle back navigation - returns true if handled (was inside folder)
  bool handleBack() {
    if (_currentFolder != null) {
      _navigateToRoot();
      return true;
    }
    return false;
  }

  /// Reset folder state (e.g., when note type changes)
  void resetFolder() {
    if (_currentFolder != null) {
      setState(() {
        _currentFolder = null;
      });
      widget.onInsideFolder?.call(false);
    }
  }

  /// Whether we're currently inside a folder
  bool get isInsideFolder => _currentFolder != null;

  List<Note> _getNotesForFolder(NoteGroups groups, FolderLocation location) {
    if (location.isPinned) {
      return groups.pinnedNotes;
    }

    if (location.labelName != null) {
      return groups.byLabel[location.labelName] ?? [];
    }

    if (location.color != null) {
      return groups.byColor[location.color] ?? [];
    }

    return [];
  }

  @override
  Widget build(BuildContext context) {
    final groups = _getGroups();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Show breadcrumb when inside a folder, toggle when at root
        if (_currentFolder != null)
          FolderBreadcrumb(
            location: _currentFolder!,
            onHomePressed: _navigateToRoot,
          )
        else if (!widget.selectionMode && !widget.searchMode)
          _buildGroupToggle(),

        // Content area
        Expanded(
          child: _currentFolder != null
              ? _buildNotesGrid(_getNotesForFolder(groups, _currentFolder!))
              : _buildFoldersGrid(groups),
        ),
      ],
    );
  }

  Widget _buildGroupToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          SegmentedButton<FolderGroupBy>(
            segments: const [
              ButtonSegment(
                value: FolderGroupBy.labels,
                label: Text('Labels'),
                icon: Icon(Icons.label_outline),
              ),
              ButtonSegment(
                value: FolderGroupBy.colors,
                label: Text('Colors'),
                icon: Icon(Icons.palette_outlined),
              ),
            ],
            selected: {_groupBy},
            onSelectionChanged: (selected) => _setGroupBy(selected.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFoldersGrid(NoteGroups groups) {
    final folders = <Widget>[];

    // Special folders first
    // 1. Pinned folder (always shown)
    folders.add(
      FolderTile(
        type: FolderType.pinned,
        noteCount: groups.pinnedNotes.length,
        onTap: () => _openFolder(const FolderLocation.pinned()),
      ),
    );

    // Add folders based on grouping mode
    if (_groupBy == FolderGroupBy.labels) {
      // 2. Unlabeled folder first (if exists)
      if (groups.byLabel.containsKey('Unlabeled')) {
        final notes = groups.byLabel['Unlabeled'] ?? [];
        folders.add(
          FolderTile(
            type: FolderType.unlabeled,
            noteCount: notes.length,
            onTap: () => _openFolder(FolderLocation.label('Unlabeled')),
          ),
        );
      }

      // 3. Regular label folders (alphabetically sorted)
      final labels = groups.byLabel.keys.where((l) => l != 'Unlabeled').toList()
        ..sort((a, b) => a.compareTo(b));

      for (final label in labels) {
        final notes = groups.byLabel[label] ?? [];
        folders.add(
          FolderTile(
            type: FolderType.label,
            labelName: label,
            noteCount: notes.length,
            onTap: () => _openFolder(FolderLocation.label(label)),
          ),
        );
      }
    } else {
      // 2. No Color folder first (if exists)
      if (groups.byColor.containsKey(Colors.transparent)) {
        final notes = groups.byColor[Colors.transparent] ?? [];
        folders.add(
          FolderTile(
            type: FolderType.noColor,
            noteCount: notes.length,
            onTap: () => _openFolder(FolderLocation.color(Colors.transparent)),
          ),
        );
      }

      // 3. Color folders (sorted by color value)
      final colors =
          groups.byColor.keys.where((c) => c != Colors.transparent).toList()
            ..sort((a, b) => a.toARGB32().compareTo(b.toARGB32()));

      for (final color in colors) {
        final notes = groups.byColor[color] ?? [];
        folders.add(
          FolderTile(
            type: FolderType.color,
            color: color,
            noteCount: notes.length,
            onTap: () => _openFolder(FolderLocation.color(color)),
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

  Widget _buildNotesGrid(List<Note> notes) {
    if (notes.isEmpty) {
      return _buildEmptyFolderState();
    }

    // Sort notes with pinned first (for non-pinned folders), then by date
    final sortedNotes = [...notes]
      ..sort((a, b) {
        if (!_currentFolder!.isPinned) {
          if (a.pinned != b.pinned) return b.pinned ? 1 : -1;
        }
        final updatedA = a.updatedAt ?? DateTime(1970);
        final updatedB = b.updatedAt ?? DateTime(1970);
        return updatedB.compareTo(updatedA);
      });

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _gap),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final crossAxisCount = availableWidth > 900
              ? 4
              : availableWidth > 600
              ? 3
              : 2;

          return MasonryGridView.count(
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_open_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            _groupBy == FolderGroupBy.labels
                ? 'No labels yet'
                : 'No colored notes yet',
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            _groupBy == FolderGroupBy.labels
                ? 'Add labels to your notes to organize them into folders'
                : 'Add colors to your notes to organize them into folders',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyFolderState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.note_outlined, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'This folder is empty',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
