import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/ui/paywall/purchase_feedback_listener.dart';
import 'package:better_keep/ui/paywall/subscription_purchase_options.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows the paywall as a full-screen page.
///
/// Returns true if the user upgraded, false otherwise.
Future<bool> showPaywall(
  BuildContext context, {
  GatedFeature? feature,
  String? customMessage,
  UserPlan initialPlan = UserPlan.pro,
}) async {
  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (context) => PaywallPage(
        feature: feature,
        customMessage: customMessage,
        initialPlan: initialPlan,
      ),
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
        label: context.l10n.upgrade,
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

    return PurchaseFeedbackListener(
      events: SubscriptionService.instance.purchaseEvents,
      child: Container(
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
  const _FeatureComparisonCard({this.plan = UserPlan.pro});

  final UserPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    l10n.featureTableHeader,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                for (final tier in UserPlan.values)
                  Expanded(
                    flex: 2,
                    child: Text(
                      tier.localizedDisplayName(l10n),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: tier == plan ? theme.colorScheme.primary : null,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          _FeatureRow(
            feature: l10n.paywallLocalNotes,
            free: l10n.unlimited,
            lite: l10n.unlimited,
            pro: l10n.unlimited,
          ),
          _FeatureRow(
            feature: l10n.manualExternalSync,
            free: true,
            lite: true,
            pro: true,
          ),
          _FeatureRow(
            feature: l10n.automaticExternalSync,
            free: false,
            lite: true,
            pro: true,
          ),
          _FeatureRow(
            feature: l10n.builtInCloudSync,
            free: false,
            lite: false,
            pro: true,
          ),
          _FeatureRow(
            feature: l10n.lockedNotes,
            free: Entitlements.free.maxLockedNotes,
            lite: Entitlements.lite.maxLockedNotes,
            pro: l10n.unlimited,
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String feature;
  final Object free;
  final Object lite;
  final Object pro;

  const _FeatureRow({
    required this.feature,
    required this.free,
    required this.lite,
    required this.pro,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(feature, style: theme.textTheme.bodyMedium),
            ),
          ),
          for (final value in [free, lite, pro])
            Expanded(flex: 2, child: _buildValue(context, value)),
        ],
      ),
    );
  }

  Widget _buildValue(BuildContext context, Object value) {
    final theme = Theme.of(context);

    if (value is bool) {
      return Icon(
        value ? Icons.check_circle : Icons.remove_circle_outline,
        size: 18,
        color: value ? theme.colorScheme.primary : theme.colorScheme.outline,
        semanticLabel: value ? context.l10n.yes : context.l10n.no,
      );
    }

    if (value == context.l10n.unlimited) {
      return Tooltip(
        message: context.l10n.unlimited,
        child: Icon(
          Icons.all_inclusive,
          size: 22,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        value.toString(),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _PricingOptions extends StatefulWidget {
  const _PricingOptions();

  @override
  State<_PricingOptions> createState() => _PricingOptionsState();
}

class _PricingOptionsState extends State<_PricingOptions> {
  bool _isLoading = false;
  bool _isLoadingProducts = false;
  PurchaseAttemptPhase _purchasePhase = PurchaseAttemptPhase.idle;

  bool get _isBusy => SubscriptionService.instance.usesRazorpay
      ? _isLoading
      : _purchasePhase != PurchaseAttemptPhase.idle;

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
    _isLoading = SubscriptionService.instance.isLoading.value;
    _purchasePhase = SubscriptionService.instance.purchasePhase.value;
    SubscriptionService.instance.storeReadiness.addListener(
      _onStoreReadinessChanged,
    );
    SubscriptionService.instance.isLoading.addListener(_onLoadingChange);
    SubscriptionService.instance.purchasePhase.addListener(
      _onPurchasePhaseChanged,
    );
    // If products aren't available, try to reload them (only for mobile IAP)
    if (!_pricesAvailable &&
        !SubscriptionService.instance.usesRazorpay &&
        SubscriptionService.instance.storeReadiness.value !=
            StoreReadiness.unavailable) {
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
    SubscriptionService.instance.storeReadiness.removeListener(
      _onStoreReadinessChanged,
    );
    SubscriptionService.instance.isLoading.removeListener(_onLoadingChange);
    SubscriptionService.instance.purchasePhase.removeListener(
      _onPurchasePhaseChanged,
    );
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

  void _onStoreReadinessChanged() {
    if (mounted) setState(() {});
  }

  void _onLoadingChange() {
    if (mounted) {
      setState(() {
        _isLoading = SubscriptionService.instance.isLoading.value;
      });
    }
  }

  void _onPurchasePhaseChanged() {
    if (mounted) {
      setState(() {
        _purchasePhase = SubscriptionService.instance.purchasePhase.value;
      });
    }
  }

  String _progressLabel(BuildContext context) => switch (_purchasePhase) {
    PurchaseAttemptPhase.preflight => context.l10n.checkingStatus,
    PurchaseAttemptPhase.awaitingStore => context.l10n.processingSubscription,
    PurchaseAttemptPhase.verifying => context.l10n.verifying,
    PurchaseAttemptPhase.idle => context.l10n.processingSubscription,
  };

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

    // Native-store prices fail closed with retry UI. Razorpay platforms use
    // configured prices and render the normal purchase controls immediately.
    if (!_pricesAvailable && !SubscriptionService.instance.usesRazorpay) {
      return Column(
        children: [
          Text(context.l10n.somethingWentWrongCheckConnection),
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

        SubscriptionPurchaseOptions(
          monthlyPrice: _monthlyPrice!,
          yearlyPrice: _yearlyPrice!,
          savePercentage: _savePercentage,
          isBusy: _isBusy,
          progressLabel: _progressLabel(context),
          onSubscribe: (yearly) => _handleSubscribe(context, yearly: yearly),
        ),
      ],
    );
  }

  Widget _buildCurrencySelector(ThemeData theme) {
    return ValueListenableBuilder<bool>(
      key: const ValueKey('razorpay-currency-selector'),
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

  Future<void> _handleSubscribe(
    BuildContext context, {
    required bool yearly,
  }) async {
    if (_isBusy) return;
    if (SubscriptionService.instance.usesRazorpay) {
      RazorpayService.instance.setThemeColor(
        Theme.of(context).colorScheme.primary,
      );
    }

    final PurchaseResult result;
    try {
      result = await SubscriptionService.instance.purchaseSubscription(
        yearly: yearly,
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

    if (!result.isPending) {
      await presentPurchaseOutcome(context, result.outcome);
    }
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
  final UserPlan initialPlan;

  const PaywallPage({
    super.key,
    this.feature,
    this.customMessage,
    this.initialPlan = UserPlan.pro,
  });

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  late UserPlan _selectedPlan;
  bool _isLoading = false;
  bool _isLoadingProducts = false;
  bool _hasPopped = false;
  PurchaseAttemptPhase _purchasePhase = PurchaseAttemptPhase.idle;

  bool get _isBusy => SubscriptionService.instance.usesRazorpay
      ? _isLoading
      : _purchasePhase != PurchaseAttemptPhase.idle;

  String? get _monthlyPrice => SubscriptionService.instance.getDisplayPriceSafe(
    yearly: false,
    plan: _selectedPlan,
  );
  String? get _yearlyPrice => SubscriptionService.instance.getDisplayPriceSafe(
    yearly: true,
    plan: _selectedPlan,
  );
  int get _savePercentage =>
      SubscriptionService.instance.calculateSavePercentage(plan: _selectedPlan);

  bool get _pricesAvailable => _monthlyPrice != null && _yearlyPrice != null;

  @override
  void initState() {
    super.initState();
    _selectedPlan = widget.initialPlan;
    _isLoading = SubscriptionService.instance.isLoading.value;
    _purchasePhase = SubscriptionService.instance.purchasePhase.value;
    SubscriptionService.instance.isLoading.addListener(_onLoadingChange);
    SubscriptionService.instance.purchasePhase.addListener(
      _onPurchasePhaseChanged,
    );
    SubscriptionService.instance.storeReadiness.addListener(
      _onStoreReadinessChanged,
    );
    // Listen to currency changes to update prices
    if (SubscriptionService.instance.usesRazorpay) {
      SubscriptionService.instance.selectedCurrency.addListener(
        _onCurrencyChanged,
      );
    }
    // If products aren't available, try to reload them (only for mobile IAP)
    if (!_pricesAvailable &&
        !SubscriptionService.instance.usesRazorpay &&
        SubscriptionService.instance.storeReadiness.value !=
            StoreReadiness.unavailable) {
      _loadProducts();
    }
    // Refresh subscription status when paywall opens to catch any missed updates
    _checkExistingSubscription();
  }

  /// Check for existing subscription and close paywall if already subscribed
  Future<void> _checkExistingSubscription() async {
    // Refresh subscription from server to get latest status
    try {
      await PlanService.instance.refreshSubscription();
    } catch (error, stackTrace) {
      AppLogger.error(
        'PaywallPage: Could not refresh subscription on open',
        error,
        stackTrace,
      );
      return;
    }

    if (!mounted) return;

    final status = PlanService.instance.status;
    if (SubscriptionService.instance.purchasePhase.value !=
        PurchaseAttemptPhase.idle) {
      return;
    }
    // If user has active paid subscription (non-trial), close paywall
    if (status.isActive &&
        status.plan == _selectedPlan &&
        !status.isTrialSubscription) {
      if (_hasPopped) return;
      _hasPopped = true;
      await presentPurchaseOutcome(context, PurchaseOutcome.alreadyActive);
    }
  }

  @override
  void dispose() {
    SubscriptionService.instance.isLoading.removeListener(_onLoadingChange);
    SubscriptionService.instance.purchasePhase.removeListener(
      _onPurchasePhaseChanged,
    );
    SubscriptionService.instance.storeReadiness.removeListener(
      _onStoreReadinessChanged,
    );
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

  void _onStoreReadinessChanged() {
    if (mounted) setState(() {});
  }

  void _onLoadingChange() {
    if (mounted) {
      final isNowLoading = SubscriptionService.instance.isLoading.value;

      setState(() {
        _isLoading = isNowLoading;
      });
    }
  }

  void _onPurchasePhaseChanged() {
    if (mounted) {
      setState(() {
        _purchasePhase = SubscriptionService.instance.purchasePhase.value;
      });
    }
  }

  String _progressLabel(BuildContext context) => switch (_purchasePhase) {
    PurchaseAttemptPhase.preflight => context.l10n.checkingStatus,
    PurchaseAttemptPhase.awaitingStore => context.l10n.processingSubscription,
    PurchaseAttemptPhase.verifying => context.l10n.verifying,
    PurchaseAttemptPhase.idle => context.l10n.processingSubscription,
  };

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
      key: const ValueKey('razorpay-currency-selector'),
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

    return PurchaseFeedbackListener(
      events: SubscriptionService.instance.purchaseEvents,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.choosePlan),
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
                      if (widget.feature != null ||
                          widget.customMessage != null) ...[
                        Text(
                          _getMessage(context),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      _FeatureComparisonCard(plan: _selectedPlan),
                      const SizedBox(height: 24),
                      if (SubscriptionService.instance.usesRazorpay) ...[
                        _buildCurrencySelector(theme),
                        const SizedBox(height: 16),
                      ],
                      if (widget.feature == null) ...[
                        SegmentedButton<UserPlan>(
                          segments: [
                            ButtonSegment(
                              value: UserPlan.lite,
                              label: Text(context.l10n.lite),
                            ),
                            ButtonSegment(
                              value: UserPlan.pro,
                              label: Text(context.l10n.pro),
                            ),
                          ],
                          selected: {_selectedPlan},
                          onSelectionChanged: _isBusy
                              ? null
                              : (values) => setState(
                                  () => _selectedPlan = values.single,
                                ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 8),

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
                        SubscriptionPurchaseOptions(
                          monthlyPrice: _monthlyPrice!,
                          yearlyPrice: _yearlyPrice!,
                          savePercentage: _savePercentage,
                          isBusy: _isBusy,
                          progressLabel: _progressLabel(context),
                          onSubscribe: (yearly) =>
                              _handleSubscribe(yearly: yearly),
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

    return _selectedPlan == UserPlan.lite
        ? context.l10n.liteDescription
        : context.l10n.unlockAllFeatures;
  }

  Future<void> _handleSubscribe({required bool yearly}) async {
    if (_isBusy) return;
    if (SubscriptionService.instance.usesRazorpay) {
      RazorpayService.instance.setThemeColor(
        Theme.of(context).colorScheme.primary,
      );
    }

    final PurchaseResult result;
    try {
      result = await SubscriptionService.instance.purchaseSubscription(
        yearly: yearly,
        plan: _selectedPlan,
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

    if (!result.isPending) {
      await presentPurchaseOutcome(context, result.outcome);
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

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://betterkeep.app/terms'),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(context.l10n.termsOfUse, style: linkStyle),
        ),
        GestureDetector(
          onTap: () => launchUrl(
            Uri.parse('https://betterkeep.app/privacy'),
            mode: LaunchMode.externalApplication,
          ),
          child: Text(context.l10n.privacyPolicy, style: linkStyle),
        ),
      ],
    );
  }
}
