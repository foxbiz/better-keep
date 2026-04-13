import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Map a [PurchaseResult] message to a localized string.
/// Falls back to the raw service message if no match is found.
String _localizedPurchaseMessage(BuildContext context, PurchaseResult result) {
  final msg = result.message;
  if (msg.contains('restored')) return context.l10n.subscriptionRestored;
  if (msg.contains('already have')) {
    return context.l10n.subscriptionAlreadyActive;
  }
  if (msg.contains('activated')) return context.l10n.subscriptionActivated;
  if (msg.contains('cancelled') || msg.contains('canceled')) {
    return context.l10n.purchaseCancelled;
  }
  if (msg.contains('Payment failed') || msg.contains('payment failed')) {
    return context.l10n.paymentFailed;
  }
  if (result.isFailed) return context.l10n.somethingWentWrongTryAgain;
  return msg;
}

/// Shows the paywall as a full-screen page.
///
/// Returns true if the user upgraded, false otherwise.
Future<bool> showPaywall(
  BuildContext context, {
  GatedFeature? feature,
  String? customMessage,
}) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (context) =>
          PaywallPage(feature: feature, customMessage: customMessage),
    ),
  );
  return result ?? false;
}

/// Shows the paywall as a bottom sheet (for quick prompts).
Future<bool> showPaywallSheet(
  BuildContext context, {
  GatedFeature? feature,
  String? customMessage,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) =>
        PaywallSheet(feature: feature, customMessage: customMessage),
  );
  return result ?? false;
}

/// Shows a quick upgrade prompt as a snackbar with action.
void showUpgradePrompt(
  BuildContext context, {
  required String message,
  GatedFeature? feature,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'Upgrade',
        onPressed: () => showPaywall(context, feature: feature),
      ),
    ),
  );
}

/// The main paywall bottom sheet.
class PaywallSheet extends StatelessWidget {
  final GatedFeature? feature;
  final String? customMessage;

  const PaywallSheet({super.key, this.feature, this.customMessage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Compact hero: icon inline with title
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.workspace_premium_rounded,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.upgradeToPro,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Feature-specific or custom message
              Text(
                _getMessage(context),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // Feature comparison
              const _FeatureComparisonCard(),
              const SizedBox(height: 8),
              Text(
                context.l10n.noAdsDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // Pricing options
              const _PricingOptions(),
              const SizedBox(height: 16),

              // Restore info
              const _RestoreInfoText(),
              const SizedBox(height: 16),

              // Terms and Privacy links
              const _LegalLinks(),
              const SizedBox(height: 16),

              // Self-host contact info
              _SelfHostContactInfo(theme: theme),
              const SizedBox(height: 12),

              // Close button
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  context.l10n.maybeLater,
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getMessage(BuildContext context) {
    if (customMessage != null) return customMessage!;

    if (feature != null) {
      return context.l10n.featureIsProFeature(
        EntitlementGuard.getFeatureDescription(feature!, context.l10n),
      );
    }

    return context.l10n.unlockAllFeatures;
  }
}

class _FeatureComparisonCard extends StatelessWidget {
  const _FeatureComparisonCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    context.l10n.featureTableHeader,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    context.l10n.free,
                    style: theme.textTheme.labelLarge,
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: Text(
                    context.l10n.pro,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Features
          _FeatureRow(
            feature: context.l10n.paywallLocalNotes,
            free: context.l10n.unlimited,
            pro: context.l10n.unlimited,
          ),
          _FeatureRow(
            feature: context.l10n.lockedNotes,
            free: context.l10n.lockedNotesFreeLimit,
            pro: context.l10n.unlimited,
          ),
          _FeatureRow(
            feature: context.l10n.realtimeCloudSync,
            free: false,
            pro: true,
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String feature;
  final dynamic free;
  final dynamic pro;

  const _FeatureRow({
    required this.feature,
    required this.free,
    required this.pro,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(feature, style: theme.textTheme.bodyMedium),
          ),
          Expanded(child: _buildValue(context, free, false)),
          Expanded(child: _buildValue(context, pro, true)),
        ],
      ),
    );
  }

  Widget _buildValue(BuildContext context, dynamic value, bool isPro) {
    final theme = Theme.of(context);

    if (value is bool) {
      return Icon(
        value ? Icons.check_circle : Icons.remove_circle_outline,
        size: 20,
        color: value
            ? (isPro ? theme.colorScheme.primary : Colors.green)
            : theme.colorScheme.outline,
      );
    }

    return Text(
      value.toString(),
      style: theme.textTheme.bodySmall?.copyWith(
        color: isPro
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
        fontWeight: isPro ? FontWeight.w600 : FontWeight.normal,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _PricingOptions extends StatefulWidget {
  const _PricingOptions();

  @override
  State<_PricingOptions> createState() => _PricingOptionsState();
}

class _PricingOptionsState extends State<_PricingOptions> {
  bool _yearlySelected = true;
  bool _isLoadingProducts = false;

  String? get _monthlyPrice =>
      SubscriptionService.instance.getDisplayPriceSafe(yearly: false);
  String? get _yearlyPrice =>
      SubscriptionService.instance.getDisplayPriceSafe(yearly: true);
  int get _savePercentage =>
      SubscriptionService.instance.calculateSavePercentage();

  bool get _pricesAvailable => _monthlyPrice != null && _yearlyPrice != null;

  @override
  void initState() {
    super.initState();
    // If products aren't available, try to reload them (only for mobile IAP)
    if (!_pricesAvailable && !SubscriptionService.instance.usesRazorpay) {
      _loadProducts();
    }
    // Listen to currency changes to update prices
    if (SubscriptionService.instance.usesRazorpay) {
      SubscriptionService.instance.selectedCurrency.addListener(
        _onCurrencyChanged,
      );
    }
  }

  @override
  void dispose() {
    if (SubscriptionService.instance.usesRazorpay) {
      SubscriptionService.instance.selectedCurrency.removeListener(
        _onCurrencyChanged,
      );
    }
    super.dispose();
  }

  void _onCurrencyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadProducts() async {
    if (_isLoadingProducts) return;
    if (!mounted) return;
    setState(() => _isLoadingProducts = true);

    await SubscriptionService.instance.reloadProducts();

    if (mounted) {
      setState(() => _isLoadingProducts = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show loading indicator while products are loading
    if (_isLoadingProducts) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    // If prices aren't available (products not loaded for mobile IAP), show redirect button
    // But for Razorpay, we always have hardcoded prices, so show full UI
    if (!_pricesAvailable && !SubscriptionService.instance.usesRazorpay) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _handleSubscribe(context),
              icon: const Icon(Icons.rocket_launch),
              label: Text(context.l10n.loadingFailedTryAgain),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loadProducts,
            child: Text(context.l10n.reloadPrices),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (SubscriptionService.instance.usesRazorpay) ...[
          _buildCurrencySelector(theme),
          const SizedBox(height: 12),
        ],

        // Plan period toggle
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _PeriodButton(
                  label: context.l10n.monthly,
                  sublabel: _monthlyPrice!,
                  selected: !_yearlySelected,
                  onTap: () => setState(() => _yearlySelected = false),
                ),
              ),
              Expanded(
                child: _PeriodButton(
                  label: context.l10n.yearly,
                  sublabel: _yearlyPrice!,
                  badge: _savePercentage > 0
                      ? context.l10n.savePercent(_savePercentage)
                      : null,
                  selected: _yearlySelected,
                  onTap: () => setState(() => _yearlySelected = true),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Subscribe button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _handleSubscribe(context),
            icon: const Icon(Icons.rocket_launch),
            label: Text(
              context.l10n.subscribeWithPrice(
                _yearlySelected ? _yearlyPrice! : _monthlyPrice!,
              ),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCurrencySelector(ThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: SubscriptionService.instance.isCurrencyLoading,
      builder: (context, isLoading, _) {
        if (isLoading) {
          return Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.detectingLocation,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          );
        }

        return ValueListenableBuilder<RazorpayCurrency>(
          valueListenable: SubscriptionService.instance.selectedCurrency,
          builder: (context, currentCurrency, _) {
            return Column(
              children: [
                SizedBox(
                  width: 240,
                  child: SegmentedButton<RazorpayCurrency>(
                    segments: const [
                      ButtonSegment<RazorpayCurrency>(
                        value: RazorpayCurrency.usd,
                        label: Text('USD (\$)'),
                      ),
                      ButtonSegment<RazorpayCurrency>(
                        value: RazorpayCurrency.inr,
                        label: Text('INR (₹)'),
                      ),
                    ],
                    selected: {currentCurrency},
                    onSelectionChanged: (Set<RazorpayCurrency> selected) {
                      SubscriptionService.instance.selectedCurrency.value =
                          selected.first;
                    },
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    expandedInsets: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.currencyHelpText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleSubscribe(BuildContext context) async {
    // Set Razorpay theme color to match the app's primary color
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    debugPrint(
      'PaywallSheet: Primary color = $primaryColor (value: 0x${primaryColor.toARGB32().toRadixString(16)})',
    );
    RazorpayService.instance.setThemeColor(primaryColor);
    debugPrint(
      'PaywallSheet: After setThemeColor, themeColorHex = ${RazorpayService.instance.themeColorHex}',
    );

    final PurchaseResult result;
    try {
      result = await SubscriptionService.instance.purchaseSubscription(
        yearly: _yearlySelected,
      );
    } catch (e) {
      AppLogger.error('PaywallSheet: Unexpected purchase error', e);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.somethingWentWrongTryAgain),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!context.mounted) return;

    if (result.isSuccess) {
      // Only pop if this route is still the current (topmost) route.
      // PaywallPage._onSubscriptionChange may have already popped this route
      // during the purchaseSubscription() await — popping again would remove
      // the page underneath, causing a black screen.
      final route = ModalRoute.of(context);
      if (route != null && route.isCurrent) {
        Navigator.pop(context, true);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_localizedPurchaseMessage(context, result)),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else if (result.isPending) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_localizedPurchaseMessage(context, result))),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_localizedPurchaseMessage(context, result)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class _PeriodButton extends StatelessWidget {
  final String label;
  final String sublabel;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodButton({
    required this.label,
    required this.sublabel,
    this.badge,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Badge or placeholder for consistent height
            SizedBox(
              height: 22,
              child: badge != null
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.colorScheme.onPrimary.withValues(alpha: 0.2)
                            : theme.colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        badge!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: selected
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              sublabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary.withValues(alpha: 0.8)
                    : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelfHostContactInfo extends StatelessWidget {
  final ThemeData theme;

  const _SelfHostContactInfo({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Text(
      context.l10n.selfHostContact,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// Full-screen paywall page.
class PaywallPage extends StatefulWidget {
  final GatedFeature? feature;
  final String? customMessage;

  const PaywallPage({super.key, this.feature, this.customMessage});

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  bool _yearlySelected = true;
  bool _isLoading = false;
  bool _isLoadingProducts = false;
  bool _hasPopped = false;

  String? get _monthlyPrice =>
      SubscriptionService.instance.getDisplayPriceSafe(yearly: false);
  String? get _yearlyPrice =>
      SubscriptionService.instance.getDisplayPriceSafe(yearly: true);
  int get _savePercentage =>
      SubscriptionService.instance.calculateSavePercentage();

  bool get _pricesAvailable => _monthlyPrice != null && _yearlyPrice != null;

  @override
  void initState() {
    super.initState();
    SubscriptionService.instance.isLoading.addListener(_onLoadingChange);
    PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);
    // Listen to currency changes to update prices
    if (SubscriptionService.instance.usesRazorpay) {
      SubscriptionService.instance.selectedCurrency.addListener(
        _onCurrencyChanged,
      );
    }
    // If products aren't available, try to reload them (only for mobile IAP)
    if (!_pricesAvailable && !SubscriptionService.instance.usesRazorpay) {
      _loadProducts();
    }
    // Refresh subscription status when paywall opens to catch any missed updates
    _checkExistingSubscription();
  }

  /// Check for existing subscription and close paywall if already subscribed
  Future<void> _checkExistingSubscription() async {
    // Refresh subscription from server to get latest status
    await PlanService.instance.refreshSubscription();

    if (!mounted) return;

    final status = PlanService.instance.status;
    // If user has active paid subscription (non-trial), close paywall
    if (status.isActive && status.plan.isPaid && !status.isTrialSubscription) {
      if (_hasPopped) return;
      _hasPopped = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.alreadyHaveSubscription(
              status.plan.localizedDisplayName(context.l10n),
            ),
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    SubscriptionService.instance.isLoading.removeListener(_onLoadingChange);
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    if (SubscriptionService.instance.usesRazorpay) {
      SubscriptionService.instance.selectedCurrency.removeListener(
        _onCurrencyChanged,
      );
    }
    super.dispose();
  }

  void _onCurrencyChanged() {
    if (mounted) setState(() {});
  }

  void _onLoadingChange() {
    if (mounted) {
      final wasLoading = _isLoading;
      final isNowLoading = SubscriptionService.instance.isLoading.value;

      setState(() {
        _isLoading = isNowLoading;
      });

      // If loading just finished, check for errors
      if (wasLoading && !isNowLoading) {
        final error = SubscriptionService.instance.lastPurchaseError;
        if (error != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red),
          );
          SubscriptionService.instance.clearLastPurchaseError();
        }
      }
    }
  }

  void _onSubscriptionChange() {
    if (_hasPopped) return;
    final status = PlanService.instance.status;
    // Only auto-close for paid subscriptions (not trial)
    if (mounted &&
        status.isActive &&
        status.plan.isPaid &&
        !status.isTrialSubscription) {
      _hasPopped = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.welcomeToProMessage),
          backgroundColor: Colors.green,
        ),
      );
      // User successfully subscribed, close the paywall
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _loadProducts() async {
    if (_isLoadingProducts) return;
    if (!mounted) return;
    setState(() => _isLoadingProducts = true);

    await SubscriptionService.instance.reloadProducts();

    if (mounted) {
      setState(() => _isLoadingProducts = false);
    }
  }

  Widget _buildCurrencySelector(ThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: SubscriptionService.instance.isCurrencyLoading,
      builder: (context, isLoading, _) {
        if (isLoading) {
          return Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.detectingLocation,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          );
        }

        return ValueListenableBuilder<RazorpayCurrency>(
          valueListenable: SubscriptionService.instance.selectedCurrency,
          builder: (context, currentCurrency, _) {
            return Column(
              children: [
                SizedBox(
                  width: 240,
                  child: SegmentedButton<RazorpayCurrency>(
                    segments: const [
                      ButtonSegment<RazorpayCurrency>(
                        value: RazorpayCurrency.usd,
                        label: Text('USD (\$)'),
                      ),
                      ButtonSegment<RazorpayCurrency>(
                        value: RazorpayCurrency.inr,
                        label: Text('INR (₹)'),
                      ),
                    ],
                    selected: {currentCurrency},
                    onSelectionChanged: (Set<RazorpayCurrency> selected) {
                      SubscriptionService.instance.selectedCurrency.value =
                          selected.first;
                      setState(() {}); // Refresh prices
                    },
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    expandedInsets: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.currencyHelpText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.upgradeToPro),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, false),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Compact hero: icon inline with title
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.workspace_premium_rounded,
                          size: 26,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            context.l10n.unlockTheFullExperience,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _getMessage(context),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // Feature comparison
                    const _FeatureComparisonCard(),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.noAdsDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),

                    // Pricing section
                    if (_isLoadingProducts) ...[
                      // Loading products
                      const SizedBox(height: 24),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                      Text(
                        context.l10n.loadingPrices,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                    ] else if (_pricesAvailable ||
                        SubscriptionService.instance.usesRazorpay) ...[
                      // Currency selector for Razorpay platforms
                      if (SubscriptionService.instance.usesRazorpay) ...[
                        _buildCurrencySelector(theme),
                        const SizedBox(height: 16),
                      ],

                      // Pricing toggle
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _PeriodButton(
                                label: context.l10n.monthly,
                                sublabel: _monthlyPrice!,
                                selected: !_yearlySelected,
                                onTap: () =>
                                    setState(() => _yearlySelected = false),
                              ),
                            ),
                            Expanded(
                              child: _PeriodButton(
                                label: context.l10n.yearly,
                                sublabel: _yearlyPrice!,
                                badge: _savePercentage > 0
                                    ? context.l10n.savePercent(_savePercentage)
                                    : null,
                                selected: _yearlySelected,
                                onTap: () =>
                                    setState(() => _yearlySelected = true),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Subscribe button
                      SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          onPressed: _isLoading ? null : _handleSubscribe,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.rocket_launch),
                          label: Text(
                            _isLoading
                                ? context.l10n.processingSubscription
                                : context.l10n.subscribeWithPrice(
                                    _yearlySelected
                                        ? _yearlyPrice!
                                        : _monthlyPrice!,
                                  ),
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ] else ...[
                      // Products failed to load
                      Text(
                        context.l10n.somethingWentWrongCheckConnection,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: _loadProducts,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.reloadPrices),
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Restore info
                    const _RestoreInfoText(),
                    const SizedBox(height: 24),

                    // Terms
                    Text(
                      context.l10n.subscriptionAutoRenewTerms,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),

                    // Terms and Privacy links
                    const _LegalLinks(),
                    const SizedBox(height: 16),

                    // Self-host contact info
                    _SelfHostContactInfo(theme: theme),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getMessage(BuildContext context) {
    if (widget.customMessage != null) return widget.customMessage!;

    if (widget.feature != null) {
      return context.l10n.featureIsProFeature(
        EntitlementGuard.getFeatureDescription(widget.feature!, context.l10n),
      );
    }

    return context.l10n.unlockAllFeatures;
  }

  Future<void> _handleSubscribe() async {
    // Set Razorpay theme color to match the app's primary color
    final themeData = Theme.of(context);
    final primaryColor = themeData.colorScheme.primary;
    debugPrint(
      'PaywallPage: Primary color = $primaryColor (value: 0x${primaryColor.toARGB32().toRadixString(16)})',
    );
    RazorpayService.instance.setThemeColor(primaryColor);
    debugPrint(
      'PaywallPage: After setThemeColor, themeColorHex = ${RazorpayService.instance.themeColorHex}',
    );

    final PurchaseResult result;
    try {
      result = await SubscriptionService.instance.purchaseSubscription(
        yearly: _yearlySelected,
      );
    } catch (e) {
      AppLogger.error('PaywallPage: Unexpected purchase error', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.somethingWentWrongTryAgain),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;

    if (result.isSuccess) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_localizedPurchaseMessage(context, result)),
          backgroundColor: Colors.green,
        ),
      );
    } else if (result.isPending) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_localizedPurchaseMessage(context, result))),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_localizedPurchaseMessage(context, result)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

class _RestoreInfoText extends StatelessWidget {
  const _RestoreInfoText();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      context.l10n.restoreInfoText,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _LegalLinks extends StatelessWidget {
  const _LegalLinks();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://betterkeep.app/terms'),
            mode: LaunchMode.externalApplication,
          ),
          child: Text('Terms of Use', style: linkStyle),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '|',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://betterkeep.app/privacy'),
            mode: LaunchMode.externalApplication,
          ),
          child: Text('Privacy Policy', style: linkStyle),
        ),
      ],
    );
  }
}
