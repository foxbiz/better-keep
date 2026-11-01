import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// Billing-period selection and checkout, shared by both paywalls.
class SubscriptionPurchaseOptions extends StatefulWidget {
  const SubscriptionPurchaseOptions({
    super.key,
    required this.monthlyPrice,
    required this.yearlyPrice,
    required this.savePercentage,
    required this.isBusy,
    required this.progressLabel,
    required this.onSubscribe,
  });

  final String monthlyPrice;
  final String yearlyPrice;
  final int savePercentage;
  final bool isBusy;
  final String progressLabel;
  final ValueChanged<bool> onSubscribe;

  @override
  State<SubscriptionPurchaseOptions> createState() =>
      _SubscriptionPurchaseOptionsState();
}

class _SubscriptionPurchaseOptionsState
    extends State<SubscriptionPurchaseOptions> {
  bool _yearly = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, label: Text(l10n.monthly)),
            ButtonSegment(value: true, label: Text(l10n.yearly)),
          ],
          selected: {_yearly},
          onSelectionChanged: widget.isBusy
              ? null
              : (selection) => setState(() => _yearly = selection.single),
        ),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              _yearly ? widget.yearlyPrice : widget.monthlyPrice,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_yearly && widget.savePercentage > 0)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    l10n.savePercent(widget.savePercentage),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.isBusy ? null : () => widget.onSubscribe(_yearly),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: widget.isBusy
              ? Semantics(
                  liveRegion: true,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Flexible(child: Text(widget.progressLabel)),
                    ],
                  ),
                )
              : Text(l10n.subscribe),
        ),
      ],
    );
  }
}
