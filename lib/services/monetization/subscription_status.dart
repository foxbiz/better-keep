import 'package:cloud_firestore/cloud_firestore.dart';

import 'user_plan.dart';

const _verifiedProviderSources = {'play_store', 'app_store', 'razorpay'};
const verifiedEntitlementContractVersion = 2;

/// Parses an authenticated backend verification payload for local hydration.
///
/// This never replaces server authorization. It only prevents a verified paid
/// purchase from remaining visually stuck on trial while Firestore catches up.
SubscriptionStatus? parseVerifiedProviderEntitlement(
  Map<String, dynamic>? data,
) {
  if (data == null) return null;
  if (data['entitlementContractVersion'] !=
      verifiedEntitlementContractVersion) {
    return null;
  }
  if (data['subscriptionState'] is! String ||
      (data['subscriptionState'] as String).trim().isEmpty ||
      RenewalState.tryParse(data['renewalState']) == null) {
    return null;
  }
  final status = SubscriptionStatus.fromFirestore(data);
  if (status.plan != UserPlan.pro ||
      !status.isActive ||
      status.billingPeriod == null ||
      !_verifiedProviderSources.contains(status.purchasePlatform)) {
    return null;
  }
  return status;
}

enum RenewalState {
  renewing,
  notRenewing,
  unknown;

  static RenewalState? tryParse(dynamic value) {
    switch (value) {
      case 'renewing':
        return RenewalState.renewing;
      case 'notRenewing':
      case 'not_renewing':
        return RenewalState.notRenewing;
      case 'unknown':
        return RenewalState.unknown;
      default:
        return null;
    }
  }
}

/// Subscription billing period
enum BillingPeriod {
  monthly,
  yearly;

  String get displayName {
    switch (this) {
      case BillingPeriod.monthly:
        return 'Monthly';
      case BillingPeriod.yearly:
        return 'Yearly';
    }
  }
}

/// Subscription status tracking
class SubscriptionStatus {
  /// Current user plan
  final UserPlan plan;

  /// When the subscription expires (null for free/lifetime)
  final DateTime? expiresAt;

  /// Billing period (null for free tier)
  final BillingPeriod? billingPeriod;

  /// Whether the subscription is in grace period
  final bool inGracePeriod;

  /// Grace period end date (null if not in grace period)
  final DateTime? gracePeriodEndsAt;

  /// Provider-reported renewal state. Missing metadata remains unknown.
  final RenewalState renewalState;

  /// Provider subscription state used to distinguish terminal server results.
  final String? subscriptionState;

  /// Platform where subscription was purchased
  final String? purchasePlatform;

  /// Store-specific subscription ID
  final String? storeSubscriptionId;

  /// When the subscription was last verified
  final DateTime? lastVerifiedAt;

  const SubscriptionStatus({
    required this.plan,
    this.expiresAt,
    this.billingPeriod,
    this.inGracePeriod = false,
    this.gracePeriodEndsAt,
    RenewalState? renewalState,
    bool? willAutoRenew,
    this.subscriptionState,
    this.purchasePlatform,
    this.storeSubscriptionId,
    this.lastVerifiedAt,
  }) : renewalState =
           renewalState ??
           (willAutoRenew == null
               ? RenewalState.unknown
               : willAutoRenew
               ? RenewalState.renewing
               : RenewalState.notRenewing);

  /// Default free subscription
  static const SubscriptionStatus free = SubscriptionStatus(
    plan: UserPlan.free,
  );

  /// Check if subscription is currently active
  bool get isActive {
    if (plan == UserPlan.free) return true; // Free is always "active"
    if (expiresAt == null) return false;

    // Check if expired
    final now = DateTime.now();
    if (expiresAt!.isAfter(now)) return true;

    // Check grace period
    if (inGracePeriod && gracePeriodEndsAt != null) {
      return gracePeriodEndsAt!.isAfter(now);
    }

    return false;
  }

  /// Check if subscription is expired
  bool get isExpired {
    if (plan == UserPlan.free) return false;
    return !isActive;
  }

  /// Check if subscription is cancelled but still active (will not renew)
  bool get isCancelledButActive {
    return isActiveProviderEntitlement &&
        renewalState == RenewalState.notRenewing;
  }

  /// Compatibility getter for code that only needs the positive renewal case.
  bool get willAutoRenew => renewalState == RenewalState.renewing;

  /// Days until expiration (-1 if no expiration)
  int get daysUntilExpiration {
    if (expiresAt == null) return -1;
    final now = DateTime.now();
    final difference = expiresAt!.difference(now);
    return difference.inDays;
  }

  /// Whether the subscription is expiring soon (within 7 days)
  bool get isExpiringSoon {
    final days = daysUntilExpiration;
    return days >= 0 && days <= 7;
  }

  /// Whether this subscription was purchased via Razorpay (web/desktop)
  bool get isRazorpaySubscription => purchasePlatform == 'razorpay';

  /// Whether this subscription was purchased via App Store (iOS)
  bool get isAppStoreSubscription => purchasePlatform == 'app_store';

  /// Whether this subscription was purchased via Play Store (Android)
  bool get isPlayStoreSubscription => purchasePlatform == 'play_store';

  /// Whether this is a trial subscription
  bool get isTrialSubscription => purchasePlatform == 'trial';

  /// Whether an active paid provider, rather than a trial, grants access.
  bool get isActiveProviderEntitlement =>
      plan == UserPlan.pro &&
      isActive &&
      _verifiedProviderSources.contains(purchasePlatform);

  /// The effective plan (downgrades to free if expired)
  UserPlan get effectivePlan {
    if (isActive) return plan;
    return UserPlan.free;
  }

  /// Create from Firebase document data
  factory SubscriptionStatus.fromFirestore(Map<String, dynamic>? data) {
    if (data == null) return SubscriptionStatus.free;

    return SubscriptionStatus(
      plan: UserPlan.fromString(data['plan'] as String?),
      // Support both 'expiresAt' (Play Store/App Store) and 'expiryDate' (Razorpay/trial)
      // Prefer 'expiresAt' as the canonical field from store-verified purchases
      expiresAt: _parseDateTime(data['expiresAt'] ?? data['expiryDate']),
      billingPeriod: _parseBillingPeriod(data['billingPeriod'] as String?),
      inGracePeriod: data['inGracePeriod'] as bool? ?? false,
      gracePeriodEndsAt: _parseDateTime(data['gracePeriodEndsAt']),
      renewalState: _parseRenewalState(data),
      subscriptionState:
          (data['subscriptionState'] ?? data['status']) as String?,
      // `source` is the canonical provider. purchasePlatform is a legacy alias
      // and may still contain `trial` briefly while a server write propagates.
      purchasePlatform: (data['source'] ?? data['purchasePlatform']) as String?,
      storeSubscriptionId:
          (data['storeSubscriptionId'] ?? data['razorpaySubscriptionId'])
              as String?,
      lastVerifiedAt: _parseDateTime(
        data['lastVerifiedAt'] ?? data['updatedAt'],
      ),
    );
  }

  /// Parse DateTime from Firestore - handles both Timestamp and String
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Convert to map for Firebase storage
  Map<String, dynamic> toFirestore() {
    return {
      'plan': plan.toStorageString(),
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      if (billingPeriod != null) 'billingPeriod': billingPeriod!.name,
      'inGracePeriod': inGracePeriod,
      if (gracePeriodEndsAt != null)
        'gracePeriodEndsAt': gracePeriodEndsAt!.toIso8601String(),
      'renewalState': renewalState.name,
      if (renewalState != RenewalState.unknown)
        'willAutoRenew': renewalState == RenewalState.renewing,
      if (subscriptionState != null) 'subscriptionState': subscriptionState,
      if (purchasePlatform != null) 'source': purchasePlatform,
      if (storeSubscriptionId != null)
        'storeSubscriptionId': storeSubscriptionId,
      if (lastVerifiedAt != null)
        'lastVerifiedAt': lastVerifiedAt!.toIso8601String(),
    };
  }

  static BillingPeriod? _parseBillingPeriod(String? value) {
    switch (value?.toLowerCase()) {
      case 'monthly':
        return BillingPeriod.monthly;
      case 'yearly':
        return BillingPeriod.yearly;
      default:
        return null;
    }
  }

  static RenewalState _parseRenewalState(Map<String, dynamic> data) {
    final typed = RenewalState.tryParse(data['renewalState']);
    if (typed != null) return typed;

    final legacy = data['willAutoRenew'] ?? data['autoRenew'];
    if (legacy is bool) {
      return legacy ? RenewalState.renewing : RenewalState.notRenewing;
    }

    final providerState = (data['subscriptionState'] ?? data['status'])
        ?.toString()
        .toUpperCase();
    if (providerState == 'SUBSCRIPTION_STATE_CANCELED' ||
        providerState == 'CANCELED' ||
        providerState == 'CANCELLED') {
      return RenewalState.notRenewing;
    }
    return RenewalState.unknown;
  }

  SubscriptionStatus copyWith({
    UserPlan? plan,
    DateTime? expiresAt,
    BillingPeriod? billingPeriod,
    bool? inGracePeriod,
    DateTime? gracePeriodEndsAt,
    RenewalState? renewalState,
    bool? willAutoRenew,
    String? subscriptionState,
    String? purchasePlatform,
    String? storeSubscriptionId,
    DateTime? lastVerifiedAt,
  }) {
    return SubscriptionStatus(
      plan: plan ?? this.plan,
      expiresAt: expiresAt ?? this.expiresAt,
      billingPeriod: billingPeriod ?? this.billingPeriod,
      inGracePeriod: inGracePeriod ?? this.inGracePeriod,
      gracePeriodEndsAt: gracePeriodEndsAt ?? this.gracePeriodEndsAt,
      renewalState:
          renewalState ??
          (willAutoRenew == null
              ? this.renewalState
              : willAutoRenew
              ? RenewalState.renewing
              : RenewalState.notRenewing),
      subscriptionState: subscriptionState ?? this.subscriptionState,
      purchasePlatform: purchasePlatform ?? this.purchasePlatform,
      storeSubscriptionId: storeSubscriptionId ?? this.storeSubscriptionId,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
    );
  }

  @override
  String toString() {
    return 'SubscriptionStatus(plan: ${plan.displayName}, '
        'active: $isActive, expires: $expiresAt)';
  }
}
