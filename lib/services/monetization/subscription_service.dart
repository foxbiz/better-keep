import 'dart:async';
import 'dart:io';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:url_launcher/url_launcher.dart';

/// Product IDs for in-app purchases
class ProductIds {
  /// Subscription product ID (same for both plans)
  static const String proSubscription = 'better_keep_pro';

  /// Base plan IDs (used with the subscription product)
  static const String basePlanMonthly = 'pro-monthly';
  static const String basePlanYearly = 'pro-yearly';

  static const List<String> subscriptions = [proSubscription];
  static const List<String> all = [...subscriptions];
}

/// Exception thrown when product pricing is not available
class ProductNotAvailableException implements Exception {
  final String message;
  ProductNotAvailableException(this.message);

  @override
  String toString() => message;
}

/// Result of checking for existing subscription
class ExistingSubscriptionResult {
  final bool hasSubscription;
  final bool restored;
  final Map<String, dynamic>? subscription;

  ExistingSubscriptionResult({
    required this.hasSubscription,
    this.restored = false,
    this.subscription,
  });
}

/// Result of purchase verification
class VerifyPurchaseResult {
  final bool valid;
  final String? error;
  final bool isLinkedToOtherAccount;
  final Map<String, dynamic>? subscription;

  VerifyPurchaseResult({
    required this.valid,
    this.error,
    this.isLinkedToOtherAccount = false,
    this.subscription,
  });
}

/// Handles subscription purchases across platforms.
///
/// - Mobile (iOS/Android): Uses in_app_purchase plugin
/// - Web/Desktop: Redirects to external checkout page
class SubscriptionService {
  SubscriptionService._internal();

  static final SubscriptionService _instance = SubscriptionService._internal();
  static SubscriptionService get instance => _instance;

  // In-app purchase
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  List<ProductDetails> _products = [];
  bool _iapAvailable = false;

  // Loading state
  final ValueNotifier<bool> isLoading = ValueNotifier(false);

  // Last purchase error (for showing to user)
  String? _lastPurchaseError;

  // Completer for restore purchases flow
  Completer<bool>? _restoreCompleter;
  bool _restoredSubscriptionFound = false;

  /// Get last purchase error message
  String? get lastPurchaseError => _lastPurchaseError;

  /// Clear last purchase error
  void clearLastPurchaseError() => _lastPurchaseError = null;

  /// Whether purchases are available on this platform
  bool get canMakePurchases {
    if (kIsWeb) return true; // Web uses Razorpay
    return Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  /// Whether this platform uses Razorpay (web, Windows, Linux, or Android when IAP unavailable)
  bool get usesRazorpay {
    if (kIsWeb) return true;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return true;
    // Fallback to Razorpay on Android when Google Play billing is not available
    // This happens on devices without Google Play Services (e.g., Huawei, custom ROMs)
    if (!kIsWeb && Platform.isAndroid && !_iapAvailable) return true;
    return false;
  }

  /// Get available products
  List<ProductDetails> get products => _products;

  /// Check if products are loaded
  bool get hasProducts => _products.isNotEmpty;

  /// Get debug info for troubleshooting
  String get debugInfo {
    return '''
IAP Available: $_iapAvailable
Products loaded: ${_products.length}
Product IDs: ${_products.map((p) => p.id).toList()}
Expected IDs: ${ProductIds.all}
''';
  }

  /// Initialize the subscription service
  Future<void> init() async {
    AppLogger.log('SubscriptionService: Initializing...');

    if (kIsWeb) {
      AppLogger.log(
        'SubscriptionService: Web platform, using external checkout',
      );
      return;
    }

    if (Platform.isIOS || Platform.isAndroid) {
      await _initInAppPurchase();
    } else {
      AppLogger.log(
        'SubscriptionService: Desktop platform, using external checkout',
      );
    }
  }

  /// Initialize in-app purchases for mobile
  Future<void> _initInAppPurchase() async {
    _iapAvailable = await _iap.isAvailable();

    if (!_iapAvailable) {
      AppLogger.log('SubscriptionService: In-app purchases not available');
      if (Platform.isAndroid) {
        AppLogger.log(
          'SubscriptionService: Will use Razorpay as fallback for payments',
        );
      }
      return;
    }

    // Listen to purchase updates
    _purchaseSubscription = _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _purchaseSubscription?.cancel(),
      onError: (error) {
        AppLogger.error('SubscriptionService: Purchase stream error', error);
      },
    );

    // Load products
    await _loadProducts();

    // Check for any pending purchases that need to be processed
    // This helps recover subscription state if the app was killed during purchase
    await _checkPendingPurchases();

    AppLogger.log('SubscriptionService: In-app purchases initialized');
  }

  /// Load available products from store
  Future<void> _loadProducts({int retryCount = 0}) async {
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 2);

    try {
      AppLogger.log(
        'SubscriptionService: Querying products: ${ProductIds.all}${retryCount > 0 ? ' (retry $retryCount)' : ''}',
      );

      final response = await _iap.queryProductDetails(ProductIds.all.toSet());

      if (response.notFoundIDs.isNotEmpty) {
        AppLogger.log(
          'SubscriptionService: Products not found: ${response.notFoundIDs}',
        );
      }

      if (response.error != null) {
        AppLogger.error('SubscriptionService: Query error', response.error);
      }

      _products = response.productDetails;
      AppLogger.log(
        'SubscriptionService: Loaded ${_products.length} products: ${_products.map((p) => p.id).toList()}',
      );

      // Count subscription variants (for Google Play, each base plan is a separate product)
      if (Platform.isAndroid) {
        final proProducts = _products
            .where((p) => p.id == ProductIds.proSubscription)
            .toList();
        AppLogger.log(
          'SubscriptionService: Found ${proProducts.length} variants of ${ProductIds.proSubscription}',
        );
        if (proProducts.length < 2) {
          AppLogger.log(
            'SubscriptionService: Warning - Expected 2 variants (monthly + yearly), got ${proProducts.length}',
          );
        }
      }

      // If no products found and we have retries left, try again
      if (_products.isEmpty && retryCount < maxRetries) {
        AppLogger.log(
          'SubscriptionService: No products loaded, retrying in ${retryDelay.inSeconds}s...',
        );
        await Future.delayed(retryDelay);
        return _loadProducts(retryCount: retryCount + 1);
      }

      // Log detailed product info for debugging
      for (final product in _products) {
        AppLogger.log(
          'SubscriptionService: Product "${product.id}" - '
          'title: ${product.title}, '
          'price: ${product.price}, '
          'rawPrice: ${product.rawPrice}, '
          'currencyCode: ${product.currencyCode}, '
          'currencySymbol: ${product.currencySymbol}',
        );

        // Log Android-specific subscription details
        if (Platform.isAndroid && product is GooglePlayProductDetails) {
          final gpProduct = product;
          AppLogger.log(
            'SubscriptionService: Google Play details for "${product.id}" - '
            'productType: ${gpProduct.productDetails.productType}, '
            'subscriptionOfferDetails: ${gpProduct.productDetails.subscriptionOfferDetails?.length ?? 0} offers',
          );

          // Log each subscription offer (base plan)
          final offers = gpProduct.productDetails.subscriptionOfferDetails;
          if (offers != null) {
            for (final offer in offers) {
              AppLogger.log(
                'SubscriptionService: Offer - '
                'basePlanId: ${offer.basePlanId}, '
                'offerId: ${offer.offerId}',
              );
              for (final phase in offer.pricingPhases) {
                AppLogger.log(
                  'SubscriptionService:   Phase - '
                  'price: ${phase.formattedPrice}, '
                  'priceAmountMicros: ${phase.priceAmountMicros}, '
                  'billingPeriod: ${phase.billingPeriod}, '
                  'billingCycleCount: ${phase.billingCycleCount}',
                );
              }
            }
          }
        }
      }
    } catch (e) {
      AppLogger.error('SubscriptionService: Error loading products', e);

      // Retry on error
      if (retryCount < maxRetries) {
        AppLogger.log(
          'SubscriptionService: Error loading products, retrying in ${retryDelay.inSeconds}s...',
        );
        await Future.delayed(retryDelay);
        return _loadProducts(retryCount: retryCount + 1);
      }
    }
  }

  /// Reload products (call this if products weren't found initially)
  Future<void> reloadProducts() async {
    if (!_iapAvailable) {
      // Try to reinitialize if IAP wasn't available before
      _iapAvailable = await _iap.isAvailable();
      if (!_iapAvailable) return;
    }
    await _loadProducts();
  }

  /// Handle purchase updates from the store
  Future<void> _handlePurchaseUpdates(
    List<PurchaseDetails> purchaseDetailsList,
  ) async {
    for (final purchase in purchaseDetailsList) {
      AppLogger.log(
        'SubscriptionService: Purchase update - ${purchase.productID}: ${purchase.status}',
      );

      switch (purchase.status) {
        case PurchaseStatus.pending:
          isLoading.value = true;
          _lastPurchaseError = null;
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Verify and deliver the purchase
          final verifyResult = await _verifyPurchase(purchase);

          if (verifyResult.valid) {
            await _deliverPurchase(purchase);
            _lastPurchaseError = null;
            // Mark that we found a restored subscription
            if (purchase.status == PurchaseStatus.restored) {
              _restoredSubscriptionFound = true;
            }
          } else if (verifyResult.isLinkedToOtherAccount) {
            // Subscription belongs to another account
            _lastPurchaseError = verifyResult.error;
            AppLogger.log(
              'SubscriptionService: Subscription linked to another account',
            );
          } else {
            _lastPurchaseError = verifyResult.error;
          }

          // Complete the purchase
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          isLoading.value = false;
          break;

        case PurchaseStatus.error:
          // Log the technical error for debugging
          AppLogger.error(
            'SubscriptionService: Purchase error for "${purchase.productID}"',
            purchase.error,
          );
          // Set user-friendly error message
          _lastPurchaseError = _getFriendlyErrorMessage(
            purchase.error?.message,
          );
          if (purchase.pendingCompletePurchase) {
            try {
              await _iap.completePurchase(purchase);
            } catch (e) {
              AppLogger.error(
                'SubscriptionService: Error completing failed purchase',
                e,
              );
            }
          }
          isLoading.value = false;
          break;

        case PurchaseStatus.canceled:
          AppLogger.log(
            'SubscriptionService: Purchase canceled for "${purchase.productID}"',
          );
          _lastPurchaseError = null;
          if (purchase.productID.isNotEmpty &&
              purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          isLoading.value = false;
          break;
      }
    }
  }

  /// Convert technical error messages to user-friendly messages
  String _getFriendlyErrorMessage(String? technicalError) {
    if (technicalError == null) {
      return 'Something went wrong. Please try again.';
    }

    final errorLower = technicalError.toLowerCase();

    if (errorLower.contains('item not found') ||
        errorLower.contains('item unavailable') ||
        errorLower.contains('product not found')) {
      return 'This subscription is not available yet. Please try again later.';
    }

    if (errorLower.contains('network') ||
        errorLower.contains('connection') ||
        errorLower.contains('internet')) {
      return 'Please check your internet connection and try again.';
    }

    if (errorLower.contains('cancelled') || errorLower.contains('canceled')) {
      return 'Purchase was cancelled.';
    }

    if (errorLower.contains('already owned') ||
        errorLower.contains('already purchased')) {
      return 'You already have this subscription. Try restoring purchases.';
    }

    if (errorLower.contains('payment') ||
        errorLower.contains('billing') ||
        errorLower.contains('card')) {
      return 'Payment failed. Please check your payment method and try again.';
    }

    if (errorLower.contains('pending')) {
      return 'Your purchase is pending. Please check back later.';
    }

    // Default user-friendly message
    return 'Purchase failed. Please try again or contact support.';
  }

  /// Check for pending purchases that may not have been processed
  /// This is called on init to recover subscription state
  Future<void> _checkPendingPurchases() async {
    try {
      // On Android, we can restore purchases to check for active subscriptions
      if (Platform.isAndroid) {
        AppLogger.log('SubscriptionService: Checking for pending purchases...');
        await _iap.restorePurchases();
      }
    } catch (e) {
      AppLogger.log(
        'SubscriptionService: Error checking pending purchases: $e',
      );
    }
  }

  /// Restore purchases and wait for completion
  /// Returns true if an active subscription was restored
  Future<bool> restoreAndWaitForPurchases() async {
    if (!_iapAvailable) return false;

    try {
      AppLogger.log('SubscriptionService: Restoring purchases from store...');
      isLoading.value = true;
      _restoredSubscriptionFound = false;
      _restoreCompleter = Completer<bool>();

      // Start the restore
      await _iap.restorePurchases();

      // Wait for a short time to allow purchase updates to come through
      // The purchase stream will set _restoredSubscriptionFound if a subscription is found
      await Future.delayed(const Duration(seconds: 3));

      // Complete the completer if not already done
      if (!_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(_restoredSubscriptionFound);
      }

      final result = await _restoreCompleter!.future;
      AppLogger.log(
        'SubscriptionService: Restore completed, subscription found: $result',
      );
      return result;
    } catch (e) {
      AppLogger.log('SubscriptionService: Error restoring purchases: $e');
      return false;
    } finally {
      isLoading.value = false;
      _restoreCompleter = null;
    }
  }

  /// Verify purchase with backend
  ///
  /// This calls the Cloud Function which:
  /// 1. Verifies the purchase with Google Play API
  /// 2. Ensures the subscription isn't linked to another account
  /// 3. Links the subscription to this user's account
  Future<VerifyPurchaseResult> _verifyPurchase(PurchaseDetails purchase) async {
    try {
      final user = AuthService.currentUser;
      if (user == null) {
        return VerifyPurchaseResult(valid: false, error: 'User not signed in');
      }

      // Call Cloud Function to verify receipt
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('verifyPurchase').call({
        'productId': purchase.productID,
        'purchaseToken': purchase.verificationData.serverVerificationData,
        'source': Platform.isIOS ? 'app_store' : 'play_store',
      });

      // Convert from Map<Object?, Object?> to Map<String, dynamic>
      final data = Map<String, dynamic>.from(result.data as Map);

      if (data['valid'] == true) {
        return VerifyPurchaseResult(
          valid: true,
          subscription: data['subscription'] != null
              ? Map<String, dynamic>.from(data['subscription'] as Map)
              : null,
        );
      } else {
        return VerifyPurchaseResult(
          valid: false,
          error: data['message'] as String? ?? 'Verification failed',
        );
      }
    } on FirebaseFunctionsException catch (e) {
      AppLogger.error('SubscriptionService: Verification error', e);

      // Handle specific error codes
      if (e.code == 'already-exists') {
        return VerifyPurchaseResult(
          valid: false,
          error:
              e.message ??
              'This subscription is already linked to another account. Please contact support.',
          isLinkedToOtherAccount: true,
        );
      }

      // For server errors (permission issues, etc.), don't grant access
      // The user can try restoring purchases later once the issue is resolved
      return VerifyPurchaseResult(
        valid: false,
        error:
            'Unable to verify purchase. Please try restoring purchases later or contact support.',
      );
    } catch (e) {
      AppLogger.error('SubscriptionService: Verification error', e);
      // In case of verification failure, don't grant access
      // The user should try again or restore purchases later
      return VerifyPurchaseResult(
        valid: false,
        error: 'Verification failed. Please try again or contact support.',
      );
    }
  }

  /// Deliver the purchase (update user subscription)
  Future<void> _deliverPurchase(PurchaseDetails purchase) async {
    try {
      final user = AuthService.currentUser;
      if (user == null) return;

      UserPlan plan;
      BillingPeriod billingPeriod;
      DateTime expiresAt;

      // Handle Pro subscription (same product ID, different base plans)
      if (purchase.productID == ProductIds.proSubscription) {
        plan = UserPlan.pro;
        // Determine billing period from purchase details or default to monthly
        // Note: For Google Play, base plan info may be in purchase.verificationData
        // For now, we'll rely on backend webhook to set the correct period
        billingPeriod = BillingPeriod.monthly;
        expiresAt = DateTime.now().add(const Duration(days: 30));
      } else {
        return;
      }

      // Update Firestore
      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      await db
          .collection('users')
          .doc(user.uid)
          .collection('subscription')
          .doc('status')
          .set({
            'plan': plan.toStorageString(),
            'billingPeriod': billingPeriod.name,
            'expiresAt': Timestamp.fromDate(expiresAt),
            'willAutoRenew': true,
            'purchaseToken': purchase.verificationData.serverVerificationData,
            'source': Platform.isIOS ? 'app_store' : 'play_store',
            'updatedAt': FieldValue.serverTimestamp(),
          });

      // Refresh local subscription
      await PlanService.instance.refreshSubscription();

      AppLogger.log(
        'SubscriptionService: Delivered purchase for ${purchase.productID}',
      );
    } catch (e) {
      AppLogger.error('SubscriptionService: Error delivering purchase', e);
    }
  }

  /// Get display price for a base plan from IAP or Razorpay.
  /// Throws [ProductNotAvailableException] if product is not loaded.
  String getDisplayPrice({required bool yearly}) {
    // For Razorpay platforms (web, Windows, Linux), return fixed INR prices
    if (usesRazorpay) {
      // Razorpay prices: ₹230/month, ₹1625/year
      return yearly ? '₹1,625' : '₹230';
    }

    // Try to get price from loaded products
    final product = _products.cast<ProductDetails?>().firstWhere(
      (p) => p?.id == ProductIds.proSubscription,
      orElse: () => null,
    );

    if (product == null) {
      throw ProductNotAvailableException(
        'Product not loaded. Please wait or try again.',
      );
    }

    // For Android subscriptions with base plans, extract price from subscription offers
    if (Platform.isAndroid && product is GooglePlayProductDetails) {
      final basePlanId = yearly
          ? ProductIds.basePlanYearly
          : ProductIds.basePlanMonthly;

      final offers = product.productDetails.subscriptionOfferDetails;
      if (offers != null) {
        for (final offer in offers) {
          if (offer.basePlanId == basePlanId) {
            // Get the first pricing phase (recurring price)
            final phases = offer.pricingPhases;
            if (phases.isNotEmpty) {
              // Find the recurring phase (not a free trial)
              for (final phase in phases) {
                if (phase.priceAmountMicros > 0) {
                  AppLogger.log(
                    'SubscriptionService: Price for $basePlanId: ${phase.formattedPrice}',
                  );
                  return phase.formattedPrice;
                }
              }
            }
          }
        }
      }

      // If we couldn't find the specific base plan, throw error
      throw ProductNotAvailableException(
        'Base plan "$basePlanId" not found in subscription offers.',
      );
    }

    // For iOS or fallback, use the default price
    return product.price;
  }

  /// Get display price safely, returns null if not available
  String? getDisplayPriceSafe({required bool yearly}) {
    try {
      return getDisplayPrice(yearly: yearly);
    } catch (_) {
      return null;
    }
  }

  /// Get raw price values for calculating savings.
  /// Throws [ProductNotAvailableException] if product is not loaded.
  (double, double) getRawPrices() {
    // For Razorpay platforms (web, Windows, Linux), return fixed INR prices
    if (usesRazorpay) {
      // Razorpay prices: ₹230/month, ₹1625/year
      // Monthly * 12 = ₹2760, Yearly = ₹1625 (save ₹1135 = ~41%)
      return (230.0, 1625.0);
    }

    final product = _products.cast<ProductDetails?>().firstWhere(
      (p) => p?.id == ProductIds.proSubscription,
      orElse: () => null,
    );

    if (product == null) {
      throw ProductNotAvailableException(
        'Product not loaded. Please wait or try again.',
      );
    }

    // For Android subscriptions with base plans, extract prices from subscription offers
    if (Platform.isAndroid && product is GooglePlayProductDetails) {
      double? monthlyPrice;
      double? yearlyPrice;

      final offers = product.productDetails.subscriptionOfferDetails;
      if (offers != null) {
        for (final offer in offers) {
          final phases = offer.pricingPhases;
          if (phases.isNotEmpty) {
            // Find the recurring phase (not a free trial)
            for (final phase in phases) {
              if (phase.priceAmountMicros > 0) {
                final priceInCurrency = phase.priceAmountMicros / 1000000.0;
                if (offer.basePlanId == ProductIds.basePlanMonthly) {
                  monthlyPrice = priceInCurrency;
                } else if (offer.basePlanId == ProductIds.basePlanYearly) {
                  yearlyPrice = priceInCurrency;
                }
                break; // Use first non-zero price phase
              }
            }
          }
        }
      }

      if (monthlyPrice != null && yearlyPrice != null) {
        AppLogger.log(
          'SubscriptionService: Raw prices - monthly: $monthlyPrice, yearly: $yearlyPrice',
        );
        return (monthlyPrice, yearlyPrice);
      }

      throw ProductNotAvailableException(
        'Could not extract pricing from subscription offers.',
      );
    }

    // For iOS or fallback
    return (product.rawPrice, product.rawPrice);
  }

  /// Get raw prices safely, returns null if not available
  (double, double)? getRawPricesSafe() {
    try {
      return getRawPrices();
    } catch (_) {
      return null;
    }
  }

  /// Calculate save percentage for yearly vs monthly.
  /// Returns 0 if prices are not available.
  int calculateSavePercentage() {
    final prices = getRawPricesSafe();
    if (prices == null) return 0;

    final (monthlyPrice, yearlyPrice) = prices;
    final monthlyTotal = monthlyPrice * 12;
    if (monthlyTotal <= 0) return 0;

    final savings = ((monthlyTotal - yearlyPrice) / monthlyTotal * 100).round();
    return savings.clamp(0, 99);
  }

  /// Purchase a subscription (Pro monthly or yearly)
  ///
  /// Before initiating a new purchase, this method:
  /// 1. Restores purchases from Google Play to check for active subscriptions
  /// 2. If an active subscription is found and verified, returns success
  /// 3. Only shows checkout dialog if no active subscription exists
  ///
  /// For web/desktop: Uses Razorpay payment gateway
  /// For mobile: Uses in_app_purchase plugin
  Future<PurchaseResult> purchaseSubscription({required bool yearly}) async {
    final basePlanId = yearly
        ? ProductIds.basePlanYearly
        : ProductIds.basePlanMonthly;

    final user = AuthService.currentUser;
    if (user == null) {
      return PurchaseResult.failed('Please sign in first');
    }

    // For web/desktop, use Razorpay
    if (usesRazorpay) {
      return _purchaseWithRazorpay(yearly: yearly);
    }

    // First, try to restore purchases from the store (Google Play / App Store)
    // This checks if user already has an active subscription in the store
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      try {
        AppLogger.log(
          'SubscriptionService: Checking for existing subscription in store...',
        );
        final restored = await restoreAndWaitForPurchases();

        if (restored) {
          AppLogger.log(
            'SubscriptionService: Active subscription found and restored',
          );
          return PurchaseResult.success('Your subscription has been restored!');
        }
      } catch (e) {
        AppLogger.log('SubscriptionService: Error restoring purchases: $e');
        // Continue with purchase if restore fails
      }
    }

    // Also check Firebase for existing subscription (backup check)
    try {
      isLoading.value = true;
      final existingCheck = await checkExistingSubscription();

      if (existingCheck.hasSubscription) {
        isLoading.value = false;
        if (existingCheck.restored) {
          return PurchaseResult.success('Your subscription has been restored!');
        }
        return PurchaseResult.success(
          'You already have an active subscription.',
        );
      }
    } catch (e) {
      AppLogger.log(
        'SubscriptionService: Error checking existing subscription: $e',
      );
      // Continue with purchase if check fails
    } finally {
      isLoading.value = false;
    }

    return _purchaseWithIAP(ProductIds.proSubscription, basePlanId: basePlanId);
  }

  /// Purchase subscription using Razorpay (for web/desktop)
  Future<PurchaseResult> _purchaseWithRazorpay({required bool yearly}) async {
    final razorpayService = RazorpayService.instance;

    AppLogger.log('SubscriptionService: Using Razorpay for subscription');
    isLoading.value = true;

    try {
      final result = await razorpayService.purchaseSubscription(yearly: yearly);

      if (result.success) {
        return PurchaseResult.success('Subscription activated successfully!');
      } else if (result.cancelled) {
        return PurchaseResult.failed('Purchase was cancelled');
      } else {
        _lastPurchaseError = result.error;
        return PurchaseResult.failed(result.error ?? 'Payment failed');
      }
    } finally {
      isLoading.value = false;
    }
  }

  /// Check if user has an existing subscription (server-side verification)
  Future<ExistingSubscriptionResult> checkExistingSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return ExistingSubscriptionResult(hasSubscription: false);
    }

    try {
      final functions = FirebaseFunctions.instance;
      final result = await functions
          .httpsCallable('checkExistingSubscription')
          .call({});

      // Convert from Map<Object?, Object?> to Map<String, dynamic>
      final data = Map<String, dynamic>.from(result.data as Map);

      if (data['hasSubscription'] == true) {
        // Refresh local subscription status
        await PlanService.instance.refreshSubscription();

        return ExistingSubscriptionResult(
          hasSubscription: true,
          restored: data['restored'] == true,
          subscription: data['subscription'] != null
              ? Map<String, dynamic>.from(data['subscription'] as Map)
              : null,
        );
      }

      return ExistingSubscriptionResult(hasSubscription: false);
    } catch (e) {
      AppLogger.error(
        'SubscriptionService: Error checking existing subscription',
        e,
      );
      rethrow;
    }
  }

  /// Purchase using in-app purchase (iOS/Android)
  ///
  /// For Google Play subscriptions, pass the [basePlanId] to specify which
  /// base plan (monthly/yearly) to subscribe to.
  Future<PurchaseResult> _purchaseWithIAP(
    String productId, {
    String? basePlanId,
  }) async {
    if (!_iapAvailable) {
      return PurchaseResult.failed(
        'In-app purchases not available on this device',
      );
    }

    final user = AuthService.currentUser;
    if (user == null) {
      return PurchaseResult.failed('Please sign in first');
    }

    // If products are empty, try to reload them
    if (_products.isEmpty) {
      AppLogger.log('SubscriptionService: Products empty, reloading...');
      await _loadProducts();
    }

    // Find the product
    ProductDetails? product;
    try {
      product = _products.firstWhere((p) => p.id == productId);
    } catch (e) {
      // Product not found - log available products for debugging
      AppLogger.log(
        'SubscriptionService: Product "$productId" not found. Available: ${_products.map((p) => p.id).toList()}',
      );

      // Try one more time to reload products
      await _loadProducts();
      try {
        product = _products.firstWhere((p) => p.id == productId);
      } catch (_) {
        return PurchaseResult.failed(
          'This product is not available yet. Please make sure the app is updated and try again.',
        );
      }
    }

    try {
      isLoading.value = true;

      AppLogger.log(
        'SubscriptionService: Initiating purchase for $productId (basePlan: $basePlanId)',
      );
      AppLogger.log(
        'SubscriptionService: Total loaded products: ${_products.length}',
      );

      // For Google Play subscriptions with base plans, we need to find the product with the correct offer
      PurchaseParam purchaseParam;
      if (basePlanId != null &&
          Platform.isAndroid &&
          product is GooglePlayProductDetails) {
        // The in_app_purchase_android package creates separate GooglePlayProductDetails
        // for each subscription offer. We need to find the one matching our base plan.
        GooglePlayProductDetails? selectedProduct;

        // Log all products with this ID for debugging
        final matchingProducts = _products
            .where((p) => p.id == productId)
            .toList();
        AppLogger.log(
          'SubscriptionService: Found ${matchingProducts.length} products with ID "$productId"',
        );

        // Search through all loaded products to find one with matching base plan
        for (final p in _products) {
          if (p.id == productId && p is GooglePlayProductDetails) {
            final offers = p.productDetails.subscriptionOfferDetails;
            final subIndex = p.subscriptionIndex ?? 0;

            AppLogger.log(
              'SubscriptionService: Checking product - subscriptionIndex: $subIndex, '
              'offers count: ${offers?.length ?? 0}',
            );

            if (offers != null &&
                offers.isNotEmpty &&
                subIndex < offers.length) {
              final selectedOffer = offers[subIndex];
              AppLogger.log(
                'SubscriptionService: Offer at index $subIndex - basePlanId: ${selectedOffer.basePlanId}',
              );

              if (selectedOffer.basePlanId == basePlanId) {
                selectedProduct = p;
                AppLogger.log(
                  'SubscriptionService: ✓ Found matching product with basePlan "$basePlanId" at index $subIndex',
                );
                break;
              }
            }
          }
        }

        if (selectedProduct == null) {
          // Fallback: If we can't find the exact match, log available options
          AppLogger.log(
            'SubscriptionService: ✗ Could not find product with basePlan "$basePlanId"',
          );

          // Log what we have
          for (final p in _products) {
            if (p.id == productId && p is GooglePlayProductDetails) {
              final offers = p.productDetails.subscriptionOfferDetails;
              if (offers != null) {
                AppLogger.log(
                  'SubscriptionService: Available product - subscriptionIndex: ${p.subscriptionIndex}, '
                  'all basePlanIds: ${offers.map((o) => o.basePlanId).toList()}',
                );
              }
            }
          }

          // Return error instead of using wrong product
          isLoading.value = false;
          return PurchaseResult.failed(
            'Subscription plan not available. Please try again later.',
          );
        }

        purchaseParam = GooglePlayPurchaseParam(
          productDetails: selectedProduct,
          applicationUserName: user.uid,
          changeSubscriptionParam: null,
        );
        final selectedOffer = selectedProduct
            .productDetails
            .subscriptionOfferDetails?[selectedProduct.subscriptionIndex ?? 0];
        AppLogger.log(
          'SubscriptionService: Using GooglePlayPurchaseParam with '
          'productId: ${selectedProduct.id}, '
          'subscriptionIndex: ${selectedProduct.subscriptionIndex}, '
          'basePlanId: ${selectedOffer?.basePlanId}, '
          'offerId: ${selectedOffer?.offerId}',
        );
      } else {
        purchaseParam = PurchaseParam(
          productDetails: product,
          applicationUserName: user.uid,
        );
        AppLogger.log(
          'SubscriptionService: Using PurchaseParam with productId: ${product.id}',
        );
      }

      // Initiate purchase - use buyNonConsumable for subscriptions on Android/iOS
      // (The in_app_purchase plugin uses buyNonConsumable for subscriptions too)
      AppLogger.log('SubscriptionService: Calling buyNonConsumable...');
      final success = await _iap.buyNonConsumable(purchaseParam: purchaseParam);

      if (!success) {
        isLoading.value = false;
        return PurchaseResult.failed('Could not initiate purchase');
      }

      // Purchase initiated - result will come through purchase stream
      return PurchaseResult.pending('Processing purchase...');
    } catch (e) {
      isLoading.value = false;
      return PurchaseResult.failed('Purchase error: $e');
    }
  }

  /// Restore previous purchases (for mobile platforms)
  Future<RestoreResult> restorePurchases() async {
    if (usesRazorpay) {
      // For web/desktop with Razorpay, just refresh from Firebase
      await PlanService.instance.refreshSubscription();
      return RestoreResult.success('Subscription status refreshed');
    }

    if (!_iapAvailable) {
      return RestoreResult.failed('In-app purchases not available');
    }

    try {
      isLoading.value = true;
      await _iap.restorePurchases();
      // Results will come through the purchase stream
      return RestoreResult.success('Restoring purchases...');
    } catch (e) {
      isLoading.value = false;
      return RestoreResult.failed('Error restoring purchases: $e');
    }
  }

  /// Cancel subscription (redirects to platform-specific management)
  Future<CancelResult> cancelSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return CancelResult.failed('Please sign in first');
    }

    final subscriptionStatus = PlanService.instance.status;

    // For Razorpay subscriptions, cancel via API (regardless of current platform)
    if (subscriptionStatus.isRazorpaySubscription) {
      return _cancelRazorpaySubscription();
    }

    // On mobile, redirect to platform subscription management
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      Uri managementUrl;
      if (Platform.isIOS) {
        managementUrl = Uri.parse(
          'https://apps.apple.com/account/subscriptions',
        );
      } else {
        // Android - Google Play subscriptions
        managementUrl = Uri.parse(
          'https://play.google.com/store/account/subscriptions',
        );
      }

      try {
        final launched = await launchUrl(
          managementUrl,
          mode: LaunchMode.externalApplication,
        );

        if (!launched) {
          return CancelResult.failed('Could not open subscription management');
        }

        return CancelResult.pending(
          'Manage your subscription in the ${Platform.isIOS ? "App Store" : "Play Store"}',
        );
      } catch (e) {
        return CancelResult.failed('Error opening subscription management: $e');
      }
    }

    // For web/desktop, redirect to account management portal
    final manageUrl = Uri.parse(
      'https://betterkeep.app/account/manage'
      '?uid=${user.uid}'
      '&email=${Uri.encodeComponent(user.email ?? '')}',
    );

    try {
      final launched = await launchUrl(
        manageUrl,
        mode: LaunchMode.externalApplication,
      );

      if (!launched) {
        return CancelResult.failed('Could not open account management');
      }

      return CancelResult.pending('Manage your subscription in your browser');
    } catch (e) {
      return CancelResult.failed('Error opening account management: $e');
    }
  }

  /// Cancel Razorpay subscription via API
  Future<CancelResult> _cancelRazorpaySubscription() async {
    final razorpayService = RazorpayService.instance;

    try {
      isLoading.value = true;
      final success = await razorpayService.cancelSubscription();

      if (success) {
        // Refresh subscription status
        await PlanService.instance.refreshSubscription();
        return CancelResult.success('Subscription cancelled successfully');
      } else {
        return CancelResult.failed('Failed to cancel subscription');
      }
    } catch (e) {
      return CancelResult.failed('Error cancelling subscription: $e');
    } finally {
      isLoading.value = false;
    }
  }

  /// Resume a cancelled Razorpay subscription
  Future<CancelResult> resumeSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return CancelResult.failed('Please sign in first');
    }

    if (!usesRazorpay) {
      return CancelResult.failed(
        'Resume is only available for web subscriptions',
      );
    }

    final razorpayService = RazorpayService.instance;

    try {
      isLoading.value = true;
      final success = await razorpayService.resumeSubscription();

      if (success) {
        // Refresh subscription status
        await PlanService.instance.refreshSubscription();
        return CancelResult.success('Subscription resumed successfully');
      } else {
        return CancelResult.failed('Failed to resume subscription');
      }
    } catch (e) {
      return CancelResult.failed('Error resuming subscription: $e');
    } finally {
      isLoading.value = false;
    }
  }

  /// Dispose resources
  void dispose() {
    _purchaseSubscription?.cancel();
  }
}

/// Result of a purchase attempt
class PurchaseResult {
  final PurchaseResultStatus status;
  final String message;

  PurchaseResult._(this.status, this.message);

  factory PurchaseResult.success(String message) =>
      PurchaseResult._(PurchaseResultStatus.success, message);

  factory PurchaseResult.pending(String message) =>
      PurchaseResult._(PurchaseResultStatus.pending, message);

  factory PurchaseResult.failed(String message) =>
      PurchaseResult._(PurchaseResultStatus.failed, message);

  bool get isSuccess => status == PurchaseResultStatus.success;
  bool get isPending => status == PurchaseResultStatus.pending;
  bool get isFailed => status == PurchaseResultStatus.failed;
}

enum PurchaseResultStatus { success, pending, failed }

/// Result of a restore attempt
class RestoreResult {
  final bool isSuccess;
  final String message;

  RestoreResult._(this.isSuccess, this.message);

  factory RestoreResult.success(String message) =>
      RestoreResult._(true, message);

  factory RestoreResult.failed(String message) =>
      RestoreResult._(false, message);
}

/// Result of a cancellation attempt
class CancelResult {
  final CancelStatus status;
  final String message;

  CancelResult._(this.status, this.message);

  factory CancelResult.success(String message) =>
      CancelResult._(CancelStatus.success, message);

  factory CancelResult.pending(String message) =>
      CancelResult._(CancelStatus.pending, message);

  factory CancelResult.failed(String message) =>
      CancelResult._(CancelStatus.failed, message);

  bool get isSuccess => status == CancelStatus.success;
  bool get isPending => status == CancelStatus.pending;
  bool get isFailed => status == CancelStatus.failed;
}

enum CancelStatus { success, pending, failed }
