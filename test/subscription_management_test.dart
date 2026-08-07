import 'package:better_keep/services/monetization/subscription_management.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const platforms = SubscriptionManagementPlatform.values;

  test('Razorpay management always uses the direct cancellation API', () {
    for (final platform in platforms) {
      final target = resolveSubscriptionManagementTarget(
        purchasePlatform: 'razorpay',
        currentPlatform: platform,
      );
      expect(target.action, SubscriptionManagementAction.razorpayApi);
      expect(target.url, isNull);
    }
  });

  test('App Store management uses StoreKit only on iOS', () {
    for (final platform in platforms) {
      final target = resolveSubscriptionManagementTarget(
        purchasePlatform: 'app_store',
        currentPlatform: platform,
      );
      final supportsStoreKit = platform == SubscriptionManagementPlatform.ios;
      expect(
        target.action,
        supportsStoreKit
            ? SubscriptionManagementAction.appStoreNative
            : SubscriptionManagementAction.externalUrl,
      );
      expect(target.url, appleSubscriptionsUrl);
    }
  });

  test('Play Store management always opens Google Play', () {
    for (final platform in platforms) {
      final target = resolveSubscriptionManagementTarget(
        purchasePlatform: 'play_store',
        currentPlatform: platform,
      );
      expect(target.action, SubscriptionManagementAction.externalUrl);
      expect(target.url, googlePlaySubscriptionsUrl);
    }
  });

  test('unknown and legacy providers direct the user to support', () {
    for (final provider in <String?>[null, '', 'trial', 'legacy']) {
      for (final platform in platforms) {
        final target = resolveSubscriptionManagementTarget(
          purchasePlatform: provider,
          currentPlatform: platform,
        );
        expect(target.action, SubscriptionManagementAction.contactSupport);
        expect(target.url, isNull);
      }
    }
  });

  test('store destinations never contain account identifiers', () {
    for (final url in [appleSubscriptionsUrl, googlePlaySubscriptionsUrl]) {
      expect(Uri.parse(url).queryParameters, isEmpty);
    }
  });
}
