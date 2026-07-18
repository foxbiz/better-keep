import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

class E2EEStatusCard extends StatelessWidget {
  const E2EEStatusCard({
    super.key,
    required this.status,
    required this.approvedDeviceCount,
    required this.hasRecoveryKey,
    required this.onManageRecoveryKey,
    required this.onSetupE2ee,
  });

  final E2EEStatus status;
  final int approvedDeviceCount;
  final bool hasRecoveryKey;
  final VoidCallback onManageRecoveryKey;
  final VoidCallback onSetupE2ee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (statusText, statusColor, statusIcon) = switch (status) {
      E2EEStatus.ready => (
        'Your notes are protected',
        Colors.green,
        Icons.lock,
      ),
      E2EEStatus.pendingApproval => (
        'Waiting for device approval',
        Colors.orange,
        Icons.hourglass_empty,
      ),
      E2EEStatus.notSetUp => (
        'Protection not enabled',
        Colors.grey,
        Icons.lock_open,
      ),
      E2EEStatus.error => (
        'Something went wrong',
        Colors.orange,
        Icons.error_outline,
      ),
      E2EEStatus.revoked => ('Device access removed', Colors.red, Icons.block),
      _ => ('Getting ready...', Colors.grey, Icons.lock_open),
    };

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: statusColor.withValues(alpha: 0.3), width: 1),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          shape: cardShape,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(statusIcon, color: statusColor, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            statusText,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                          if (status == E2EEStatus.ready)
                            Text(
                              'Your notes and attachments are encrypted',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (status == E2EEStatus.ready) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    theme,
                    'Encryption',
                    'XChaCha20-Poly1305',
                    Icons.shield,
                  ),
                  const SizedBox(height: 8),
                  _buildInfoRow(
                    theme,
                    'Key Exchange',
                    'X25519 ECDH',
                    Icons.swap_horiz,
                  ),
                  const SizedBox(height: 8),
                  _buildInfoRow(theme, 'Key Size', '256-bit', Icons.key),
                  const SizedBox(height: 8),
                  _buildInfoRow(
                    theme,
                    'Devices',
                    '$approvedDeviceCount authorized',
                    Icons.devices,
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.vpn_key),
                    title: Row(
                      children: [
                        Text(context.l10n.recoveryKey),
                        if (!hasRecoveryKey) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              context.l10n.important,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(context.l10n.manageRecoveryPassphrase),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onManageRecoveryKey,
                  ),
                ],
                if (status == E2EEStatus.notSetUp) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: onSetupE2ee,
                      icon: const Icon(Icons.lock),
                      label: Text(context.l10n.enableE2EE),
                    ),
                  ),
                ],
                if (status == E2EEStatus.pendingApproval) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.l10n.approveOnOtherDevice,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
  ) {
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
