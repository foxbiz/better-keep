import 'package:better_keep/services/firebase_app_check_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('never activates in non-release builds', () {
    for (final platform in TargetPlatform.values) {
      expect(
        shouldActivateFirebaseAppCheck(
          isReleaseMode: false,
          isWeb: false,
          platform: platform,
          isAndroidEnabled: true,
        ),
        isFalse,
      );
    }
  });

  test('web activation remains enabled in release mode', () {
    expect(
      shouldActivateFirebaseAppCheck(
        isReleaseMode: true,
        isWeb: true,
        platform: TargetPlatform.android,
        isAndroidEnabled: false,
      ),
      isTrue,
    );
  });

  test('Android activation follows the emergency build flag', () {
    expect(
      shouldActivateFirebaseAppCheck(
        isReleaseMode: true,
        isWeb: false,
        platform: TargetPlatform.android,
        isAndroidEnabled: false,
      ),
      isFalse,
    );
    expect(
      shouldActivateFirebaseAppCheck(
        isReleaseMode: true,
        isWeb: false,
        platform: TargetPlatform.android,
        isAndroidEnabled: true,
      ),
      isTrue,
    );
  });

  test('Apple release activation remains enabled', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      expect(
        shouldActivateFirebaseAppCheck(
          isReleaseMode: true,
          isWeb: false,
          platform: platform,
          isAndroidEnabled: false,
        ),
        isTrue,
      );
    }
  });

  test('unsupported native platforms remain disabled', () {
    for (final platform in [
      TargetPlatform.fuchsia,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      expect(
        shouldActivateFirebaseAppCheck(
          isReleaseMode: true,
          isWeb: false,
          platform: platform,
          isAndroidEnabled: true,
        ),
        isFalse,
      );
    }
  });
}
