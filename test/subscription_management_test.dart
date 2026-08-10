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
      expect(Uri.parse(target.url!).queryParameters, {
        'sku': 'better_keep_pro',
        'package': 'io.foxbiz.better_keep',
      });
    }
  });

  test(
    'ownership-conflict management resolves from the current native store',
    () {
      final android = resolveCurrentStoreManagementTarget(
        SubscriptionManagementPlatform.android,
      );
      expect(android.action, SubscriptionManagementAction.externalUrl);
      expect(android.url, googlePlaySubscriptionsUrl);

      final ios = resolveCurrentStoreManagementTarget(
        SubscriptionManagementPlatform.ios,
      );
      expect(ios.action, SubscriptionManagementAction.appStoreNative);
      expect(ios.url, appleSubscriptionsUrl);
    },
  );

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
    expect(Uri.parse(appleSubscriptionsUrl).queryParameters, isEmpty);
    final playParameters = Uri.parse(
      googlePlaySubscriptionsUrl,
    ).queryParameters;
    expect(playParameters.keys, unorderedEquals(['sku', 'package']));
  });
}
