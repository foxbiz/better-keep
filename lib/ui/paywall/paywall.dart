/// Paywall and upgrade UI components for Better Keep Notes.
///
/// Usage:
/// ```dart
/// import 'package:better_keep/ui/paywall/paywall.dart';
///
/// // Show the paywall modal
/// await showPaywall(context, feature: GatedFeature.realtimeCloudSync);
///
/// // Show a quick upgrade snackbar
/// showUpgradePrompt(context, message: 'Cloud sync requires Pro');
///
/// // Use upgrade widgets
/// UpgradeBanner(onUpgrade: () => showPaywall(context));
/// ProBadge();
/// UpgradeChip(onTap: () => showPaywall(context));
/// ```
library;

export 'paywall_sheet.dart';
export 'upgrade_widgets.dart';
