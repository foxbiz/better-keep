import 'package:flutter/material.dart';

/// Represents the current folder location for breadcrumb navigation.
class FolderLocation {
  /// Whether this is the pinned folder
  final bool isPinned;

  /// Label name (for label folders)
  final String? labelName;

  /// Color value (for color folders)
  final Color? color;

  const FolderLocation.pinned()
    : isPinned = true,
      labelName = null,
      color = null;

  const FolderLocation.label(String name)
    : isPinned = false,
      labelName = name,
      color = null;

  const FolderLocation.color(Color c)
    : isPinned = false,
      labelName = null,
      color = c;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderLocation &&
          runtimeType == other.runtimeType &&
          isPinned == other.isPinned &&
          labelName == other.labelName &&
          color == other.color;

  @override
  int get hashCode => Object.hash(isPinned, labelName, color);
}

/// Breadcrumb navigation widget for folder view.
/// Shows "Home" > "Current Folder" with tap navigation.
class FolderBreadcrumb extends StatelessWidget {
  /// Current folder location
  final FolderLocation location;

  /// Callback when "Home" is tapped
  final VoidCallback onHomePressed;

  const FolderBreadcrumb({
    super.key,
    required this.location,
    required this.onHomePressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Home button
          InkWell(
            onTap: onHomePressed,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.home_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Folders',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Separator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // Current folder indicator
          _buildCurrentFolder(theme),
        ],
      ),
    );
  }

  Widget _buildCurrentFolder(ThemeData theme) {
    if (location.isPinned) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.push_pin, size: 18, color: theme.colorScheme.onSurface),
          const SizedBox(width: 4),
          Text(
            'Pinned',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (location.labelName != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.label_outline,
            size: 18,
            color: theme.colorScheme.onSurface,
          ),
          const SizedBox(width: 4),
          Text(
            location.labelName!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (location.color != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: location.color == Colors.transparent
                  ? theme.colorScheme.surfaceContainerHighest
                  : location.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: location.color == Colors.transparent
                ? Icon(
                    Icons.format_color_reset,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Text(
            'Color',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
