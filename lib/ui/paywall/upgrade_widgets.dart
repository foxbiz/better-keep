import 'package:better_keep/services/monetization/monetization.dart';
import 'package:flutter/material.dart';

/// A banner widget shown to free users encouraging upgrade.
///
/// Shows contextual information about what's missing.
class UpgradeBanner extends StatelessWidget {
  final GatedFeature? feature;
  final VoidCallback? onUpgrade;
  final bool dismissible;

  const UpgradeBanner({
    super.key,
    this.feature,
    this.onUpgrade,
    this.dismissible = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final planService = PlanService.instance;

    // Only show for free users
    return ValueListenableBuilder<SubscriptionStatus>(
      valueListenable: planService.statusNotifier,
      builder: (context, status, child) {
        if (status.effectivePlan != UserPlan.free) {
          return const SizedBox.shrink();
        }
        return child!;
      },
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.15),
              theme.colorScheme.secondary.withValues(alpha: 0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.workspace_premium_rounded,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getTitle(),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _getSubtitle(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onUpgrade,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Upgrade'),
            ),
          ],
        ),
      ),
    );
  }

  String _getTitle() {
    if (feature != null) {
      return 'Unlock ${EntitlementGuard.getFeatureDescription(feature!)}';
    }
    return 'Upgrade to Pro';
  }

  String _getSubtitle() {
    if (feature != null) {
      switch (feature!) {
        case GatedFeature.lockNote:
          return 'Protect unlimited notes with PIN locks';
        case GatedFeature.realtimeCloudSync:
          return 'Sync across all your devices securely';
      }
    }
    return 'Unlimited locked notes and real-time cloud sync';
  }
}

/// A small inline upgrade chip/button.
class UpgradeChip extends StatelessWidget {
  final VoidCallback? onTap;

  const UpgradeChip({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.workspace_premium_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Text(
              'Pro',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Badge to indicate a feature is Pro-only.
class ProBadge extends StatelessWidget {
  final bool small;

  const ProBadge({super.key, this.small = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 6 : 8,
        vertical: small ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'PRO',
        style: TextStyle(
          color: theme.colorScheme.onPrimary,
          fontSize: small ? 9 : 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// A list tile with a Pro badge if feature is gated.
class FeatureListTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final GatedFeature? gatedFeature;
  final bool enabled;

  const FeatureListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.gatedFeature,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAvailable =
        gatedFeature == null ||
        EntitlementGuard.isFeatureAvailable(gatedFeature!);
    final isEnabled = enabled && isAvailable;

    return ListTile(
      leading: leading != null
          ? Icon(leading, color: isEnabled ? null : theme.colorScheme.outline)
          : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: TextStyle(
                color: isEnabled ? null : theme.colorScheme.outline,
              ),
            ),
          ),
          if (!isAvailable) ...[
            const SizedBox(width: 8),
            const ProBadge(small: true),
          ],
        ],
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(
                color: isEnabled
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.outline,
              ),
            )
          : null,
      trailing: trailing,
      enabled: isEnabled,
      onTap: isAvailable ? onTap : () => _showUpgradePrompt(context),
    );
  }

  void _showUpgradePrompt(BuildContext context) {
    // Import and use showPaywall
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${gatedFeature != null ? EntitlementGuard.getFeatureDescription(gatedFeature!) : 'This feature'} requires Pro',
        ),
        action: SnackBarAction(
          label: 'Upgrade',
          onPressed: () {
            // Show paywall - caller should handle this
          },
        ),
      ),
    );
  }
}
