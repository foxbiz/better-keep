import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_functions_helper.dart';
import 'package:better_keep/services/country_detection_service.dart';
import 'package:better_keep/services/monetization/google_play_product_selector.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/purchase_attempt_tracker.dart';
import 'package:better_keep/services/monetization/purchase_feedback.dart';
import 'package:better_keep/services/monetization/purchase_provider.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/services/monetization/subscription_management.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:better_keep/services/monetization/purchase_feedback.dart';

/// Supported currencies for Razorpay payments
enum RazorpayCurrency {
  usd('USD', '\$'),
  inr('INR', '₹');

  const RazorpayCurrency(this.code, this.symbol);
  final String code;
  final String symbol;
}

/// Product IDs for in-app purchases
class ProductIds {
  /// Subscription product ID for Android (single product with base plans)
  static const String proSubscription = 'better_keep_pro';

  /// Base plan IDs for Android (used with the subscription product)
  static const String basePlanMonthly = 'pro-monthly';
  static const String basePlanYearly = 'pro-yearly';

  /// iOS product IDs (separate products per billing period)
  static const String proMonthlyIos = 'pro_monthly';
  static const String proYearlyIos = 'pro_yearly';

  static const List<String> subscriptions = [
    proSubscription,
    proMonthlyIos,
    proYearlyIos,
  ];
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
  final bool localEntitlementActive;
  final bool restored;
  final bool isTrial;
  final bool contractValid;
  final ExistingEntitlementResolution resolution;
  final Map<String, dynamic>? subscription;

  ExistingSubscriptionResult({
    required this.hasSubscription,
    this.localEntitlementActive = false,
    this.restored = false,
    this.isTrial = false,
    this.contractValid = false,
    this.resolution = ExistingEntitlementResolution.unknown,
    this.subscription,
  });

  bool get linkedProviderRecordFound =>
      resolution == ExistingEntitlementResolution.activeProvider ||
      resolution == ExistingEntitlementResolution.providerInactive;

  bool get explicitlyTerminal =>
      contractValid &&
      resolution == ExistingEntitlementResolution.providerInactive;
}

enum ExistingEntitlementResolution {
  activeProvider,
  providerInactive,
  trial,
  none,
  unknown;

  static ExistingEntitlementResolution parse(dynamic value) {
    switch (value) {
      case 'active_provider':
        return ExistingEntitlementResolution.activeProvider;
      case 'provider_inactive':
        return ExistingEntitlementResolution.providerInactive;
      case 'trial':
        return ExistingEntitlementResolution.trial;
      case 'none':
        return ExistingEntitlementResolution.none;
      default:
        return ExistingEntitlementResolution.unknown;
    }
  }
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

/// Razorpay pricing by currency
/// Amounts are in smallest currency unit (cents for USD, paise for INR)
const Map<RazorpayCurrency, Map<String, int>> razorpayPricing = {
  RazorpayCurrency.usd: {
    'monthly': 299, // $2.99
    'yearly': 1999, // $19.99
  },
  RazorpayCurrency.inr: {
    'monthly': 23000, // ₹230
    'yearly': 162500, // ₹1625
  },
};

/// Handles subscription purchases across platforms.
///
/// - Mobile (iOS/Android): Uses in_app_purchase plugin
/// - Web/Desktop: Redirects to external checkout page
class SubscriptionService {
  SubscriptionService._internal();

  static final SubscriptionService _instance = SubscriptionService._internal();
  static SubscriptionService get instance => _instance;

  // In-app purchase
  // Resolve the platform implementation only when native billing is used.
  // Provider/readiness UI can safely inspect this service without opening a
  // billing connection as a side effect.
  late final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  List<ProductDetails> _products = [];
  Future<bool>? _iapInitialization;

  /// Native store readiness is independent from the selected provider.
  final ValueNotifier<StoreReadiness> storeReadiness = ValueNotifier(
    StoreReadiness.uninitialized,
  );

  bool get _iapAvailable => storeReadiness.value == StoreReadiness.ready;

  // Loading state
  final ValueNotifier<bool> isLoading = ValueNotifier(false);

  // Currency detection loading state (for showing loading indicator in paywall)
  final ValueNotifier<bool> isCurrencyLoading = ValueNotifier(false);

  // Flag to prevent multiple currency initialization calls
  bool _currencyInitialized = false;

  // Currency selection for Razorpay
  // NOTE: Razorpay Subscriptions API only supports INR for most Indian merchants.
  // USD subscriptions require special approval from Razorpay. Default to INR.
  final ValueNotifier<RazorpayCurrency> selectedCurrency = ValueNotifier(
    RazorpayCurrency.usd,
  );

  final PurchaseAttemptTracker _purchaseAttempt = PurchaseAttemptTracker();
  final ValueNotifier<PurchaseEvent?> _purchaseEvents = ValueNotifier(null);
  final ValueNotifier<PurchaseAttemptPhase> _purchasePhase = ValueNotifier(
    PurchaseAttemptPhase.idle,
  );

  // Completer for restore purchases flow
  Completer<bool>? _restoreCompleter;
  bool _restoredSubscriptionFound = false;
  bool _restoreOwnershipConflictFound = false;
  bool _sawAlreadyOwnedStoreError = false;
  // Track whether we've already verified a restored iOS receipt in this
  // restore session.  iOS delivers one restored transaction per past purchase
  // but they all share the same app receipt — verifying more than once is
  // redundant and causes duplicate emails + unnecessary Cloud Function calls.
  bool _restoredIosReceiptVerified = false;

  /// One-shot outcomes from the active asynchronous app-store checkout.
  ValueListenable<PurchaseEvent?> get purchaseEvents => _purchaseEvents;

  /// Stable progress for the active native app-store checkout.
  ValueListenable<PurchaseAttemptPhase> get purchasePhase => _purchasePhase;

  /// True when running on Apple platforms (iOS/macOS), never on web.
  bool get _isApplePlatform => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Whether purchases are available on this platform
  bool get canMakePurchases {
    if (kIsWeb) return true; // Web uses Razorpay
    return Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  /// Provider selected solely from the current distribution platform.
  PurchaseProvider get purchaseProvider => currentPurchaseProvider;

  /// Compatibility getter for UI and subscription-management call sites.
  bool get usesRazorpay => purchaseProvider == PurchaseProvider.razorpay;

  /// Get available products
  List<ProductDetails> get products => _products;

  /// Check if products are loaded
  bool get hasProducts => _products.isNotEmpty;

  /// Get debug info for troubleshooting
  String get debugInfo {
    return '''
Purchase provider: ${purchaseProvider.name}
Store readiness: ${storeReadiness.value.name}
Purchase phase: ${_purchasePhase.value.name}
Products loaded: ${_products.length}
Product IDs: ${_products.map((p) => p.id).toList()}
Expected IDs: ${ProductIds.all}
''';
  }

  bool _initialized = false;

  /// Initialize the subscription service
  Future<void> init() async {
    if (_initialized) {
      AppLogger.log('SubscriptionService: Already initialized, skipping.');
      return;
    }
    _initialized = true;
    AppLogger.log('SubscriptionService: Initializing...');
    if (ReviewAccess.isCloudMutationBlockedFor(AuthService.currentUser)) {
      AppLogger.log(
        'SubscriptionService: Managed review session, store services disabled',
      );
      return;
    }

    if (kIsWeb) {
      AppLogger.log(
        'SubscriptionService: Web platform, using external checkout',
      );
      // Initialize currency for web (always uses Razorpay)
      await _initializeCurrency();
      return;
    }

    if (Platform.isIOS || Platform.isAndroid || Platform.isMacOS) {
      await _ensureInAppPurchaseReady();
    } else {
      AppLogger.log(
        'SubscriptionService: Desktop platform, using external checkout',
      );
    }

    // Initialize currency after IAP check so usesRazorpay is accurate
    if (usesRazorpay) {
      await _initializeCurrency();
    }
  }

  /// Initialize currency selection based on detected country
  Future<void> _initializeCurrency() async {
    // Guard against multiple/concurrent calls
    if (_currencyInitialized || isCurrencyLoading.value) {
      AppLogger.log(
        'SubscriptionService: Currency already initialized or in progress, skipping',
      );
      return;
    }
    _currencyInitialized = true;

    isCurrencyLoading.value = true;
    try {
      final countryCode = await CountryDetectionService.detectCountryCode();
      // Set INR for India, USD for all other countries
      if (countryCode.toUpperCase() == 'IN') {
        selectedCurrency.value = RazorpayCurrency.inr;
        AppLogger.log(
          'SubscriptionService: Currency set to INR (India detected)',
        );
      } else {
        selectedCurrency.value = RazorpayCurrency.usd;
        AppLogger.log(
          'SubscriptionService: Currency set to USD (country: $countryCode)',
        );
      }
    } catch (e) {
      AppLogger.error(
        'SubscriptionService: Error detecting country, defaulting to USD',
        e,
      );
      selectedCurrency.value = RazorpayCurrency.usd;
    } finally {
      isCurrencyLoading.value = false;
    }
  }

  /// Initialize in-app purchases for mobile
  Future<bool> _ensureInAppPurchaseReady() async {
    if (purchaseProvider != PurchaseProvider.googlePlay &&
        purchaseProvider != PurchaseProvider.appStore) {
      return false;
    }

    final inProgress = _iapInitialization;
    if (inProgress != null) return inProgress;
    if (_iapAvailable) return true;

    final initialization = _initializeInAppPurchase();
    _iapInitialization = initialization;
    try {
      return await initialization;
    } finally {
      if (identical(_iapInitialization, initialization)) {
        _iapInitialization = null;
      }
    }
  }

  Future<bool> _initializeInAppPurchase() async {
    storeReadiness.value = StoreReadiness.checking;

    try {
      final available = await _iap.isAvailable();
      if (!available) {
        storeReadiness.value = StoreReadiness.unavailable;
        AppLogger.log(
          'SubscriptionService: Native store billing is unavailable; '
          'purchases will fail closed on ${purchaseProvider.name}',
        );
        return false;
      }

      _purchaseSubscription ??= _iap.purchaseStream.listen(
        _handlePurchaseUpdates,
        onDone: () {
          _purchaseSubscription?.cancel();
          _purchaseSubscription = null;
        },
        onError: (error) {
          AppLogger.error('SubscriptionService: Purchase stream error', error);
        },
      );

      storeReadiness.value = StoreReadiness.ready;
      await _loadProducts();

      // Recover a purchase that completed while the app was not running.
      await _checkPendingPurchases();

      AppLogger.log('SubscriptionService: In-app purchases initialized');
      return true;
    } catch (error, stackTrace) {
      storeReadiness.value = StoreReadiness.unavailable;
      await AppLogger.error(
        'SubscriptionService: In-app purchase initialization failed',
        error,
        stackTrace,
      );
      return false;
    }
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
    final initialization = _iapInitialization;
    if (initialization != null) {
      await initialization;
      return;
    }
    if (!_iapAvailable) {
      // Initialization performs the first product load once the store connects.
      await _ensureInAppPurchaseReady();
      return;
    }
    await _loadProducts();
  }

  int _beginPurchaseAttempt() {
    // Clear presentation state from a previous attempt before any preflight
    // loading transitions occur.
    _purchaseEvents.value = null;
    _sawAlreadyOwnedStoreError = false;
    final attemptId = _purchaseAttempt.begin();
    _purchasePhase.value = PurchaseAttemptPhase.preflight;
    return attemptId;
  }

  void _finishPurchaseAttempt(int attemptId) {
    if (_purchaseAttempt.activeAttemptId != attemptId) return;
    _purchaseAttempt.finish(attemptId);
    _purchasePhase.value = PurchaseAttemptPhase.idle;
  }

  void _awaitStore(int attemptId, String productId) {
    if (_purchaseAttempt.awaitStore(attemptId, productId)) {
      _purchasePhase.value = PurchaseAttemptPhase.awaitingStore;
    }
  }

  void _beginVerification(int attemptId, String productId) {
    if (_purchaseAttempt.beginVerification(attemptId, productId)) {
      _purchasePhase.value = PurchaseAttemptPhase.verifying;
    }
  }

  void _publishStoreOutcome(
    PurchaseOutcome outcome, {
    required String productId,
  }) {
    final event = _purchaseAttempt.recordStoreOutcome(
      outcome,
      productId: productId,
    );
    if (event != null) {
      _purchasePhase.value = PurchaseAttemptPhase.idle;
      _purchaseEvents.value = event;
    }
  }

  /// Handle purchase updates from the store
  Future<void> _handlePurchaseUpdates(
    List<PurchaseDetails> purchaseDetailsList,
  ) async {
    String? processingProductId;
    try {
      for (final purchase in purchaseDetailsList) {
        processingProductId = purchase.productID;
        AppLogger.log(
          'SubscriptionService: Purchase update - ${purchase.productID}: ${purchase.status}',
        );

        switch (purchase.status) {
          case PurchaseStatus.pending:
            isLoading.value = true;
            break;

          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            final activeAttemptId = _purchaseAttempt.activeAttemptId;
            final belongsToActiveCheckout =
                purchase.status == PurchaseStatus.purchased &&
                activeAttemptId != null &&
                _purchaseAttempt.acceptsStoreOutcomeFor(purchase.productID);
            if (belongsToActiveCheckout) {
              _beginVerification(activeAttemptId, purchase.productID);
            }

            // On iOS, all restored transactions share the same app receipt.
            // Once we've successfully verified one, skip the rest to avoid
            // redundant Cloud Function calls and duplicate welcome emails.
            if (purchase.status == PurchaseStatus.restored &&
                _restoredIosReceiptVerified &&
                _isApplePlatform) {
              AppLogger.log(
                'SubscriptionService: Skipping duplicate iOS restored purchase ${purchase.productID}',
              );
              if (purchase.pendingCompletePurchase) {
                try {
                  await _iap.completePurchase(purchase);
                } catch (e) {
                  AppLogger.error(
                    'SubscriptionService: Error completing duplicate iOS purchase',
                    e,
                  );
                }
              }
              break;
            }

            // On iOS, complete the purchase BEFORE verification.
            // If _verifyPurchase() triggers a native StoreKit crash (release mode),
            // the transaction must already be cleared from the queue — otherwise
            // StoreKit replays it on every app launch, causing a permanent crash loop.
            if (_isApplePlatform && purchase.pendingCompletePurchase) {
              try {
                await _iap.completePurchase(purchase);
              } catch (e) {
                AppLogger.error(
                  'SubscriptionService: Error completing iOS purchase before verify',
                  e,
                );
              }
            }

            // Verify and deliver the purchase
            final verifyResult = await _verifyPurchase(purchase);

            if (verifyResult.valid) {
              final delivered = await _deliverPurchase(
                purchase,
                verifiedSubscription: verifyResult.subscription,
              );
              // Mark that we found a restored subscription
              if (purchase.status == PurchaseStatus.restored && delivered) {
                _restoredSubscriptionFound = true;
                if (_isApplePlatform) {
                  _restoredIosReceiptVerified = true;
                }
              }
              if (belongsToActiveCheckout) {
                _publishStoreOutcome(
                  delivered
                      ? PurchaseOutcome.activated
                      : PurchaseOutcome.activationPending,
                  productId: purchase.productID,
                );
              }
            } else if (verifyResult.isLinkedToOtherAccount) {
              // Subscription belongs to another account
              await PlanService.instance.applyOwnershipConflict(
                source: _isApplePlatform ? 'app_store' : 'play_store',
              );
              if (purchase.status == PurchaseStatus.restored) {
                _restoreOwnershipConflictFound = true;
              }
              if (belongsToActiveCheckout) {
                _publishStoreOutcome(
                  PurchaseOutcome.ownershipConflict,
                  productId: purchase.productID,
                );
              }
              AppLogger.log(
                'SubscriptionService: Subscription linked to another account',
              );
            } else {
              if (purchase.status == PurchaseStatus.restored) {
                // A failed restore just means "no active subscription to
                // restore", not an error the user needs to see.
                AppLogger.log(
                  'SubscriptionService: Restored purchase verification failed - ${verifyResult.error}',
                );
              } else {
                if (belongsToActiveCheckout) {
                  _publishStoreOutcome(
                    PurchaseOutcome.failed,
                    productId: purchase.productID,
                  );
                }
              }
            }

            // Complete the purchase (Android only — iOS/macOS already completed above)
            if (!kIsWeb &&
                !Platform.isIOS &&
                !Platform.isMacOS &&
                purchase.pendingCompletePurchase) {
              await _iap.completePurchase(purchase);
            }

            isLoading.value = false;
            if (belongsToActiveCheckout) {
              _finishPurchaseAttempt(activeAttemptId);
            }
            break;

          case PurchaseStatus.error:
            // Log the technical error for debugging
            AppLogger.error(
              'SubscriptionService: Purchase error for "${purchase.productID}"',
              purchase.error,
            );
            if (isAlreadyOwnedStoreError(purchase.error)) {
              // launchBillingFlow also returns false for ITEM_ALREADY_OWNED.
              // Let that synchronous path reconcile ownership before choosing
              // a terminal result instead of racing it with a generic error.
              _sawAlreadyOwnedStoreError = true;
            } else {
              // Only an error from an active checkout is user-facing. Restore
              // and other preflight errors remain diagnostics.
              _publishStoreOutcome(
                PurchaseOutcome.failed,
                productId: purchase.productID,
              );
            }
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
            _publishStoreOutcome(
              PurchaseOutcome.cancelled,
              productId: purchase.productID,
            );
            if (purchase.productID.isNotEmpty &&
                purchase.pendingCompletePurchase) {
              try {
                await _iap.completePurchase(purchase);
              } catch (e) {
                AppLogger.error(
                  'SubscriptionService: Error completing canceled purchase',
                  e,
                );
              }
            }
            isLoading.value = false;
            break;
        }
        processingProductId = null;
      }

      // Signal restore completer after ALL purchases in this batch have been
      // fully processed (verified + completePurchase called). This prevents
      // the race where buyNonConsumable is called while a second restored
      // purchase still has a pending transaction.
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        final hadRestored = purchaseDetailsList.any(
          (p) => p.status == PurchaseStatus.restored,
        );
        if (hadRestored) {
          _restoreCompleter!.complete(_restoredSubscriptionFound);
        }
      }
    } catch (e) {
      // Ensure stream listener exceptions never become unhandled Future
      // rejections, which would crash the app in release builds.
      AppLogger.error(
        'SubscriptionService: Unhandled error in purchase update handler',
        e,
      );
      final failedProductId = processingProductId;
      if (failedProductId != null) {
        _publishStoreOutcome(
          PurchaseOutcome.failed,
          productId: failedProductId,
        );
      }
      isLoading.value = false;
      // Complete restore completer so purchaseSubscription() is not stuck waiting
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
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
        errorLower.contains('already purchased') ||
        errorLower.contains('duplicate_product') ||
        errorLower.contains('pending transaction')) {
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

  /// Convert a purchase exception (thrown by buyNonConsumable) to a user-friendly message
  String _getFriendlyPurchaseException(Object e) {
    final message = e.toString();
    final messageLower = message.toLowerCase();

    if (messageLower.contains('storekit_duplicate_product') ||
        messageLower.contains('pending transaction') ||
        messageLower.contains('duplicate')) {
      return 'You have a pending purchase for this subscription. Please wait a moment and try again.';
    }

    return _getFriendlyErrorMessage(message);
  }

  /// Check for pending purchases that may not have been processed
  /// This is called on init to recover subscription state
  Future<void> _checkPendingPurchases() async {
    try {
      if (_skipPurchaseRestoreForReviewSession()) return;

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

  /// Restore purchases and wait for completion.
  /// Returns true if an active subscription was verified and restored.
  ///
  /// The completer is signaled by [_handlePurchaseUpdates] once a restored
  /// purchase finishes server-side verification (success or failure). A 15-second
  /// timeout fires if no restored purchases arrive from the store (e.g. user has
  /// no prior purchases on this account).
  Future<bool> restoreAndWaitForPurchases() async {
    if (_skipPurchaseRestoreForReviewSession()) return false;

    if (!await _ensureInAppPurchaseReady()) return false;

    // If a restore is already in progress, wait for it rather than starting a new one
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      return _restoreCompleter!.future;
    }

    try {
      AppLogger.log('SubscriptionService: Restoring purchases from store...');
      isLoading.value = true;
      _restoredSubscriptionFound = false;
      _restoreOwnershipConflictFound = false;
      _restoredIosReceiptVerified = false;
      _restoreCompleter = Completer<bool>();

      // Start the restore
      await _iap.restorePurchases();

      // Wait for _handlePurchaseUpdates to signal the completer after
      // verifying the restored purchase(s). Timeout fires when the store
      // delivers no restorable purchases (user has no prior purchases).
      final result = await _restoreCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => _restoredSubscriptionFound,
      );

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

  bool _skipPurchaseRestoreForReviewSession() {
    if (!ReviewAccess.isCloudMutationBlockedFor(AuthService.currentUser)) {
      return false;
    }
    AppLogger.log(
      'SubscriptionService: Skipping purchase restoration for review session',
    );
    return true;
  }

  /// Verify purchase with backend
  ///
  /// This calls the Cloud Function which:
  /// 1. Verifies the purchase with Google Play API
  /// 2. Ensures the subscription isn't linked to another account
  /// 3. Links the subscription to this user's account
  Future<VerifyPurchaseResult> _verifyPurchase(PurchaseDetails purchase) async {
    final verifyTraceId = _newVerifyTraceId();
    try {
      final user = AuthService.currentUser;
      if (user == null) {
        return VerifyPurchaseResult(valid: false, error: 'User not signed in');
      }
      if (ReviewAccess.isCloudMutationBlockedFor(user)) {
        return VerifyPurchaseResult(
          valid: false,
          error: 'Purchases are unavailable for the managed review account',
        );
      }

      final serverVerificationData =
          purchase.verificationData.serverVerificationData;
      final localVerificationData =
          purchase.verificationData.localVerificationData;

      if (_isApplePlatform) {
        AppLogger.log(
          'SubscriptionService: [$verifyTraceId] iOS verification payload lengths - '
          'local: ${localVerificationData.length}, '
          'server: ${serverVerificationData.length}',
        );
      }

      // Use serverVerificationData directly. Do NOT call
      // refreshPurchaseVerificationData() — it triggers a native StoreKit
      // SKReceiptRefreshRequest that crashes in release builds with
      // "freed pointer was not the last allocation" when Apple throttles
      // the request (SKError 603). The native crash bypasses Dart try/catch.
      final String verificationToken = serverVerificationData.isNotEmpty
          ? serverVerificationData
          : localVerificationData;

      if (_isApplePlatform) {
        if (verificationToken.trim().isEmpty) {
          return VerifyPurchaseResult(
            valid: false,
            error:
                'Unable to validate App Store purchase right now. Please tap Restore Purchases and try again.',
          );
        }

        if (_isTransactionJsonPayload(verificationToken)) {
          return VerifyPurchaseResult(
            valid: false,
            error:
                'Unable to validate this purchase payload yet. Please tap Restore Purchases and try again.',
          );
        }
      }

      // Log payload format for debugging
      if (_isApplePlatform) {
        final format = _isJWSPayload(verificationToken)
            ? 'JWS signed transaction'
            : 'legacy base64 receipt';
        AppLogger.log(
          'SubscriptionService: [$verifyTraceId] iOS payload format: $format',
        );
      }

      // Call Cloud Function to verify receipt
      final result = await callCloudFunction('verifyPurchase', {
        'productId': purchase.productID,
        'purchaseToken': verificationToken,
        'source': _isApplePlatform ? 'app_store' : 'play_store',
        'verifyTraceId': verifyTraceId,
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
      AppLogger.error(
        'SubscriptionService: [$verifyTraceId] Verification error (code: ${e.code}, message: ${e.message})',
        e,
      );

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

      if (e.code == 'failed-precondition' &&
          (e.message?.toLowerCase().contains('account') ?? false)) {
        return VerifyPurchaseResult(
          valid: false,
          error: e.message ?? 'This purchase belongs to another account.',
          isLinkedToOtherAccount: true,
        );
      }

      if (e.code == 'invalid-argument' || e.code == 'failed-precondition') {
        return VerifyPurchaseResult(
          valid: false,
          error: e.message ?? 'Purchase verification request is invalid.',
        );
      }

      if (e.code == 'internal') {
        return VerifyPurchaseResult(
          valid: false,
          error:
              e.message ??
              'Server error while verifying purchase. Please try again shortly.',
        );
      }

      // For server errors (permission issues, etc.), don't grant access
      // The user can try restoring purchases later once the issue is resolved
      return VerifyPurchaseResult(
        valid: false,
        error:
            e.message ??
            'Unable to verify purchase. Please try restoring purchases later or contact support.',
      );
    } catch (e) {
      AppLogger.error(
        'SubscriptionService: [$verifyTraceId] Verification error',
        e,
      );
      // In case of verification failure, don't grant access
      // The user should try again or restore purchases later
      return VerifyPurchaseResult(
        valid: false,
        error: 'Verification failed. Please try again or contact support.',
      );
    }
  }

  bool _isTransactionJsonPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        return false;
      }

      final hasTransactionId = decoded['transactionId'] is String;
      final hasOriginalTransactionId =
          decoded['originalTransactionId'] is String;
      return hasTransactionId || hasOriginalTransactionId;
    } catch (_) {
      return false;
    }
  }

  /// Check if the payload is a JWS compact serialization (3 dot-separated base64url segments).
  /// StoreKit 2 provides JWS signed transactions instead of legacy base64 app receipts.
  bool _isJWSPayload(String payload) {
    final parts = payload.split('.');
    if (parts.length != 3) return false;
    final b64urlRegex = RegExp(r'^[A-Za-z0-9_-]+$');
    return parts.every((p) => p.isNotEmpty && b64urlRegex.hasMatch(p));
  }

  String _newVerifyTraceId() {
    final random = Random.secure()
        .nextInt(1 << 20)
        .toRadixString(16)
        .padLeft(5, '0');
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-$random';
  }

  /// Deliver the purchase (update user subscription)
  Future<bool> _deliverPurchase(
    PurchaseDetails purchase, {
    Map<String, dynamic>? verifiedSubscription,
  }) async {
    try {
      // Verify step already updates Firestore server-side with canonical
      // subscription data. Avoid overwriting it on the client with guessed values.
      if (purchase.productID != ProductIds.proSubscription &&
          purchase.productID != ProductIds.proMonthlyIos &&
          purchase.productID != ProductIds.proYearlyIos) {
        return false;
      }

      // Refresh local subscription
      await PlanService.instance.refreshSubscription();

      if (!PlanService.instance.status.isActiveProviderEntitlement) {
        final payload = <String, dynamic>{
          ...?verifiedSubscription,
          'plan': 'pro',
          'source': _isApplePlatform ? 'app_store' : 'play_store',
        };
        await PlanService.instance.applyVerifiedEntitlement(payload);
      }

      final delivered = PlanService.instance.status.isActiveProviderEntitlement;

      AppLogger.log(
        'SubscriptionService: Delivered purchase for ${purchase.productID}: $delivered',
      );
      return delivered;
    } catch (e) {
      AppLogger.error('SubscriptionService: Error delivering purchase', e);
      return false;
    }
  }

  /// Get display price for a base plan from IAP or Razorpay.
  /// Throws [ProductNotAvailableException] if product is not loaded.
  String getDisplayPrice({required bool yearly}) {
    // For Razorpay platforms (web, Windows, Linux), return prices based on selected currency
    if (usesRazorpay) {
      final currency = selectedCurrency.value;
      final pricing = razorpayPricing[currency]!;
      final amount = yearly ? pricing['yearly']! : pricing['monthly']!;
      // Format based on currency
      if (currency == RazorpayCurrency.inr) {
        // Format INR: ₹1,625 or ₹230
        final formatted = (amount / 100).toStringAsFixed(0);
        final withCommas = formatted.replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
        return '₹$withCommas';
      } else {
        // Format USD: $19.99 or $2.99
        return '\$${(amount / 100).toStringAsFixed(2)}';
      }
    }

    // For iOS/macOS: look up separate monthly/yearly products directly
    if (_isApplePlatform) {
      final iosProductId = yearly
          ? ProductIds.proYearlyIos
          : ProductIds.proMonthlyIos;
      final iosProduct = _products.cast<ProductDetails?>().firstWhere(
        (p) => p?.id == iosProductId,
        orElse: () => null,
      );
      if (iosProduct == null) {
        throw ProductNotAvailableException(
          'iOS product "$iosProductId" not loaded. Please wait or try again.',
        );
      }
      return iosProduct.price;
    }

    // Try to get price from loaded products (Android)
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

    // Fallback
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
    // For Razorpay platforms (web, Windows, Linux), return prices based on selected currency
    if (usesRazorpay) {
      final currency = selectedCurrency.value;
      final pricing = razorpayPricing[currency]!;
      final divisor = currency == RazorpayCurrency.inr ? 100.0 : 100.0;
      return (pricing['monthly']! / divisor, pricing['yearly']! / divisor);
    }

    // For iOS/macOS: look up separate monthly/yearly products directly
    if (_isApplePlatform) {
      final monthlyProduct = _products.cast<ProductDetails?>().firstWhere(
        (p) => p?.id == ProductIds.proMonthlyIos,
        orElse: () => null,
      );
      final yearlyProduct = _products.cast<ProductDetails?>().firstWhere(
        (p) => p?.id == ProductIds.proYearlyIos,
        orElse: () => null,
      );
      if (monthlyProduct != null && yearlyProduct != null) {
        return (monthlyProduct.rawPrice, yearlyProduct.rawPrice);
      }
      throw ProductNotAvailableException(
        'iOS products not loaded. Please wait or try again.',
      );
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

    // For iOS/macOS: look up separate monthly/yearly products
    if (_isApplePlatform) {
      final monthlyProduct = _products.cast<ProductDetails?>().firstWhere(
        (p) => p?.id == ProductIds.proMonthlyIos,
        orElse: () => null,
      );
      final yearlyProduct = _products.cast<ProductDetails?>().firstWhere(
        (p) => p?.id == ProductIds.proYearlyIos,
        orElse: () => null,
      );
      if (monthlyProduct != null && yearlyProduct != null) {
        return (monthlyProduct.rawPrice, yearlyProduct.rawPrice);
      }
      throw ProductNotAvailableException(
        'iOS products not loaded. Please wait or try again.',
      );
    }

    // Fallback
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
      return PurchaseResult.failed(
        'Please sign in first',
        outcome: PurchaseOutcome.signInRequired,
      );
    }
    if (ReviewAccess.isCloudMutationBlockedFor(user)) {
      return PurchaseResult.failed(
        'Purchases are unavailable for the managed review account',
        outcome: PurchaseOutcome.unavailable,
      );
    }

    // For web/desktop, use Razorpay
    if (usesRazorpay) {
      return _purchaseWithRazorpay(yearly: yearly);
    }

    if (purchaseProvider == PurchaseProvider.unavailable) {
      return PurchaseResult.failed(
        'Purchases are not supported on this platform',
        outcome: PurchaseOutcome.unavailable,
      );
    }

    if (_purchaseAttempt.activeAttemptId != null) {
      return PurchaseResult.pending('A purchase is already in progress');
    }

    final attemptId = _beginPurchaseAttempt();

    // Native store platforms fail closed. A temporary Play/App Store failure
    // must never select or invoke an external payment provider.
    if (!await _ensureInAppPurchaseReady()) {
      _finishPurchaseAttempt(attemptId);
      return PurchaseResult.failed(
        'In-app purchases are unavailable. Please check your store account and try again.',
        outcome: PurchaseOutcome.unavailable,
      );
    }

    // First, try to restore purchases from the store (Google Play / App Store)
    // This checks if user already has an active subscription in the store
    //
    // On iOS, SKIP the store-level restore before purchase. The native
    // StoreKit 2 restorePurchases() call can trigger a native crash in
    // release builds (different behaviour under -O vs -Onone optimisation).
    // StoreKit 2 natively prevents duplicate subscriptions, and the
    // checkExistingSubscription() Cloud Function below provides a backup
    // duplicate check — so skipping restore here is safe on iOS.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        AppLogger.log(
          'SubscriptionService: Checking for existing subscription in store...',
        );
        final restored = await restoreAndWaitForPurchases();

        if (_restoreOwnershipConflictFound) {
          _finishPurchaseAttempt(attemptId);
          return PurchaseResult.failed(
            'This store purchase belongs to another Better Keep account.',
            outcome: PurchaseOutcome.ownershipConflict,
          );
        }
        if (restored) {
          AppLogger.log(
            'SubscriptionService: Active subscription found and restored',
          );
          _finishPurchaseAttempt(attemptId);
          return PurchaseResult.success(
            'Your subscription has been restored!',
            outcome: PurchaseOutcome.restored,
          );
        }
      } catch (e) {
        AppLogger.log('SubscriptionService: Error restoring purchases: $e');
        // Continue with purchase if restore fails
      }
    }

    // Also check Firebase for existing subscription (backup check)
    // Backend now properly excludes trial subscriptions
    try {
      isLoading.value = true;
      AppLogger.log(
        'SubscriptionService: Calling checkExistingSubscription...',
      );
      final existingCheck = await checkExistingSubscription();
      AppLogger.log(
        'SubscriptionService: checkExistingSubscription result - hasSubscription: ${existingCheck.hasSubscription}, restored: ${existingCheck.restored}',
      );

      if (existingCheck.hasSubscription) {
        isLoading.value = false;
        _finishPurchaseAttempt(attemptId);
        if (!existingCheck.localEntitlementActive) {
          return PurchaseResult.failed(
            'Payment is confirmed but Pro activation is still pending.',
            outcome: PurchaseOutcome.activationPending,
          );
        }
        if (existingCheck.restored) {
          return PurchaseResult.success(
            'Your subscription has been restored!',
            outcome: PurchaseOutcome.restored,
          );
        }
        return PurchaseResult.success(
          'You already have an active subscription.',
          outcome: PurchaseOutcome.alreadyActive,
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

    // On iOS/macOS, use separate product IDs; on Android, use the single product with base plan
    if (_isApplePlatform) {
      final iosProductId = yearly
          ? ProductIds.proYearlyIos
          : ProductIds.proMonthlyIos;
      return _purchaseWithIAP(iosProductId, attemptId: attemptId);
    }

    return _purchaseWithIAP(
      ProductIds.proSubscription,
      basePlanId: basePlanId,
      attemptId: attemptId,
    );
  }

  /// Purchase subscription using Razorpay (for web/desktop)
  Future<PurchaseResult> _purchaseWithRazorpay({required bool yearly}) async {
    final razorpayService = RazorpayService.instance;

    AppLogger.log('SubscriptionService: Using Razorpay for subscription');
    isLoading.value = true;

    try {
      final result = await razorpayService.purchaseSubscription(yearly: yearly);

      if (result.success) {
        return PurchaseResult.success(
          'Subscription activated successfully!',
          outcome: PurchaseOutcome.activated,
        );
      } else if (result.cancelled) {
        return PurchaseResult.failed(
          'Purchase was cancelled',
          outcome: PurchaseOutcome.cancelled,
        );
      } else {
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
      final result = await callCloudFunction('checkExistingSubscription');

      // Convert from Map<Object?, Object?> to Map<String, dynamic>
      final data = Map<String, dynamic>.from(result.data as Map);
      final contractValid =
          data['entitlementContractVersion'] ==
          verifiedEntitlementContractVersion;
      final resolution = ExistingEntitlementResolution.parse(
        data['resolution'],
      );

      if (data['hasSubscription'] == true) {
        final subscription = data['subscription'] != null
            ? Map<String, dynamic>.from(data['subscription'] as Map)
            : null;
        // Apply the authenticated, versioned result first. A following stale
        // Firestore trial/missing read can no longer undo this activation.
        final hydrated = await PlanService.instance.applyVerifiedEntitlement(
          subscription,
        );
        if (hydrated) {
          await PlanService.instance.refreshSubscription();
        }

        return ExistingSubscriptionResult(
          hasSubscription: true,
          localEntitlementActive:
              PlanService.instance.status.isActiveProviderEntitlement,
          restored: data['restored'] == true,
          isTrial: data['isTrial'] == true,
          contractValid: contractValid,
          resolution: resolution,
          subscription: subscription,
        );
      }

      if (contractValid &&
          resolution == ExistingEntitlementResolution.providerInactive) {
        await PlanService.instance.applyExplicitTerminalEntitlement();
      }

      // Check if user is on trial - backend returns hasSubscription: false
      // for trial users to allow upgrades, but we shouldn't reset their status
      return ExistingSubscriptionResult(
        hasSubscription: false,
        isTrial: data['isTrial'] == true,
        contractValid: contractValid,
        resolution: resolution,
      );
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
    required int attemptId,
  }) async {
    if (!await _ensureInAppPurchaseReady()) {
      _finishPurchaseAttempt(attemptId);
      return PurchaseResult.failed(
        'In-app purchases not available on this device',
        outcome: PurchaseOutcome.unavailable,
      );
    }

    final user = AuthService.currentUser;
    if (user == null) {
      _finishPurchaseAttempt(attemptId);
      return PurchaseResult.failed(
        'Please sign in first',
        outcome: PurchaseOutcome.signInRequired,
      );
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
        _finishPurchaseAttempt(attemptId);
        return PurchaseResult.failed(
          'This product is not available yet. Please make sure the app is updated and try again.',
          outcome: PurchaseOutcome.unavailable,
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
        // Log all products with this ID for debugging
        final matchingProducts = _products
            .where((p) => p.id == productId)
            .toList();
        AppLogger.log(
          'SubscriptionService: Found ${matchingProducts.length} products with ID "$productId"',
        );

        final selectedProduct = selectGooglePlayProductForBasePlan(
          _products,
          productId: productId,
          basePlanId: basePlanId,
        );

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
          _finishPurchaseAttempt(attemptId);
          return PurchaseResult.failed(
            'Subscription plan not available. Please try again later.',
            outcome: PurchaseOutcome.unavailable,
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

      // On iOS, a pending restored transaction from a previous restore attempt
      // may not have been completed yet. Retry once after a short delay if
      // StoreKit reports a duplicate pending transaction.
      bool success;
      try {
        _awaitStore(attemptId, productId);
        success = await _iap.buyNonConsumable(purchaseParam: purchaseParam);
      } catch (e) {
        if (!kIsWeb &&
            _isApplePlatform &&
            e.toString().contains('storekit_duplicate_product')) {
          AppLogger.log(
            'SubscriptionService: Pending transaction detected, waiting for completion...',
          );
          // Wait for the pending transaction to be completed by _handlePurchaseUpdates
          await Future.delayed(const Duration(seconds: 3));
          AppLogger.log(
            'SubscriptionService: Retrying buyNonConsumable after delay...',
          );
          success = await _iap.buyNonConsumable(purchaseParam: purchaseParam);
        } else if (isAlreadyOwnedStoreError(e)) {
          AppLogger.log(
            'SubscriptionService: Store reports an already-owned purchase; '
            'reconciling it for the current account',
          );
          return _reconcileCurrentStorePurchase(
            attemptId: attemptId,
            paymentWasConfirmed: true,
          );
        } else {
          rethrow;
        }
      }

      if (!success) {
        isLoading.value = false;
        if (_purchaseAttempt.activeAttemptId != attemptId) {
          // The purchase stream already delivered the terminal outcome while
          // the launch call was awaiting its platform response.
          return PurchaseResult.pending('Purchase outcome already received');
        }
        return _reconcileCurrentStorePurchase(
          attemptId: attemptId,
          paymentWasConfirmed: _sawAlreadyOwnedStoreError,
        );
      }

      // Purchase initiated - result will come through purchase stream
      return PurchaseResult.pending('Processing purchase...');
    } catch (e) {
      isLoading.value = false;
      if (_purchaseAttempt.activeAttemptId != attemptId) {
        AppLogger.log(
          'SubscriptionService: Store outcome arrived before launch exception: $e',
        );
        return PurchaseResult.pending('Purchase outcome already received');
      }
      _finishPurchaseAttempt(attemptId);
      AppLogger.error(
        'SubscriptionService: Purchase exception for $productId',
        e,
      );
      return PurchaseResult.failed(_getFriendlyPurchaseException(e));
    }
  }

  /// Restores and reconciles the current store account without starting a new
  /// checkout. This is also the recovery path for Play's ITEM_ALREADY_OWNED.
  Future<PurchaseResult> reconcileCurrentStorePurchase() {
    return _reconcileCurrentStorePurchase(paymentWasConfirmed: true);
  }

  Future<PurchaseResult> _reconcileCurrentStorePurchase({
    int? attemptId,
    required bool paymentWasConfirmed,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return PurchaseResult.failed(
        'Please sign in first',
        outcome: PurchaseOutcome.signInRequired,
      );
    }
    if (ReviewAccess.isCloudMutationBlockedFor(user)) {
      return PurchaseResult.failed(
        'Purchase reconciliation is unavailable for the managed review account',
        outcome: PurchaseOutcome.unavailable,
      );
    }
    if (purchaseProvider != PurchaseProvider.googlePlay &&
        purchaseProvider != PurchaseProvider.appStore) {
      return PurchaseResult.failed(
        'Store purchase reconciliation is unavailable on this platform',
        outcome: PurchaseOutcome.unavailable,
      );
    }

    final activeAttemptId = _purchaseAttempt.activeAttemptId;
    if (attemptId == null && activeAttemptId != null) {
      return PurchaseResult.pending('A purchase is already being reconciled');
    }
    if (attemptId != null && activeAttemptId != attemptId) {
      return PurchaseResult.pending('Purchase outcome already received');
    }

    final effectiveAttemptId = attemptId ?? _beginPurchaseAttempt();
    _purchasePhase.value = PurchaseAttemptPhase.verifying;
    isLoading.value = true;

    try {
      if (!await _ensureInAppPurchaseReady()) {
        return PurchaseResult.failed(
          'In-app purchases are unavailable. Please check your store account and try again.',
          outcome: PurchaseOutcome.unavailable,
        );
      }

      // Query linked provider records before asking the store to replay
      // purchases. This avoids unnecessary restore churn and is authoritative
      // for an already-linked, still-active subscription.
      final existing = await checkExistingSubscription();
      if (existing.hasSubscription && existing.localEntitlementActive) {
        return PurchaseResult.success(
          existing.restored
              ? 'Your subscription has been restored!'
              : 'You already have an active subscription.',
          outcome: existing.restored
              ? PurchaseOutcome.restored
              : PurchaseOutcome.alreadyActive,
        );
      }
      if (existing.hasSubscription) {
        return PurchaseResult.failed(
          'Payment is confirmed but Pro activation is still pending.',
          outcome: PurchaseOutcome.activationPending,
        );
      }

      if (!existing.linkedProviderRecordFound) {
        final restored = await restoreAndWaitForPurchases();
        if (_restoreOwnershipConflictFound) {
          await PlanService.instance.applyOwnershipConflict(
            source: _isApplePlatform ? 'app_store' : 'play_store',
          );
          return PurchaseResult.failed(
            'This store purchase belongs to another Better Keep account.',
            outcome: PurchaseOutcome.ownershipConflict,
          );
        }
        if (restored &&
            PlanService.instance.status.isActiveProviderEntitlement) {
          return PurchaseResult.success(
            'Your subscription has been restored!',
            outcome: PurchaseOutcome.restored,
          );
        }

        final afterRestore = await checkExistingSubscription();
        if (afterRestore.hasSubscription &&
            afterRestore.localEntitlementActive) {
          return PurchaseResult.success(
            'Your subscription has been restored!',
            outcome: PurchaseOutcome.restored,
          );
        }
      }

      if (paymentWasConfirmed || !existing.contractValid) {
        return PurchaseResult.failed(
          'Payment is confirmed but Pro activation is still pending.',
          outcome: PurchaseOutcome.activationPending,
        );
      }

      return PurchaseResult.failed(
        'No active subscription was found for this account.',
      );
    } catch (e) {
      AppLogger.error(
        'SubscriptionService: Store purchase reconciliation failed',
        e,
      );
      if (paymentWasConfirmed) {
        return PurchaseResult.failed(
          'Payment is confirmed but Pro activation is still pending.',
          outcome: PurchaseOutcome.activationPending,
        );
      }
      return PurchaseResult.failed('Could not reconcile the store purchase');
    } finally {
      isLoading.value = false;
      _finishPurchaseAttempt(effectiveAttemptId);
    }
  }

  /// Restore previous purchases (for mobile platforms)
  Future<RestoreResult> restorePurchases() async {
    if (ReviewAccess.isCloudMutationBlockedFor(AuthService.currentUser)) {
      return RestoreResult.failed(
        'Purchase restoration is unavailable for the managed review account',
      );
    }
    if (usesRazorpay) {
      // For web/desktop with Razorpay, just refresh from Firebase
      await PlanService.instance.refreshSubscription();
      return RestoreResult.success('Subscription status refreshed');
    }

    if (!await _ensureInAppPurchaseReady()) {
      return RestoreResult.failed('In-app purchases not available');
    }

    try {
      isLoading.value = true;
      final found = await restoreAndWaitForPurchases();

      if (found) {
        // Force refresh so the UI reflects the latest state (including
        // willAutoRenew / cancelled status written by the Cloud Function).
        await PlanService.instance.refreshSubscription();
        return RestoreResult.success('Subscription restored successfully');
      } else {
        return RestoreResult.failed('No active subscription found to restore');
      }
    } catch (e) {
      return RestoreResult.failed('Error restoring purchases: $e');
    } finally {
      isLoading.value = false;
    }
  }

  /// Cancel subscription (redirects to platform-specific management)
  Future<CancelResult> cancelSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return CancelResult.failed('Please sign in first');
    }
    if (ReviewAccess.isCloudMutationBlockedFor(user)) {
      return CancelResult.failed(
        'Subscription changes are unavailable for the managed review account',
      );
    }
    final subscriptionStatus = PlanService.instance.status;
    final target = resolveSubscriptionManagementTarget(
      purchasePlatform: subscriptionStatus.purchasePlatform,
      currentPlatform: _subscriptionManagementPlatform,
    );

    switch (target.action) {
      case SubscriptionManagementAction.razorpayApi:
        return _cancelRazorpaySubscription();
      case SubscriptionManagementAction.appStoreNative:
      case SubscriptionManagementAction.externalUrl:
      case SubscriptionManagementAction.contactSupport:
        return _openSubscriptionManagementTarget(target);
    }
  }

  /// Opens the current provider's subscription-management surface without
  /// changing entitlement state in the app.
  Future<CancelResult> openSubscriptionManagement() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return CancelResult.failed('Please sign in first');
    }

    final target = resolveSubscriptionManagementTarget(
      purchasePlatform: PlanService.instance.status.purchasePlatform,
      currentPlatform: _subscriptionManagementPlatform,
    );
    if (target.action == SubscriptionManagementAction.razorpayApi) {
      return CancelResult.failed(
        'Manage this subscription from your Better Keep account settings.',
        outcome: SubscriptionActionOutcome.unavailable,
      );
    }
    return _openSubscriptionManagementTarget(target);
  }

  /// Opens the native store that produced the current purchase/restore event.
  /// Used when local provider state was deliberately cleared after an
  /// ownership conflict or has not hydrated yet after payment.
  Future<CancelResult> openCurrentStoreSubscriptionManagement() async {
    final user = AuthService.currentUser;
    if (user == null) {
      return CancelResult.failed('Please sign in first');
    }

    final target = resolveCurrentStoreManagementTarget(
      _subscriptionManagementPlatform,
    );
    return _openSubscriptionManagementTarget(target);
  }

  Future<CancelResult> _openSubscriptionManagementTarget(
    SubscriptionManagementTarget target,
  ) async {
    switch (target.action) {
      case SubscriptionManagementAction.razorpayApi:
        return CancelResult.failed(
          'Subscription management is unavailable for this provider.',
          outcome: SubscriptionActionOutcome.unavailable,
        );
      case SubscriptionManagementAction.appStoreNative:
        // Use StoreKit 2 API which handles sandbox vs production automatically
        try {
          const channel = MethodChannel('com.betterkeep/subscriptions');
          await channel.invokeMethod('showManageSubscriptions');
          // The modal sheet has been dismissed — the user may have cancelled,
          // re-subscribed, or just browsed.  Refresh the Firestore subscription
          // status to pick up any webhook-driven updates.
          await PlanService.instance.refreshSubscription(
            validateWithBackend: true,
          );
          return CancelResult.pending(
            'If you made changes, they may take a moment to appear.',
          );
        } catch (e) {
          // Fallback to URL if native method channel fails
          AppLogger.log(
            'StoreKit manage subscriptions failed, falling back to URL: $e',
          );
          return _openSubscriptionManagementUrl(target);
        }
      case SubscriptionManagementAction.externalUrl:
        return _openSubscriptionManagementUrl(target);
      case SubscriptionManagementAction.contactSupport:
        return CancelResult.failed(
          'We could not identify the billing provider. Contact '
          'contact@betterkeep.app for help managing this subscription.',
          outcome: SubscriptionActionOutcome.providerUnknown,
        );
    }
  }

  SubscriptionManagementPlatform get _subscriptionManagementPlatform {
    if (kIsWeb) return SubscriptionManagementPlatform.web;
    if (Platform.isIOS) return SubscriptionManagementPlatform.ios;
    if (Platform.isAndroid) return SubscriptionManagementPlatform.android;
    if (Platform.isMacOS) return SubscriptionManagementPlatform.macos;
    if (Platform.isWindows) return SubscriptionManagementPlatform.windows;
    if (Platform.isLinux) return SubscriptionManagementPlatform.linux;
    return SubscriptionManagementPlatform.other;
  }

  Future<CancelResult> _openSubscriptionManagementUrl(
    SubscriptionManagementTarget target,
  ) async {
    final uri = Uri.parse(target.url!);
    try {
      var launched = await launchUrl(uri, mode: LaunchMode.externalApplication);

      // Some Android devices report no external handler for the HTTPS intent
      // even though the platform can open it through its default route.
      if (!launched) {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }

      if (!launched) {
        return CancelResult.failed('Could not open subscription management');
      }

      return CancelResult.pending(target.pendingMessage!);
    } catch (e) {
      AppLogger.error('Error opening subscription management', e);
      try {
        final launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
        if (launched) return CancelResult.pending(target.pendingMessage!);
      } catch (fallbackError) {
        AppLogger.error(
          'Subscription management fallback failed',
          fallbackError,
        );
      }
      return CancelResult.failed('Could not open subscription management');
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
    if (ReviewAccess.isCloudMutationBlockedFor(user)) {
      return CancelResult.failed(
        'Subscription changes are unavailable for the managed review account',
      );
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
    _purchaseSubscription = null;
    _iapInitialization = null;
    _initialized = false;
    _products = [];
    _purchaseAttempt.reset();
    _purchaseEvents.value = null;
    _purchasePhase.value = PurchaseAttemptPhase.idle;
    storeReadiness.value = StoreReadiness.uninitialized;
  }
}

/// Result of a purchase attempt
class PurchaseResult {
  final PurchaseResultStatus status;
  final PurchaseOutcome outcome;
  final String diagnosticMessage;

  PurchaseResult._(this.status, this.outcome, this.diagnosticMessage);

  factory PurchaseResult.success(
    String diagnosticMessage, {
    PurchaseOutcome outcome = PurchaseOutcome.activated,
  }) => PurchaseResult._(
    PurchaseResultStatus.success,
    outcome,
    diagnosticMessage,
  );

  factory PurchaseResult.pending(String diagnosticMessage) => PurchaseResult._(
    PurchaseResultStatus.pending,
    PurchaseOutcome.pending,
    diagnosticMessage,
  );

  factory PurchaseResult.failed(
    String diagnosticMessage, {
    PurchaseOutcome outcome = PurchaseOutcome.failed,
  }) =>
      PurchaseResult._(PurchaseResultStatus.failed, outcome, diagnosticMessage);

  bool get isSuccess => status == PurchaseResultStatus.success;
  bool get isPending => status == PurchaseResultStatus.pending;
  bool get isFailed => status == PurchaseResultStatus.failed;
}

enum PurchaseResultStatus { success, pending, failed }

/// Result of a restore attempt
class RestoreResult {
  final SubscriptionActionOutcome outcome;
  final String diagnosticMessage;

  RestoreResult._(this.outcome, this.diagnosticMessage);

  factory RestoreResult.success(String diagnosticMessage) =>
      RestoreResult._(SubscriptionActionOutcome.success, diagnosticMessage);

  factory RestoreResult.failed(
    String diagnosticMessage, {
    SubscriptionActionOutcome outcome = SubscriptionActionOutcome.failed,
  }) => RestoreResult._(outcome, diagnosticMessage);

  bool get isSuccess => outcome == SubscriptionActionOutcome.success;
}

/// Result of a cancellation attempt
class CancelResult {
  final CancelStatus status;
  final SubscriptionActionOutcome outcome;
  final String diagnosticMessage;

  CancelResult._(this.status, this.outcome, this.diagnosticMessage);

  factory CancelResult.success(String diagnosticMessage) => CancelResult._(
    CancelStatus.success,
    SubscriptionActionOutcome.success,
    diagnosticMessage,
  );

  factory CancelResult.pending(String diagnosticMessage) => CancelResult._(
    CancelStatus.pending,
    SubscriptionActionOutcome.pending,
    diagnosticMessage,
  );

  factory CancelResult.failed(
    String diagnosticMessage, {
    SubscriptionActionOutcome outcome = SubscriptionActionOutcome.failed,
  }) => CancelResult._(CancelStatus.failed, outcome, diagnosticMessage);

  bool get isSuccess => status == CancelStatus.success;
  bool get isPending => status == CancelStatus.pending;
  bool get isFailed => status == CancelStatus.failed;
}

enum CancelStatus { success, pending, failed }

enum SubscriptionActionOutcome {
  success,
  pending,
  signInRequired,
  unavailable,
  notFound,
  providerUnknown,
  failed,
}
