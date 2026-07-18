import 'package:flutter/foundation.dart';

const String firebaseEmulatorLoopbackHost = '127.0.0.1';
const String androidEmulatorHost = '10.0.2.2';

/// Selects the address from which the current runtime can reach Firebase.
///
/// An explicit IPv4 loopback address is used for browsers and Apple
/// simulators because `localhost` may resolve to IPv6 while the Firebase CLI
/// is listening only on 127.0.0.1.
String selectFirebaseEmulatorHost({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isAndroidEmulator,
  required bool isAppleSimulator,
  required String physicalDeviceHost,
}) {
  if (isWeb) {
    return firebaseEmulatorLoopbackHost;
  }

  if (platform == TargetPlatform.android && isAndroidEmulator) {
    return androidEmulatorHost;
  }

  if (isAppleSimulator) {
    return firebaseEmulatorLoopbackHost;
  }

  return physicalDeviceHost;
}
