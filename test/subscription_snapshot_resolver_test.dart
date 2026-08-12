import 'package:better_keep/services/monetization/subscription_snapshot_resolver.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:better_keep/services/monetization/verified_entitlement_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 10);

  SubscriptionStatus provider({
    String source = 'play_store',
    RenewalState renewalState = RenewalState.unknown,
    int expiryDays = 30,
  }) => SubscriptionStatus(
    plan: UserPlan.pro,
    purchasePlatform: source,
    billingPeriod: BillingPeriod.yearly,
    expiresAt: now.add(Duration(days: expiryDays)),
    renewalState: renewalState,
    subscriptionState: 'ACTIVE',
  );

  final trial = SubscriptionStatus(
    plan: UserPlan.pro,
    purchasePlatform: 'trial',
    billingPeriod: BillingPeriod.monthly,
    expiresAt: now.add(const Duration(days: 14)),
  );

  test('verified provider wins over trial, free, and missing snapshots', () {
    final verified = provider();
    for (final incoming in <SubscriptionStatus?>[
      trial,
      SubscriptionStatus.free,
      null,
    ]) {
      final result = resolveSubscriptionSnapshot(
        current: trial,
        incoming: incoming,
        verified: verified,
        now: now,
      );

      expect(result.status.purchasePlatform, 'play_store');
      expect(result.retainVerifiedSnapshot, isTrue);
      expect(result.shouldReconcile, isTrue);
    }
  });

  test(
    'current canonical provider is monotonic after verified floor clears',
    () {
      final current = provider(source: 'app_store');
      final result = resolveSubscriptionSnapshot(
        current: current,
        incoming: trial,
        now: now,
      );

      expect(result.status, same(current));
      expect(result.shouldReconcile, isTrue);
    },
  );

  test('canonical provider catch-up is accepted', () {
    final incoming = provider(renewalState: RenewalState.renewing);
    final result = resolveSubscriptionSnapshot(
      current: trial,
      incoming: incoming,
      verified: provider(),
      now: now,
    );

    expect(result.status, same(incoming));
    expect(result.canonicalProviderCaughtUp, isTrue);
    expect(result.retainVerifiedSnapshot, isFalse);
  });

  test('explicit terminal backend result clears provider access', () {
    final result = resolveSubscriptionSnapshot(
      current: provider(),
      incoming: SubscriptionStatus.free,
      verified: provider(),
      explicitTerminal: true,
      now: now,
    );

    expect(result.status.plan, UserPlan.free);
    expect(result.retainVerifiedSnapshot, isFalse);
    expect(result.shouldReconcile, isFalse);
  });

  test('expired verified snapshot cannot preserve Pro', () {
    final result = resolveSubscriptionSnapshot(
      current: trial,
      incoming: SubscriptionStatus.free,
      verified: provider(expiryDays: -1),
      now: now,
    );

    expect(result.status.plan, UserPlan.free);
  });

  test(
    'UID-scoped verified snapshots reject another account and old contract',
    () {
      final entitlement = {
        'entitlementContractVersion': verifiedEntitlementContractVersion,
        'plan': 'pro',
        'source': 'app_store',
        'billingPeriod': 'yearly',
        'expiresAt': now.add(const Duration(days: 30)).toIso8601String(),
        'renewalState': 'unknown',
        'subscriptionState': 'ACTIVE',
      };
      final snapshot = VerifiedEntitlementSnapshot.fromBackend(
        uid: 'uid-a',
        data: entitlement,
        verifiedAt: now,
      );

      expect(snapshot, isNotNull);
      expect(
        VerifiedEntitlementSnapshot.fromJson(
          snapshot!.toJson(),
          expectedUid: 'uid-a',
          now: now,
        ),
        isNotNull,
      );
      expect(
        VerifiedEntitlementSnapshot.fromJson(
          snapshot.toJson(),
          expectedUid: 'uid-b',
          now: now,
        ),
        isNull,
      );
      expect(
        VerifiedEntitlementSnapshot.fromBackend(
          uid: 'uid-a',
          data: {...entitlement}..remove('entitlementContractVersion'),
        ),
        isNull,
      );
    },
  );
}
