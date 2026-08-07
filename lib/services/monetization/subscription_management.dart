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
    'https://play.google.com/store/account/subscriptions';

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
