import 'package:better_keep/services/monetization/google_play_product_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

void main() {
  group('selectGooglePlayProductForBasePlan', () {
    test('selects products at the first and last offer indexes', () {
      final products = _subscriptionProducts();

      final monthly = selectGooglePlayProductForBasePlan(
        products,
        productId: 'better_keep_pro',
        basePlanId: 'pro-monthly',
      );
      final yearly = selectGooglePlayProductForBasePlan(
        products,
        productId: 'better_keep_pro',
        basePlanId: 'pro-yearly',
      );

      expect(monthly, same(products.first));
      expect(yearly, same(products.last));
      expect(monthly?.subscriptionIndex, 0);
      expect(yearly?.subscriptionIndex, 1);
    });

    test('returns null when the base plan is missing', () {
      final selected = selectGooglePlayProductForBasePlan(
        _subscriptionProducts(),
        productId: 'better_keep_pro',
        basePlanId: 'pro-lifetime',
      );

      expect(selected, isNull);
    });

    test('returns null when the product ID does not match', () {
      final selected = selectGooglePlayProductForBasePlan(
        _subscriptionProducts(),
        productId: 'another_product',
        basePlanId: 'pro-monthly',
      );

      expect(selected, isNull);
    });

    test('ignores products without a subscription offer index', () {
      final selected = selectGooglePlayProductForBasePlan(
        [_oneTimeProduct()],
        productId: 'better_keep_pro',
        basePlanId: 'pro-monthly',
      );

      expect(selected, isNull);
    });
  });
}

List<GooglePlayProductDetails> _subscriptionProducts() {
  const pricingPhase = PricingPhaseWrapper(
    billingCycleCount: 0,
    billingPeriod: 'P1M',
    formattedPrice: r'$2.99',
    priceAmountMicros: 2990000,
    priceCurrencyCode: 'USD',
    recurrenceMode: RecurrenceMode.infiniteRecurring,
  );
  const details = ProductDetailsWrapper(
    description: 'Better Keep Pro',
    name: 'Better Keep Pro',
    productId: 'better_keep_pro',
    productType: ProductType.subs,
    title: 'Better Keep Pro',
    subscriptionOfferDetails: [
      SubscriptionOfferDetailsWrapper(
        basePlanId: 'pro-monthly',
        offerTags: [],
        offerIdToken: 'monthly-token',
        pricingPhases: [pricingPhase],
      ),
      SubscriptionOfferDetailsWrapper(
        basePlanId: 'pro-yearly',
        offerTags: [],
        offerIdToken: 'yearly-token',
        pricingPhases: [pricingPhase],
      ),
    ],
  );

  return GooglePlayProductDetails.fromProductDetails(details);
}

GooglePlayProductDetails _oneTimeProduct() {
  const offer = OneTimePurchaseOfferDetailsWrapper(
    formattedPrice: r'$9.99',
    priceAmountMicros: 9990000,
    priceCurrencyCode: 'USD',
  );
  const details = ProductDetailsWrapper(
    description: 'One-time purchase',
    name: 'One-time purchase',
    oneTimePurchaseOfferDetails: offer,
    oneTimePurchaseOfferDetailsList: [offer],
    productId: 'better_keep_pro',
    productType: ProductType.inapp,
    title: 'One-time purchase',
  );

  return GooglePlayProductDetails.fromProductDetails(details).single;
}
