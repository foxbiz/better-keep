import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

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
      case NoteViewMode.folderLabels:
        return Icons.label;
      case NoteViewMode.folderColors:
        return Icons.color_lens;
    }
  }

  void _showViewModeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.selectView),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildViewModeOption(
              NoteViewMode.grid,
              Icons.grid_view,
              context.l10n.viewModeGrid,
            ),
            const Divider(),
            _buildViewModeOption(
              NoteViewMode.list,
              Icons.list,
              context.l10n.viewModeList,
            ),
            const Divider(),
            _buildViewModeOption(
              NoteViewMode.folderLabels,
              Icons.label,
              context.l10n.labels,
            ),
            const Divider(),
            _buildViewModeOption(
              NoteViewMode.folderColors,
              Icons.color_lens,
              context.l10n.viewModeColors,
            ),
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
