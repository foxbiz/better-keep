import 'package:flutter/foundation.dart';

const bool androidAppCheckEnabled = bool.fromEnvironment(
  'APP_CHECK_ANDROID_ENABLED',
  defaultValue: false,
);

bool shouldActivateFirebaseAppCheck({
  required bool isReleaseMode,
  required bool isWeb,
  required TargetPlatform platform,
  bool isAndroidEnabled = androidAppCheckEnabled,
}) {
  if (!isReleaseMode) return false;
  if (isWeb) return true;

  return switch (platform) {
    TargetPlatform.android => isAndroidEnabled,
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.windows => false,
  };
}
