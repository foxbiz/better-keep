import 'package:better_keep/services/monetization/google_play_product_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

void main() {
  group('Play subscription replacement', () {
    GooglePlayPurchaseDetails? select(
      List<GooglePlayPurchaseDetails> purchases, {
      String from = 'better_keep_lite',
      String to = 'better_keep_pro',
    }) => selectGooglePlayReplacementPurchase(
      purchases,
      currentProductId: from,
      targetProductId: to,
      uid: 'owner',
    );

    test('uses the existing acknowledged token in either tier direction', () {
      final lite = _purchase('better_keep_lite');
      final pro = _purchase('better_keep_pro');
      expect(select([lite]), same(lite));
      expect(
        select([pro], from: 'better_keep_pro', to: 'better_keep_lite'),
        same(pro),
      );
    });

    test('rejects missing, ambiguous, pending, foreign and unacknowledged purchases', () {
      final lite = _purchase('better_keep_lite');
      for (final purchases in <List<GooglePlayPurchaseDetails>>[
        [],
        [lite, lite],
        [lite, _purchase('better_keep_pro')],
        [_purchase('better_keep_pro')],
        [_purchase('better_keep_lite', owner: 'other')],
        [_purchase('better_keep_lite', acknowledged: false)],
        [_purchase('better_keep_lite', pending: true)],
        [_purchase('better_keep_lite', token: '')],
      ]) {
        expect(select(purchases), isNull);
      }
      expect(select([lite], to: 'better_keep_lite'), isNull);
    });
  });
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

GooglePlayPurchaseDetails _purchase(
  String product, {
  String owner = 'owner',
  bool acknowledged = true,
  bool pending = false,
  String token = 'verified-by-backend-later',
}) => GooglePlayPurchaseDetails.fromPurchase(
  PurchaseWrapper(
    orderId: 'test-order',
    packageName: 'io.foxbiz.better_keep',
    purchaseTime: 1,
    purchaseToken: token,
    signature: '',
    products: [product],
    isAutoRenewing: true,
    originalJson: '{}',
    isAcknowledged: acknowledged,
    purchaseState: pending
        ? PurchaseStateWrapper.pending
        : PurchaseStateWrapper.purchased,
    obfuscatedAccountId: owner,
  ),
).single;

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
