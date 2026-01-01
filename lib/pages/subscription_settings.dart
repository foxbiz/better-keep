import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:flutter/material.dart';

/// Settings page section for subscription management.
class SubscriptionSettingsSection extends StatelessWidget {
  const SubscriptionSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SubscriptionStatus>(
      valueListenable: PlanService.instance.statusNotifier,
      builder: (context, status, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, status),
            const SizedBox(height: 8),
            if (status.effectivePlan == UserPlan.free)
              _buildUpgradeCard(context)
            else
              _buildSubscriptionDetails(context, status),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, SubscriptionStatus status) {
    final theme = Theme.of(context);
    final plan = status.effectivePlan;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            plan == UserPlan.free
                ? Icons.person_outline
                : Icons.workspace_premium,
            color: plan == UserPlan.free
                ? theme.colorScheme.outline
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Subscription',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${plan.displayName} Plan',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _buildPlanBadge(context, plan),
        ],
      ),
    );
  }

  Widget _buildPlanBadge(BuildContext context, UserPlan plan) {
    final theme = Theme.of(context);

    Color backgroundColor;
    Color textColor;

    switch (plan) {
      case UserPlan.free:
        backgroundColor = theme.colorScheme.surfaceContainerHighest;
        textColor = theme.colorScheme.onSurfaceVariant;
        break;
      case UserPlan.pro:
        backgroundColor = theme.colorScheme.primary;
        textColor = theme.colorScheme.onPrimary;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        plan.displayName.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: textColor,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildUpgradeCard(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () => showPaywall(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.rocket_launch,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upgrade to Pro',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Cloud sync, unlimited locked notes, and more',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionDetails(
    BuildContext context,
    SubscriptionStatus status,
  ) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Plan details
            if (status.plan == UserPlan.pro) ...[
              _DetailRow(
                label: 'Billing',
                value: status.billingPeriod?.displayName ?? 'N/A',
              ),
              if (status.expiresAt != null) ...[
                const SizedBox(height: 8),
                _DetailRow(
                  label: status.willAutoRenew ? 'Renews' : 'Expires',
                  value: _formatDate(status.expiresAt!),
                  valueColor: status.isExpiringSoon
                      ? theme.colorScheme.error
                      : null,
                ),
              ],
              if (status.isExpiringSoon) ...[
                const SizedBox(height: 12),
                Container(
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
                        Icons.warning_amber,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your subscription expires in ${status.daysUntilExpiration} days',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _manageSubscription(context),
                    child: const Text('Manage'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _cancelSubscription(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      side: BorderSide(color: theme.colorScheme.error),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _manageSubscription(BuildContext context) async {
    final result = await SubscriptionService.instance.cancelSubscription();

    if (!context.mounted) return;

    if (result.isPending) {
      // Successfully opened subscription management
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } else if (!result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _cancelSubscription(BuildContext context) async {
    final theme = Theme.of(context);

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Subscription?'),
        content: const Text(
          'Your subscription will remain active until the end of the current billing period. '
          'After that, you\'ll lose access to Pro features.\n\n'
          'You can resubscribe at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep Subscription'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Cancel Subscription'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final result = await SubscriptionService.instance.cancelSubscription();

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.isSuccess || result.isPending
            ? null
            : Colors.red,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

/// Usage stats widget showing entitlement consumption.
class UsageStatsWidget extends StatelessWidget {
  final int lockedNotesCount;

  const UsageStatsWidget({super.key, required this.lockedNotesCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entitlements = PlanService.instance.entitlements;

    if (entitlements.maxLockedNotes == -1) {
      // Unlimited - don't show usage
      return const SizedBox.shrink();
    }

    final usagePercent = lockedNotesCount / entitlements.maxLockedNotes;
    final isNearLimit = usagePercent >= 0.8;
    final isAtLimit = lockedNotesCount >= entitlements.maxLockedNotes;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Locked Notes', style: theme.textTheme.titleSmall),
                Text(
                  '$lockedNotesCount / ${entitlements.maxLockedNotes}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isAtLimit
                        ? theme.colorScheme.error
                        : isNearLimit
                        ? Colors.orange
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: usagePercent.clamp(0.0, 1.0),
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: isAtLimit
                    ? theme.colorScheme.error
                    : isNearLimit
                    ? Colors.orange
                    : theme.colorScheme.primary,
              ),
            ),
            if (isNearLimit && !isAtLimit) ...[
              const SizedBox(height: 8),
              Text(
                'You\'re running low on locked notes',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
              ),
            ],
            if (isAtLimit) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Upgrade to unlock unlimited locked notes',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        showPaywall(context, feature: GatedFeature.lockNote),
                    child: const Text('Upgrade'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
