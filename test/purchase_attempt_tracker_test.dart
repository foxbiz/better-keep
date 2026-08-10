import 'package:better_keep/services/monetization/purchase_attempt_tracker.dart';
import 'package:better_keep/services/monetization/purchase_feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PurchaseAttemptTracker', () {
    test('preflight outcomes stay diagnostic and do not end the attempt', () {
      final tracker = PurchaseAttemptTracker();
      final attemptId = tracker.begin();

      expect(tracker.phase, PurchaseAttemptPhase.preflight);
      expect(
        tracker.recordStoreOutcome(PurchaseOutcome.failed, productId: 'pro'),
        isNull,
      );
      expect(tracker.activeAttemptId, attemptId);
      expect(tracker.awaitStore(attemptId, 'pro'), isTrue);
    });

    test('active checkout failure emits once and becomes idle', () {
      final tracker = PurchaseAttemptTracker();
      final attemptId = tracker.begin();
      tracker.awaitStore(attemptId, 'pro');

      final event = tracker.recordStoreOutcome(
        PurchaseOutcome.failed,
        productId: 'pro',
      );

      expect(event?.id, 1);
      expect(event?.attemptId, attemptId);
      expect(event?.outcome, PurchaseOutcome.failed);
      expect(tracker.phase, PurchaseAttemptPhase.idle);
      expect(
        tracker.recordStoreOutcome(PurchaseOutcome.failed, productId: 'pro'),
        isNull,
      );
    });

    test('verified activation emits one success event and becomes idle', () {
      final tracker = PurchaseAttemptTracker();
      final attemptId = tracker.begin();
      tracker.awaitStore(attemptId, 'pro');
      expect(tracker.beginVerification(attemptId, 'pro'), isTrue);

      final event = tracker.recordStoreOutcome(
        PurchaseOutcome.activated,
        productId: 'pro',
      );

      expect(event?.outcome, PurchaseOutcome.activated);
      expect(event?.attemptId, attemptId);
      expect(tracker.phase, PurchaseAttemptPhase.idle);
      expect(
        tracker.recordStoreOutcome(PurchaseOutcome.activated, productId: 'pro'),
        isNull,
      );
    });

    test('new attempts and events receive monotonic identifiers', () {
      final tracker = PurchaseAttemptTracker();
      final firstAttempt = tracker.begin();
      tracker.awaitStore(firstAttempt, 'pro');
      final firstEvent = tracker.recordStoreOutcome(
        PurchaseOutcome.cancelled,
        productId: 'pro',
      )!;

      final secondAttempt = tracker.begin();
      tracker.awaitStore(secondAttempt, 'pro');
      tracker.beginVerification(secondAttempt, 'pro');
      final secondEvent = tracker.recordStoreOutcome(
        PurchaseOutcome.failed,
        productId: 'pro',
      )!;

      expect(secondAttempt, greaterThan(firstAttempt));
      expect(secondEvent.id, greaterThan(firstEvent.id));
      expect(secondEvent.attemptId, secondAttempt);
    });

    test('immediate completion produces no asynchronous event', () {
      final tracker = PurchaseAttemptTracker();
      final attemptId = tracker.begin();

      tracker.finish(attemptId);

      expect(tracker.phase, PurchaseAttemptPhase.idle);
      expect(
        tracker.recordStoreOutcome(PurchaseOutcome.failed, productId: 'pro'),
        isNull,
      );
    });

    test('reset clears activity without reusing identifiers', () {
      final tracker = PurchaseAttemptTracker();
      final firstAttempt = tracker.begin();
      tracker.awaitStore(firstAttempt, 'pro');
      final firstEvent = tracker.recordStoreOutcome(
        PurchaseOutcome.failed,
        productId: 'pro',
      )!;

      tracker.reset();
      final secondAttempt = tracker.begin();
      tracker.awaitStore(secondAttempt, 'pro');
      final secondEvent = tracker.recordStoreOutcome(
        PurchaseOutcome.failed,
        productId: 'pro',
      )!;

      expect(secondAttempt, greaterThan(firstAttempt));
      expect(secondEvent.id, greaterThan(firstEvent.id));
    });

    test('ignores a delayed outcome for another product', () {
      final tracker = PurchaseAttemptTracker();
      final attemptId = tracker.begin();
      tracker.awaitStore(attemptId, 'pro_subscription');

      final unrelated = tracker.recordStoreOutcome(
        PurchaseOutcome.failed,
        productId: 'legacy_product',
      );

      expect(unrelated, isNull);
      expect(tracker.activeAttemptId, attemptId);
      expect(tracker.activeProductId, 'pro_subscription');
      expect(tracker.phase, PurchaseAttemptPhase.awaitingStore);
    });
  });
}
