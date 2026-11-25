import 'package:flutter/material.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/utils/l10n_helper.dart';

class UserDevicesSection extends StatelessWidget {
  const UserDevicesSection({
    required this.devices,
    required this.showAll,
    required this.isMainDevice,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onShowAll,
    required this.loadingBuilder,
    required this.tileBuilder,
    super.key,
  });

  final List<DeviceDocument> devices;
  final bool showAll, isMainDevice, loading;
  final String? error;
  final VoidCallback onRefresh, onShowAll;
  final WidgetBuilder loadingBuilder;
  final Widget Function(BuildContext, DeviceDocument, bool) tileBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final pendingDevices = isMainDevice
        ? devices.where((d) => d.canApproveAt(now)).toList()
        : <DeviceDocument>[];
    final approvedDevices = devices.where((d) => d.isApproved).toList();
    final totalDevices = pendingDevices.length + approvedDevices.length;
    final visiblePending = showAll
        ? pendingDevices
        : pendingDevices.take(3).toList();
    final visibleApproved = showAll
        ? approvedDevices
        : approvedDevices.take(3 - visiblePending.length).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: showAll ? EdgeInsets.zero : const EdgeInsets.all(16),
        decoration: showAll
            ? null
            : BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!showAll)
              Row(
                children: [
                  const Icon(Icons.devices, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    context.l10n.yourDevices,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (loading)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
            if (!showAll) const SizedBox(height: 16),

            // Show error message if there's an error
            if (error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_off,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: onRefresh,
                      child: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
            ]
            // Show skeleton loader while loading
            else if (loading && devices.isEmpty) ...[
              loadingBuilder(context),
            ]
            // Show devices
            else ...[
              if (showAll &&
                  !isMainDevice &&
                  !loading &&
                  approvedDevices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.deviceRemovalMainDeviceOnly,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              // Pending devices (show approval buttons) - only on primary device
              if (visiblePending.isNotEmpty) ...[
                Text(
                  context.l10n.pendingApprovalSection,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                ...visiblePending.map(
                  (device) => tileBuilder(context, device, true),
                ),
                const SizedBox(height: 16),
              ],

              // Approved devices
              if (visibleApproved.isNotEmpty) ...[
                Text(
                  context.l10n.authorizedDevices,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < visibleApproved.length; i++) ...[
                  if (showAll && i > 0) const Divider(height: 1),
                  tileBuilder(context, visibleApproved[i], false),
                ],
              ],
              if (!showAll && totalDevices > 3)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: onShowAll,
                    child: Text(context.l10n.showMoreDevices(totalDevices - 3)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
