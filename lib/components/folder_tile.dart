import 'package:flutter/material.dart';
import 'package:better_keep/utils/utils.dart';

/// Folder display type
enum FolderType {
  /// Folder for a label group
  label,

  /// Folder for a color group
  color,

  /// Special folder for pinned notes
  pinned,

  /// Special folder for unlabeled notes
  unlabeled,

  /// Special folder for notes with no color
  noColor,
}

/// A tile representing a folder of notes.
/// Displays a large folder icon with text/icon inside.
class FolderTile extends StatelessWidget {
  /// The folder display type
  final FolderType type;

  /// Label name (for label type folders)
  final String? labelName;

  /// Folder color (for color type folders, or folder tint)
  final Color? color;

  /// Number of notes in this folder
  final int noteCount;

  /// Callback when folder is tapped
  final VoidCallback? onTap;

  const FolderTile({
    super.key,
    required this.type,
    this.labelName,
    this.color,
    required this.noteCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folderColor = _getFolderColor(theme);
    final foregroundColor = isDark(folderColor) ? Colors.white : Colors.black;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: _buildFolderWithContent(theme, folderColor, foregroundColor),
      ),
    );
  }

  Color _getFolderColor(ThemeData theme) {
    switch (type) {
      case FolderType.pinned:
        return theme.colorScheme.primary;
      case FolderType.unlabeled:
      case FolderType.noColor:
        return theme.colorScheme.surfaceContainerHighest;
      case FolderType.color:
        if (color != null && color != Colors.transparent) {
          return color!;
        }
        return theme.colorScheme.surfaceContainerHighest;
      case FolderType.label:
        return theme.colorScheme.primaryContainer;
    }
  }

  Widget _buildFolderWithContent(
    ThemeData theme,
    Color folderColor,
    Color foregroundColor,
  ) {
    return AspectRatio(
      aspectRatio: 1.1,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Large folder icon that fills the space
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.contain,
              child: Icon(Icons.folder_rounded, size: 100, color: folderColor),
            ),
          ),
          // Content inside folder (centered)
          Positioned(
            top: 20,
            left: 8,
            right: 8,
            bottom: 8,
            child: _buildInsideContent(theme, foregroundColor),
          ),
        ],
      ),
    );
  }

  Widget _buildInsideContent(ThemeData theme, Color foregroundColor) {
    switch (type) {
      case FolderType.pinned:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.push_pin,
              size: 22,
              color: foregroundColor.withValues(alpha: 0.9),
            ),
            Text(
              '$noteCount',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foregroundColor.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      case FolderType.unlabeled:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Unlabeled',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foregroundColor.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
              textAlign: TextAlign.center,
            ),
            Text(
              '$noteCount',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foregroundColor.withValues(alpha: 0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        );
      case FolderType.noColor:
        // No Color folder just shows the count (like color folders)
        return Center(
          child: Text(
            '$noteCount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: foregroundColor.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      case FolderType.label:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelName ?? '',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foregroundColor.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            Text(
              '$noteCount',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foregroundColor.withValues(alpha: 0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        );
      case FolderType.color:
        // Color folders just show the count centered
        return Center(
          child: Text(
            '$noteCount',
            style: theme.textTheme.labelMedium?.copyWith(
              color: foregroundColor.withValues(alpha: 0.9),
              fontWeight: FontWeight.w600,
            ),
          ),
        );
    }
  }
}
