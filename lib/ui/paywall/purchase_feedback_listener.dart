import 'dart:async';

import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/monetization_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Presents each asynchronous purchase event once for the mounted paywall.
///
/// An event already present when this widget mounts is deliberately ignored;
/// it belongs to an older paywall lifecycle or purchase attempt.
class PurchaseFeedbackListener extends StatefulWidget {
  const PurchaseFeedbackListener({
    required this.events,
    required this.child,
    super.key,
  });

  final ValueListenable<PurchaseEvent?> events;
  final Widget child;

  @override
  State<PurchaseFeedbackListener> createState() =>
      _PurchaseFeedbackListenerState();
}

class _PurchaseFeedbackListenerState extends State<PurchaseFeedbackListener> {
  late int _lastHandledEventId;

  @override
  void initState() {
    super.initState();
    _lastHandledEventId = widget.events.value?.id ?? 0;
    widget.events.addListener(_handleEvent);
  }

  @override
  void didUpdateWidget(PurchaseFeedbackListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.events, widget.events)) return;

    oldWidget.events.removeListener(_handleEvent);
    _lastHandledEventId = widget.events.value?.id ?? 0;
    widget.events.addListener(_handleEvent);
  }

  @override
  void dispose() {
    widget.events.removeListener(_handleEvent);
    super.dispose();
  }

  void _handleEvent() {
    final event = widget.events.value;
    if (event == null || event.id <= _lastHandledEventId) return;
    _lastHandledEventId = event.id;
    if (!mounted) return;

    unawaited(presentPurchaseOutcome(context, event.outcome));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _PurchaseDialogAction { continueToApp, recheck, manage, done }

Future<void> _openManagement(
  BuildContext context, {
  required bool currentStore,
}) async {
  final result = currentStore
      ? await SubscriptionService.instance
            .openCurrentStoreSubscriptionManagement()
      : await SubscriptionService.instance.openSubscriptionManagement();
  if (!context.mounted || !result.isFailed) return;

  final message = result.outcome == SubscriptionActionOutcome.providerUnknown
      ? context.l10n.subscriptionProviderUnknownContactSupport
      : context.l10n.couldNotOpenSubscriptionManagement;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

/// Shared, one-shot purchase presentation for both paywall variants.
Future<void> presentPurchaseOutcome(
  BuildContext context,
  PurchaseOutcome initialOutcome,
) async {
  var outcome = initialOutcome;
  final navigator = Navigator.of(context);
  final paywallRoute = ModalRoute.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;

  while (navigator.mounted) {
    switch (outcome) {
      case PurchaseOutcome.activated:
      case PurchaseOutcome.restored:
      case PurchaseOutcome.alreadyActive:
        if (!navigator.mounted) return;
        final shouldOfferManagement =
            outcome == PurchaseOutcome.alreadyActive ||
            PlanService.instance.status.isCancelledButActive ||
            PlanService.instance.status.renewalState == RenewalState.unknown;
        final action = await showDialog<_PurchaseDialogAction>(
          context: navigator.context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.workspace_premium_rounded),
            title: Text(dialogContext.l10n.welcomeToProMessage),
            content: Text(outcome.localized(dialogContext.l10n)),
            actions: [
              if (shouldOfferManagement)
                TextButton(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _PurchaseDialogAction.manage,
                  ),
                  child: Text(dialogContext.l10n.manageSubscription),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _PurchaseDialogAction.continueToApp,
                ),
                child: Text(dialogContext.l10n.continue_),
              ),
            ],
          ),
        );

        if (!navigator.mounted) return;
        if (action == _PurchaseDialogAction.manage) {
          await _openManagement(navigator.context, currentStore: false);
          continue;
        }
        if (action == _PurchaseDialogAction.continueToApp) {
          if (paywallRoute != null && paywallRoute.isCurrent) {
            navigator.pop(true);
          }
        }
        return;

      case PurchaseOutcome.activationPending:
        if (!navigator.mounted) return;
        final action = await showDialog<_PurchaseDialogAction>(
          context: navigator.context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.sync_problem_rounded),
            title: Text(dialogContext.l10n.paymentConfirmedTitle),
            content: Text(dialogContext.l10n.paymentConfirmedActivationPending),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _PurchaseDialogAction.manage),
                child: Text(dialogContext.l10n.manageSubscription),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _PurchaseDialogAction.done),
                child: Text(dialogContext.l10n.done),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _PurchaseDialogAction.recheck),
                child: Text(dialogContext.l10n.recheckStatus),
              ),
            ],
          ),
        );

        if (!navigator.mounted || action == _PurchaseDialogAction.done) return;
        if (action == _PurchaseDialogAction.manage) {
          await _openManagement(navigator.context, currentStore: true);
          continue;
        }
        if (action == _PurchaseDialogAction.recheck) {
          final result = await SubscriptionService.instance
              .reconcileCurrentStorePurchase();
          if (!navigator.mounted) return;
          if (result.isPending) return;
          outcome = result.outcome;
          continue;
        }
        return;

      case PurchaseOutcome.ownershipConflict:
        if (!navigator.mounted) return;
        final action = await showDialog<_PurchaseDialogAction>(
          context: navigator.context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.account_circle_outlined),
            title: Text(dialogContext.l10n.subscriptionAccountMismatchTitle),
            content: Text(
              dialogContext.l10n.subscriptionAccountMismatchMessage,
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _PurchaseDialogAction.manage),
                child: Text(dialogContext.l10n.manageSubscription),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, _PurchaseDialogAction.done),
                child: Text(dialogContext.l10n.done),
              ),
            ],
          ),
        );
        if (navigator.mounted && action == _PurchaseDialogAction.manage) {
          await _openManagement(navigator.context, currentStore: true);
        }
        return;

      case PurchaseOutcome.cancelled:
      case PurchaseOutcome.pending:
      case PurchaseOutcome.signInRequired:
      case PurchaseOutcome.unavailable:
      case PurchaseOutcome.failed:
        final isFailure =
            outcome != PurchaseOutcome.cancelled &&
            outcome != PurchaseOutcome.pending;
        messenger.showSnackBar(
          SnackBar(
            content: Text(outcome.localized(l10n)),
            backgroundColor: isFailure ? Colors.red : null,
          ),
        );
        return;
    }
  }
}
