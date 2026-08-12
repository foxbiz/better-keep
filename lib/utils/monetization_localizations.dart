import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/monetization/purchase_feedback.dart';

extension PurchaseOutcomeLocalizations on PurchaseOutcome {
  String localized(AppLocalizations l10n) => switch (this) {
    PurchaseOutcome.activated => l10n.subscriptionActivated,
    PurchaseOutcome.restored => l10n.subscriptionRestored,
    PurchaseOutcome.alreadyActive => l10n.subscriptionAlreadyActive,
    PurchaseOutcome.activationPending => l10n.paymentConfirmedActivationPending,
    PurchaseOutcome.ownershipConflict =>
      l10n.subscriptionAccountMismatchMessage,
    PurchaseOutcome.cancelled => l10n.purchaseCancelled,
    PurchaseOutcome.pending => l10n.gettingReady,
    PurchaseOutcome.signInRequired => l10n.pleaseSignInAgain,
    PurchaseOutcome.unavailable ||
    PurchaseOutcome.failed => l10n.somethingWentWrongTryAgain,
  };
}
