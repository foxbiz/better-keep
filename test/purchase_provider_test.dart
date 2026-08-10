import 'package:better_keep/services/monetization/purchase_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolvePurchaseProvider', () {
    test('uses Razorpay for web regardless of browser host platform', () {
      for (final platform in TargetPlatform.values) {
        expect(
          resolvePurchaseProvider(isWeb: true, platform: platform),
          PurchaseProvider.razorpay,
          reason: platform.name,
        );
      }
    });

    test('routes native platforms by their app-store policy', () {
      const expected = <TargetPlatform, PurchaseProvider>{
        TargetPlatform.android: PurchaseProvider.googlePlay,
        TargetPlatform.iOS: PurchaseProvider.appStore,
        TargetPlatform.macOS: PurchaseProvider.appStore,
        TargetPlatform.windows: PurchaseProvider.razorpay,
        TargetPlatform.linux: PurchaseProvider.razorpay,
        TargetPlatform.fuchsia: PurchaseProvider.unavailable,
      };

      for (final entry in expected.entries) {
        expect(
          resolvePurchaseProvider(isWeb: false, platform: entry.key),
          entry.value,
          reason: entry.key.name,
        );
      }
    });

    test('Android never changes provider with store readiness', () {
      for (final readiness in StoreReadiness.values) {
        expect(
          resolvePurchaseProvider(
            isWeb: false,
            platform: TargetPlatform.android,
          ),
          PurchaseProvider.googlePlay,
          reason: readiness.name,
        );
      }
    });
  });
}
