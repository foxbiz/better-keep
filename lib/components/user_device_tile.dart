import 'package:flutter/material.dart';

/// A device row used by the user page's authorized and pending device lists.
class UserDeviceTile extends StatelessWidget {
  const UserDeviceTile({
    required this.name,
    required this.subtitle,
    required this.platformIcon,
    required this.isPending,
    required this.isCurrentDevice,
    required this.currentDeviceLabel,
    this.trailing,
    super.key,
  });

  final String name;
  final String subtitle;
  final IconData platformIcon;
  final bool isPending;
  final bool isCurrentDevice;
  final String currentDeviceLabel;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: isCurrentDevice
            ? Border.all(color: theme.colorScheme.primary, width: 1)
            : null,
      ),
      child: Row(
        children: [
          Icon(
            platformIcon,
            size: 24,
            color: isPending ? Colors.orange : theme.colorScheme.onSurface,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Tooltip(
                        message: name,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (isCurrentDevice) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          currentDeviceLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
