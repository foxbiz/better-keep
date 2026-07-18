import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// Finds the Google Play product variant associated with [basePlanId].
///
/// Google Play exposes each subscription offer as a separate
/// [GooglePlayProductDetails] whose [GooglePlayProductDetails.subscriptionIndex]
/// points into the shared offer list.
GooglePlayProductDetails? selectGooglePlayProductForBasePlan(
  Iterable<ProductDetails> products, {
  required String productId,
  required String basePlanId,
}) {
  for (final product in products) {
    if (product is! GooglePlayProductDetails || product.id != productId) {
      continue;
    }

    final offers = product.productDetails.subscriptionOfferDetails;
    final subscriptionIndex = product.subscriptionIndex;
    if (offers == null ||
        subscriptionIndex == null ||
        subscriptionIndex < 0 ||
        subscriptionIndex >= offers.length) {
      continue;
    }

    if (offers[subscriptionIndex].basePlanId == basePlanId) {
      return product;
    }
  }

  return null;
}
