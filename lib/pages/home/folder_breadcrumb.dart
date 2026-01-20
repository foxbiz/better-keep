import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';

class FolderLocation {
  final bool isPinned;
  final String? labelName;
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

  factory FolderLocation.fromString(String str) {
    if (str == 'pinned') {
      return FolderLocation.pinned();
    } else if (str.startsWith('label:')) {
      return FolderLocation.label(str.substring(6));
    } else if (str.startsWith('color:')) {
      late final Color color;

      try {
        final colorValue = int.tryParse(str.substring(6));
        if (colorValue != null) {
          color = Color(colorValue);
        } else {
          color = Colors.transparent;
        }
      } catch (e) {
        color = Colors.transparent;
      }

      return FolderLocation.color(color);
    }
    throw ArgumentError('Invalid folder location string: $str');
  }

  String toStorageString() {
    if (isPinned) {
      return 'pinned';
    } else if (labelName != null) {
      return 'label:$labelName';
    } else if (color != null) {
      return 'color:${color!.toARGB32()}';
    }
    throw StateError('Invalid folder location state');
  }
}

class FolderBreadcrumb extends StatelessWidget {
  final FolderLocation? location;

  const FolderBreadcrumb({super.key, this.location});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(
            Icons.chevron_right,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        InkWell(
          onTap: () {
            AppState.currentFolder = null;
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Icon(
              Icons.home_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        if (location != null) ...[
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
      ],
    );
  }

  Widget _buildCurrentFolder(ThemeData theme) {
    if (location == null) {
      return const SizedBox.shrink();
    }

    if (location!.isPinned) {
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

    if (location!.labelName != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            location!.labelName!.isEmpty ? Icons.label_off : Icons.label,
            size: 18,
            color: theme.colorScheme.onSurface,
          ),
          const SizedBox(width: 4),
          Text(
            location!.labelName!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (location!.color != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: location!.color == Colors.transparent
                  ? theme.colorScheme.surfaceContainerHighest
                  : location!.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: location!.color == Colors.transparent
                ? Icon(
                    Icons.format_color_reset,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
