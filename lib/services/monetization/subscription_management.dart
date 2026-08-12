enum SubscriptionManagementPlatform {
  web,
  ios,
  android,
  macos,
  windows,
  linux,
  other,
}

enum SubscriptionManagementAction {
  razorpayApi,
  appStoreNative,
  externalUrl,
  contactSupport,
}

class SubscriptionManagementTarget {
  const SubscriptionManagementTarget({
    required this.action,
    this.url,
    this.pendingMessage,
  });

  final SubscriptionManagementAction action;
  final String? url;
  final String? pendingMessage;
}

const appleSubscriptionsUrl = 'https://apps.apple.com/account/subscriptions';
const googlePlaySubscriptionsUrl =
    'https://play.google.com/store/account/subscriptions?sku=better_keep_pro&package=io.foxbiz.better_keep';

/// Resolves the store currently handling native billing. This is intentionally
/// separate from [resolveSubscriptionManagementTarget]: ownership conflicts
/// clear local entitlement data, so there may be no saved provider left even
/// though the store that reported the conflict is known.
SubscriptionManagementTarget resolveCurrentStoreManagementTarget(
  SubscriptionManagementPlatform currentPlatform,
) {
  switch (currentPlatform) {
    case SubscriptionManagementPlatform.android:
      return resolveSubscriptionManagementTarget(
        purchasePlatform: 'play_store',
        currentPlatform: currentPlatform,
      );
    case SubscriptionManagementPlatform.ios:
    case SubscriptionManagementPlatform.macos:
      return resolveSubscriptionManagementTarget(
        purchasePlatform: 'app_store',
        currentPlatform: currentPlatform,
      );
    case SubscriptionManagementPlatform.web:
    case SubscriptionManagementPlatform.windows:
    case SubscriptionManagementPlatform.linux:
    case SubscriptionManagementPlatform.other:
      return const SubscriptionManagementTarget(
        action: SubscriptionManagementAction.contactSupport,
      );
  }
}

/// Resolves management from the purchase provider, not the current device.
SubscriptionManagementTarget resolveSubscriptionManagementTarget({
  required String? purchasePlatform,
  required SubscriptionManagementPlatform currentPlatform,
}) {
  switch (purchasePlatform) {
    case 'razorpay':
      return const SubscriptionManagementTarget(
        action: SubscriptionManagementAction.razorpayApi,
      );
    case 'app_store':
      final supportsNativeStoreKit =
          currentPlatform == SubscriptionManagementPlatform.ios;
      return SubscriptionManagementTarget(
        action: supportsNativeStoreKit
            ? SubscriptionManagementAction.appStoreNative
            : SubscriptionManagementAction.externalUrl,
        url: appleSubscriptionsUrl,
        pendingMessage: 'Manage your subscription in the App Store',
      );
    case 'play_store':
      return const SubscriptionManagementTarget(
        action: SubscriptionManagementAction.externalUrl,
        url: googlePlaySubscriptionsUrl,
        pendingMessage: 'Manage your subscription in the Play Store',
      );
    default:
      return const SubscriptionManagementTarget(
        action: SubscriptionManagementAction.contactSupport,
      );
  }
}
