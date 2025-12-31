import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:flutter/material.dart';

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

              // Icon and title
              Icon(
                Icons.workspace_premium_rounded,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Upgrade to Pro',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Feature-specific or custom message
              Text(
                _getMessage(),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Why we charge
              _WhyWeChargeCard(theme: theme),
              const SizedBox(height: 24),

              // Feature comparison
              const _FeatureComparisonCard(),
              const SizedBox(height: 24),

              // Pricing options
              const _PricingOptions(),
              const SizedBox(height: 16),

              // Self-host contact info
              _SelfHostContactInfo(theme: theme),
              const SizedBox(height: 16),

              // Close button
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  'Maybe later',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getMessage() {
    if (customMessage != null) return customMessage!;

    if (feature != null) {
      return '${EntitlementGuard.getFeatureDescription(feature!)} is a Pro feature.';
    }

    return 'Unlock all features and support development.';
  }
}

class _WhyWeChargeCard extends StatelessWidget {
  final ThemeData theme;

  const _WhyWeChargeCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Why we charge',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Cloud sync and end-to-end encryption require real servers that cost money to run. '
            'Your subscription directly funds secure infrastructure and ongoing development. '
            'No ads, no data selling — just notes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
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
                    'Feature',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Free',
                    style: theme.textTheme.labelLarge,
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: Text(
                    'Pro',
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
            feature: 'Local notes',
            free: 'Unlimited',
            pro: 'Unlimited',
          ),
          _FeatureRow(feature: 'Locked notes', free: '5 max', pro: 'Unlimited'),
          _FeatureRow(feature: 'Real-time cloud sync', free: false, pro: true),
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
    if (!_pricesAvailable) {
      return Column(
        children: [
          // Currency selector disabled - Razorpay Subscriptions only supports INR
          // for most Indian merchants. USD requires special approval.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _handleSubscribe(context),
              icon: const Icon(Icons.rocket_launch),
              label: Text(
                SubscriptionService.instance.usesRazorpay
                    ? 'Subscribe Now'
                    : 'Loading failed - Try again',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          if (!SubscriptionService.instance.usesRazorpay) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadProducts,
              child: const Text('Reload prices'),
            ),
          ],
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
                  label: 'Monthly',
                  sublabel: _monthlyPrice!,
                  selected: !_yearlySelected,
                  onTap: () => setState(() => _yearlySelected = false),
                ),
              ),
              Expanded(
                child: _PeriodButton(
                  label: 'Yearly',
                  sublabel: _yearlyPrice!,
                  badge: _savePercentage > 0 ? 'Save $_savePercentage%' : null,
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
              _yearlySelected
                  ? 'Subscribe — $_yearlyPrice'
                  : 'Subscribe — $_monthlyPrice',
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
    final currentCurrency = SubscriptionService.instance.selectedCurrency.value;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Currency: ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        SegmentedButton<RazorpayCurrency>(
          segments: [
            ButtonSegment<RazorpayCurrency>(
              value: RazorpayCurrency.usd,
              label: const Text('USD (\$)'),
            ),
            ButtonSegment<RazorpayCurrency>(
              value: RazorpayCurrency.inr,
              label: const Text('INR (₹)'),
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
        ),
      ],
    );
  }

  Future<void> _handleSubscribe(BuildContext context) async {
    // Set Razorpay theme color to match the app's primary color
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    debugPrint(
      'PaywallSheet: Primary color = $primaryColor (value: 0x${primaryColor.value.toRadixString(16)})',
    );
    RazorpayService.instance.setThemeColor(primaryColor);
    debugPrint(
      'PaywallSheet: After setThemeColor, themeColorHex = ${RazorpayService.instance.themeColorHex}',
    );

    final result = await SubscriptionService.instance.purchaseSubscription(
      yearly: _yearlySelected,
    );

    if (!context.mounted) return;

    if (result.isSuccess) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), backgroundColor: Colors.green),
      );
    } else if (result.isPending) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), backgroundColor: Colors.red),
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
      'Want to self-host? Contact us at contact@betterkeep.app',
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
      // Show snackbar before popping to ensure context is still valid
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'You already have an active ${status.plan.displayName} subscription!',
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
    super.dispose();
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
    final status = PlanService.instance.status;
    // Only auto-close for paid subscriptions (not trial)
    if (mounted &&
        status.isActive &&
        status.plan.isPaid &&
        !status.isTrialSubscription) {
      // Show snackbar before popping to ensure context is still valid
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Welcome to Better Keep Pro!'),
          backgroundColor: Colors.green,
        ),
      );
      // User successfully subscribed, close the paywall
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _loadProducts() async {
    if (_isLoadingProducts) return;
    setState(() => _isLoadingProducts = true);

    await SubscriptionService.instance.reloadProducts();

    if (mounted) {
      setState(() => _isLoadingProducts = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Upgrade to Pro'),
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
                    // Icon and title
                    Icon(
                      Icons.workspace_premium_rounded,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Unlock the Full Experience',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _getMessage(),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // Why we charge
                    _WhyWeChargeCard(theme: theme),
                    const SizedBox(height: 24),

                    // Feature comparison
                    const _FeatureComparisonCard(),
                    const SizedBox(height: 32),

                    // Pricing section
                    if (_isLoadingProducts) ...[
                      // Loading products
                      const SizedBox(height: 24),
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                      Text(
                        'Loading prices...',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                    ] else if (_pricesAvailable) ...[
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
                                label: 'Monthly',
                                sublabel: _monthlyPrice!,
                                selected: !_yearlySelected,
                                onTap: () =>
                                    setState(() => _yearlySelected = false),
                              ),
                            ),
                            Expanded(
                              child: _PeriodButton(
                                label: 'Yearly',
                                sublabel: _yearlyPrice!,
                                badge: _savePercentage > 0
                                    ? 'Save $_savePercentage%'
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
                                ? 'Processing...'
                                : _yearlySelected
                                ? 'Subscribe — $_yearlyPrice'
                                : 'Subscribe — $_monthlyPrice',
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ] else ...[
                      // Products failed to load
                      Text(
                        'Unable to load prices. Please check your internet connection.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: _loadProducts,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reload prices'),
                      ),
                    ],
                    const SizedBox(height: 24),

                    // Self-host contact info
                    _SelfHostContactInfo(theme: theme),
                    const SizedBox(height: 32),

                    // Terms
                    Text(
                      'Payment will be charged to your account. Subscription automatically '
                      'renews unless auto-renew is turned off at least 24 hours before '
                      'the end of the current period.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      textAlign: TextAlign.center,
                    ),
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

  String _getMessage() {
    if (widget.customMessage != null) return widget.customMessage!;

    if (widget.feature != null) {
      return '${EntitlementGuard.getFeatureDescription(widget.feature!)} is a Pro feature.';
    }

    return 'Unlock all features and support development.';
  }

  Future<void> _handleSubscribe() async {
    // Set Razorpay theme color to match the app's primary color
    final themeData = Theme.of(context);
    final primaryColor = themeData.colorScheme.primary;
    debugPrint(
      'PaywallPage: Primary color = $primaryColor (value: 0x${primaryColor.value.toRadixString(16)})',
    );
    RazorpayService.instance.setThemeColor(primaryColor);
    debugPrint(
      'PaywallPage: After setThemeColor, themeColorHex = ${RazorpayService.instance.themeColorHex}',
    );

    final result = await SubscriptionService.instance.purchaseSubscription(
      yearly: _yearlySelected,
    );

    if (!mounted) return;

    if (result.isSuccess) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), backgroundColor: Colors.green),
      );
    } else if (result.isPending) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message), backgroundColor: Colors.red),
      );
    }
  }
}
