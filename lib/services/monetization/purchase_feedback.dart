import 'package:flutter/foundation.dart';

enum PurchaseOutcome {
  activated,
  restored,
  alreadyActive,
  activationPending,
  ownershipConflict,
  cancelled,
  pending,
  signInRequired,
  unavailable,
  failed,
}

/// User-visible phases of one native app-store purchase attempt.
enum PurchaseAttemptPhase { idle, preflight, awaitingStore, verifying }

/// Recognizes the stable Google Play and StoreKit forms of an owned item.
bool isAlreadyOwnedStoreError(Object? error) {
  final value = error?.toString().toLowerCase() ?? '';
  return value.contains('itemalreadyowned') ||
      value.contains('item_already_owned') ||
      value.contains('already owned') ||
      value.contains('already purchased');
}

/// A one-shot presentation event produced by an asynchronous store checkout.
///
/// Event and attempt identifiers are monotonic so listeners can ignore events
/// that predate their lifecycle and avoid handling the same outcome twice.
@immutable
class PurchaseEvent {
  const PurchaseEvent({
    required this.id,
    required this.attemptId,
    required this.outcome,
  });

  final int id;
  final int attemptId;
  final PurchaseOutcome outcome;
}
