import 'package:flutter/foundation.dart';

/// Payment provider selected from the distribution platform.
///
/// Store availability is intentionally not part of this decision. In
/// particular, Android must remain on Google Play even when Play Billing is
/// temporarily unavailable.
enum PurchaseProvider { googlePlay, appStore, razorpay, unavailable }

/// Current readiness of the native app-store billing connection.
enum StoreReadiness { uninitialized, checking, ready, unavailable }

PurchaseProvider resolvePurchaseProvider({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return PurchaseProvider.razorpay;

  return switch (platform) {
    TargetPlatform.android => PurchaseProvider.googlePlay,
    TargetPlatform.iOS || TargetPlatform.macOS => PurchaseProvider.appStore,
    TargetPlatform.windows || TargetPlatform.linux => PurchaseProvider.razorpay,
    TargetPlatform.fuchsia => PurchaseProvider.unavailable,
  };
}

PurchaseProvider get currentPurchaseProvider =>
    resolvePurchaseProvider(isWeb: kIsWeb, platform: defaultTargetPlatform);
