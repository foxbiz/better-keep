import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const physicalDeviceHost = '192.168.1.25';

  String selectHost({
    bool isWeb = false,
    TargetPlatform platform = TargetPlatform.iOS,
    bool isAndroidEmulator = false,
    bool isAppleSimulator = false,
  }) {
    return selectFirebaseEmulatorHost(
      isWeb: isWeb,
      platform: platform,
      isAndroidEmulator: isAndroidEmulator,
      isAppleSimulator: isAppleSimulator,
      physicalDeviceHost: physicalDeviceHost,
    );
  }

  group('selectFirebaseEmulatorHost', () {
    test('uses explicit IPv4 loopback for browsers', () {
      expect(
        selectHost(isWeb: true, platform: TargetPlatform.linux),
        firebaseEmulatorLoopbackHost,
      );
    });

    test('uses the Android host alias for an Android emulator', () {
      expect(
        selectHost(platform: TargetPlatform.android, isAndroidEmulator: true),
        androidEmulatorHost,
      );
    });

    test('uses IPv4 loopback for an Apple simulator', () {
      expect(
        selectHost(platform: TargetPlatform.iOS, isAppleSimulator: true),
        firebaseEmulatorLoopbackHost,
      );
    });

    test('uses the configured LAN address for a physical device', () {
      expect(selectHost(), physicalDeviceHost);
    });
  });
}
