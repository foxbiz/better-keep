import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';

/// Button to toggle between scroll and grid toolbar layout modes.
/// Only shows if [showToggle] is true (i.e., content doesn't fit in one row).
///
/// Note: This widget reads [AppState.toolbarGridMode] directly and relies on
/// the parent widget rebuilding when the state changes (via AppState subscription).
/// Do not cache or reuse this widget without ensuring the parent subscribes to
/// the "toolbar_grid_mode" state key.
class ToolbarLayoutToggleButton extends StatelessWidget {
  final bool showToggle;

  const ToolbarLayoutToggleButton({super.key, this.showToggle = true});

  @override
  Widget build(BuildContext context) {
    if (!showToggle) {
      return const SizedBox.shrink();
    }

    return IconButton(
      icon: Icon(
        AppState.toolbarGridMode
            ? Icons.keyboard_arrow_down
            : Icons.keyboard_arrow_up,
      ),
      tooltip: AppState.toolbarGridMode ? 'Collapse toolbar' : 'Expand toolbar',
      onPressed: () {
        AppState.toolbarGridMode = !AppState.toolbarGridMode;
      },
    );
  }
}
