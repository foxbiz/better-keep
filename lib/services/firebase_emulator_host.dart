import 'package:flutter/foundation.dart';

const String firebaseEmulatorLoopbackHost = '127.0.0.1';
const String androidEmulatorHost = '10.0.2.2';

enum FirebaseEnvironment { live, emulator }

enum GoogleEmulatorAuthMode { mock, real }

@immutable
class FirebaseEmulatorEndpoints {
  const FirebaseEmulatorEndpoints(this.host, {this.webProxyOrigin});

  static const int authPort = 9099;
  static const int firestorePort = 8080;
  static const int functionsPort = 5001;
  static const int hostingPort = 5002;
  static const int storagePort = 9199;
  static const int uiPort = 4000;

  final String host;
  final String? webProxyOrigin;

  String get routingIdentity =>
      webProxyOrigin == null ? host : '$host|$webProxyOrigin';

  Map<String, int> get requiredServices => const {
    'Authentication': authPort,
    'Cloud Firestore': firestorePort,
    'Cloud Functions': functionsPort,
    'Cloud Storage': storagePort,
    'Firebase Hosting': hostingPort,
  };

  String functionsBaseUrl({
    required String projectId,
    required String region,
  }) =>
      '${webProxyOrigin == null ? 'http://$host:$functionsPort' : '$webProxyOrigin/__emulator/functions'}/$projectId/$region';

  String get hostingBaseUrl => webProxyOrigin ?? 'http://$host:$hostingPort';
}

@immutable
class FirebaseEmulatorSettings {
  const FirebaseEmulatorSettings({
    required this.environment,
    this.endpoints,
    this.googleAuthMode = GoogleEmulatorAuthMode.mock,
  });

  const FirebaseEmulatorSettings.live()
    : environment = FirebaseEnvironment.live,
      endpoints = null,
      googleAuthMode = GoogleEmulatorAuthMode.mock;

  final FirebaseEnvironment environment;
  final FirebaseEmulatorEndpoints? endpoints;
  final GoogleEmulatorAuthMode googleAuthMode;

  bool get usesEmulators => environment == FirebaseEnvironment.emulator;
}

class FirebaseEmulatorUnavailableException implements Exception {
  FirebaseEmulatorUnavailableException({
    required this.host,
    required Map<String, Object> failures,
  }) : failures = Map.unmodifiable(failures);

  final String host;
  final Map<String, Object> failures;

  @override
  String toString() {
    final services = failures.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    return 'Firebase emulators are unreachable at $host.\n'
        '$services\n'
        'Check the host IP, emulator process, firewall, and Wi-Fi client '
        'isolation, then retry.';
  }
}

class FirebaseEmulatorRoutingException implements Exception {
  const FirebaseEmulatorRoutingException(this.cause);

  final Object cause;

  @override
  String toString() =>
      'Firebase emulator routing could not be completed: $cause. '
      'Restart the app before selecting another environment.';
}

class FirebaseEmulatorFirestoreProbeException implements Exception {
  const FirebaseEmulatorFirestoreProbeException({
    required this.projectId,
    required this.databaseId,
    required this.host,
    required this.uid,
    required this.code,
    required this.cause,
  });

  final String projectId;
  final String databaseId;
  final String host;
  final String uid;
  final String code;
  final Object cause;

  @override
  String toString() =>
      'The signed-in app could not reach the Firestore emulator '
      '(project=$projectId, database=$databaseId, host=$host, uid=$uid, '
      'code=$code). Cloud sync was not started. Check the saved emulator host, '
      'that Firestore is listening on the LAN interface, the device firewall '
      'and Wi-Fi client isolation, then retry. The app will not fall back to '
      'production. Cause: $cause';
}

/// Selects the address from which the current runtime can reach Firebase.
///
/// An explicit IPv4 loopback address is used for browsers, Apple simulators,
/// and same-machine desktop clients because `localhost` may resolve to IPv6
/// while the Firebase CLI is listening only on 127.0.0.1.
String selectFirebaseEmulatorHost({
  required bool isWeb,
  required TargetPlatform platform,
  required bool isAndroidEmulator,
  required bool isAppleSimulator,
  required String physicalDeviceHost,
  String configuredHost = '',
}) {
  final isPhysicalDevice =
      !isWeb &&
      ((platform == TargetPlatform.iOS && !isAppleSimulator) ||
          (platform == TargetPlatform.android && !isAndroidEmulator));
  // The debug screen uses EMULATOR_HOST only as an initial suggestion. Honor
  // the entered (or saved) LAN address when connecting a physical device.
  if (isPhysicalDevice && physicalDeviceHost.trim().isNotEmpty) {
    return normalizePhysicalFirebaseEmulatorHost(physicalDeviceHost);
  }
  if (configuredHost.trim().isNotEmpty) {
    final host = configuredHost.trim();
    final uri = Uri.tryParse('http://$host');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        host.contains('://')) {
      throw const FormatException(
        'EMULATOR_HOST must be a hostname or IP, without a scheme, path, or port.',
      );
    }
    return host;
  }
  if (isWeb) {
    return firebaseEmulatorLoopbackHost;
  }

  if (platform == TargetPlatform.android && isAndroidEmulator) {
    return androidEmulatorHost;
  }

  if (platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux) {
    final explicitHost = physicalDeviceHost.trim();
    return explicitHost.isEmpty ? firebaseEmulatorLoopbackHost : explicitHost;
  }

  if (isAppleSimulator) {
    return firebaseEmulatorLoopbackHost;
  }

  return physicalDeviceHost;
}

String? normalizeEmulatorWebOrigin(String value) {
  if (value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'EMULATOR_WEB_ORIGIN must be an HTTPS origin, without a path or credentials.',
    );
  }
  return uri.origin;
}

/// Validates and normalizes the LAN host entered for a physical device.
///
/// Emulator bind addresses, loopback addresses, URLs, and values containing
/// ports are rejected because they cannot route from a separate device.
String normalizePhysicalFirebaseEmulatorHost(String value) {
  final host = value.trim();
  if (host.isEmpty) {
    throw const FormatException(
      'Enter the LAN IP address or hostname of the computer running Firebase.',
    );
  }

  final lowerHost = host.toLowerCase();
  if (lowerHost.contains('://') ||
      lowerHost.contains('/') ||
      lowerHost.contains('?') ||
      lowerHost.contains('#') ||
      lowerHost.contains(':')) {
    throw const FormatException(
      'Enter only a host, without a URL scheme, path, or port.',
    );
  }

  if (lowerHost == 'localhost' ||
      lowerHost == firebaseEmulatorLoopbackHost ||
      lowerHost == '0.0.0.0' ||
      lowerHost == androidEmulatorHost ||
      lowerHost.startsWith('127.')) {
    throw const FormatException(
      'A physical device needs the computer’s LAN address, not a loopback or '
      'emulator-only address.',
    );
  }

  if (RegExp(r'^[0-9.]+$').hasMatch(lowerHost)) {
    if (_isValidIpv4Address(lowerHost)) return lowerHost;
    throw const FormatException('Enter a valid IPv4 address or hostname.');
  }

  if (_isValidHostname(lowerHost)) {
    return lowerHost;
  }

  throw const FormatException('Enter a valid IPv4 address or hostname.');
}

bool _isValidIpv4Address(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;

  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
  }
  return true;
}

bool _isValidHostname(String host) {
  if (host.length > 253 || !host.contains('.')) return false;
  final labels = host.split('.');
  final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  return labels.every(labelPattern.hasMatch);
}
