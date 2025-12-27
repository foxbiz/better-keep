import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

const databaseVersion = 2;
const databaseName = "better_keep.db";
const bigScreenWidthThreshold = 800;
const appLabel = "Better Keep Notes";
const defaultAlarmSound = "assets/sounds/2.mp3";

/// Demo account email for Google Play review and testing.
/// This account bypasses certain features for easier testing.
const String demoAccountEmail = 'better.keep.review@gmail.com';

/// App store URLs
const String playStoreUrl =
    'https://play.google.com/store/apps/details?id=io.foxbiz.better_keep';
const String microsoftStoreUrl =
    'https://apps.microsoft.com/detail/9PHT5C6WK6Q1';
const String appDeepLinkScheme = 'betterkeep://';

/// Cached platform detection values - computed once at startup
final bool isDesktop = _computeIsDesktop();
final bool isAlarmSupported = _computeIsAlarmSupported();
final bool isMobile = _computeIsMobile();

bool _computeIsDesktop() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

bool _computeIsAlarmSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

bool _computeIsMobile() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
