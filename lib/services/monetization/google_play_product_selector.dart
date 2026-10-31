import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// Selects a replacement source from a fresh Play query. The caller must still
/// verify its token with the backend before opening the replacement checkout.
GooglePlayPurchaseDetails? selectGooglePlayReplacementPurchase(
  Iterable<GooglePlayPurchaseDetails> purchases, {
  required String currentProductId,
  required String targetProductId,
  required String uid,
}) {
  if (currentProductId == targetProductId) return null;
  final relevant = purchases
      .where(
        (purchase) =>
            purchase.productID == currentProductId ||
            purchase.productID == targetProductId,
      )
      .toList();
  // Multiple purchases, a pending target, or an already owned target require
  // reconciliation, never an additional parallel subscription.
  if (relevant.length != 1) return null;
  final purchase = relevant.single;
  final details = purchase.billingClientPurchase;
  if (purchase.productID != currentProductId ||
      purchase.status != PurchaseStatus.purchased ||
      !details.isAcknowledged ||
      details.pendingPurchaseUpdate != null ||
      details.purchaseToken.isEmpty ||
      (details.obfuscatedAccountId != null &&
          details.obfuscatedAccountId != uid)) {
    return null;
  }
  return purchase;
}

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
