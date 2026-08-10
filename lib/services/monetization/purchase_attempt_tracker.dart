import 'package:better_keep/services/monetization/purchase_feedback.dart';

/// Tracks which asynchronous store updates belong to the active checkout.
///
/// This class is intentionally kept outside the public monetization barrel. It
/// is separate from the subscription service so the state transitions can be
/// unit tested without Firebase or platform-channel dependencies.
class PurchaseAttemptTracker {
  int _nextAttemptId = 0;
  int _nextEventId = 0;
  int? _activeAttemptId;
  String? _activeProductId;
  PurchaseAttemptPhase _phase = PurchaseAttemptPhase.idle;

  int? get activeAttemptId => _activeAttemptId;
  String? get activeProductId => _activeProductId;
  PurchaseAttemptPhase get phase => _phase;

  bool get acceptsStoreOutcome =>
      _activeAttemptId != null &&
      (_phase == PurchaseAttemptPhase.awaitingStore ||
          _phase == PurchaseAttemptPhase.verifying);

  int begin() {
    final attemptId = ++_nextAttemptId;
    _activeAttemptId = attemptId;
    _phase = PurchaseAttemptPhase.preflight;
    return attemptId;
  }

  bool awaitStore(int attemptId, String productId) {
    if (_activeAttemptId != attemptId) return false;
    _activeProductId = productId;
    _phase = PurchaseAttemptPhase.awaitingStore;
    return true;
  }

  bool beginVerification(int attemptId, String productId) {
    if (_activeAttemptId != attemptId || !acceptsStoreOutcomeFor(productId)) {
      return false;
    }
    _phase = PurchaseAttemptPhase.verifying;
    return true;
  }

  bool acceptsStoreOutcomeFor(String productId) {
    if (!acceptsStoreOutcome) return false;

    // Some store-level failures do not include a product identifier. Since
    // only one checkout can be active, those still belong to that checkout.
    return productId.isEmpty || productId == _activeProductId;
  }

  PurchaseEvent? recordStoreOutcome(
    PurchaseOutcome outcome, {
    required String productId,
  }) {
    final attemptId = _activeAttemptId;
    if (attemptId == null || !acceptsStoreOutcomeFor(productId)) return null;

    final event = PurchaseEvent(
      id: ++_nextEventId,
      attemptId: attemptId,
      outcome: outcome,
    );
    finish(attemptId);
    return event;
  }

  void finish(int attemptId) {
    if (_activeAttemptId != attemptId) return;
    _activeAttemptId = null;
    _activeProductId = null;
    _phase = PurchaseAttemptPhase.idle;
  }

  void reset() {
    _activeAttemptId = null;
    _activeProductId = null;
    _phase = PurchaseAttemptPhase.idle;
  }
}
