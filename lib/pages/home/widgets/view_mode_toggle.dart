import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';

/// A widget that shows the current view mode icon and allows changing it
class ViewModeToggle extends StatefulWidget {
  const ViewModeToggle({super.key});

  @override
  State<ViewModeToggle> createState() => _ViewModeToggleState();
}

class _ViewModeToggleState extends State<ViewModeToggle> {
  late NoteViewMode _viewMode;

  @override
  void initState() {
    super.initState();
    _viewMode = AppState.notesViewMode;
    AppState.subscribe("notes_view_mode", _onViewModeChanged);
  }

  @override
  void dispose() {
    AppState.unsubscribe("notes_view_mode", _onViewModeChanged);
    super.dispose();
  }

  void _onViewModeChanged(dynamic value) {
    if (!mounted) return;
    if (value is! NoteViewMode) return;
    setState(() {
      _viewMode = value;
    });
  }

  IconData _getIcon(NoteViewMode mode) {
    switch (mode) {
      case NoteViewMode.grid:
        return Icons.grid_view;
      case NoteViewMode.list:
        return Icons.list;
      case NoteViewMode.folder:
        return Icons.folder;
    }
  }

  void _showViewModeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select View Mode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildViewModeOption(NoteViewMode.grid, Icons.grid_view, 'Grid'),
            const Divider(),
            _buildViewModeOption(NoteViewMode.list, Icons.list, 'List'),
            const Divider(),
            _buildViewModeOption(NoteViewMode.folder, Icons.folder, 'Folder'),
          ],
        ),
      ),
    );
  }

  Widget _buildViewModeOption(NoteViewMode mode, IconData icon, String label) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: _viewMode == mode
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () {
        AppState.notesViewMode = mode;
        Navigator.pop(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showViewModeDialog,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _getIcon(_viewMode),
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
