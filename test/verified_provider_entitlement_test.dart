import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final future = DateTime.now().add(const Duration(days: 30)).toIso8601String();
  final past = DateTime.now()
      .subtract(const Duration(days: 1))
      .toIso8601String();

  test('accepts active provider entitlements, including canceled-active', () {
    for (final source in ['play_store', 'app_store', 'razorpay']) {
      final status = parseVerifiedProviderEntitlement({
        'entitlementContractVersion': verifiedEntitlementContractVersion,
        'plan': 'pro',
        'source': source,
        'billingPeriod': 'yearly',
        'expiresAt': future,
        'renewalState': 'notRenewing',
        'subscriptionState': 'CANCELED',
        'willAutoRenew': false,
      });

      expect(status, isNotNull, reason: source);
      expect(status!.isActiveProviderEntitlement, isTrue, reason: source);
      expect(status.willAutoRenew, isFalse, reason: source);
      expect(status.isCancelledButActive, isTrue, reason: source);
    }
  });

  test('rejects trial, free, expired, and unknown entitlement payloads', () {
    final rejected = <Map<String, dynamic>?>[
      null,
      {'plan': 'pro', 'source': 'trial', 'expiresAt': future},
      {'plan': 'free', 'source': 'play_store', 'expiresAt': future},
      {'plan': 'pro', 'source': 'play_store', 'expiresAt': past},
      {'plan': 'pro', 'source': 'unknown', 'expiresAt': future},
      {'plan': 'pro', 'source': 'play_store'},
      {
        'plan': 'pro',
        'source': 'play_store',
        'billingPeriod': 'yearly',
        'expiresAt': future,
        'subscriptionState': 'ACTIVE',
        'renewalState': 'unknown',
      },
    ];

    for (final payload in rejected) {
      expect(parseVerifiedProviderEntitlement(payload), isNull);
    }
  });

  test('canonical source overrides a stale trial platform alias', () {
    final status = parseVerifiedProviderEntitlement({
      'entitlementContractVersion': verifiedEntitlementContractVersion,
      'plan': 'pro',
      'source': 'play_store',
      'purchasePlatform': 'trial',
      'billingPeriod': 'yearly',
      'expiresAt': future,
      'renewalState': 'renewing',
      'subscriptionState': 'SUBSCRIPTION_STATE_ACTIVE',
      'willAutoRenew': true,
    });

    expect(status, isNotNull);
    expect(status!.purchasePlatform, 'play_store');
    expect(status.isActiveProviderEntitlement, isTrue);
  });

  test('unknown renewal remains active without being labelled cancelled', () {
    final status = parseVerifiedProviderEntitlement({
      'entitlementContractVersion': verifiedEntitlementContractVersion,
      'plan': 'pro',
      'source': 'play_store',
      'billingPeriod': 'yearly',
      'expiresAt': future,
      'renewalState': 'unknown',
      'subscriptionState': 'SUBSCRIPTION_STATE_ACTIVE',
      'willAutoRenew': null,
    });

    expect(status, isNotNull);
    expect(status!.renewalState, RenewalState.unknown);
    expect(status.isActiveProviderEntitlement, isTrue);
    expect(status.isCancelledButActive, isFalse);
  });
}
