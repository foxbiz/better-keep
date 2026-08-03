import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_bootstrap_coordinator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

typedef PackageInfoLoader = Future<PackageInfo> Function();

@immutable
class AppleFirebaseConfigurationSnapshot {
  const AppleFirebaseConfigurationSnapshot({
    required this.runtimeBundleId,
    required this.expectedBundleId,
    required this.activeBundleId,
    required this.expectedAppId,
    required this.activeAppId,
    required this.expectedProjectId,
    required this.activeProjectId,
  });

  final String runtimeBundleId;
  final String? expectedBundleId;
  final String? activeBundleId;
  final String expectedAppId;
  final String activeAppId;
  final String expectedProjectId;
  final String activeProjectId;
}

class FirebaseAppleConfigurationException
    implements Exception, NonRetryableFirebaseBootstrapError {
  const FirebaseAppleConfigurationException(this.mismatches);

  final List<String> mismatches;

  @override
  String toString() =>
      'Firebase Apple configuration does not match the signed application: '
      '${mismatches.join('; ')}. Replace the Apple Firebase configuration '
      'and restart the app before signing in.';
}

bool usesNativeAppleFirebaseConfiguration({
  required bool isWeb,
  required TargetPlatform platform,
  required bool usesEmulators,
}) {
  if (isWeb || usesEmulators) return false;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

List<String> appleFirebaseConfigurationMismatches(
  AppleFirebaseConfigurationSnapshot snapshot,
) {
  final mismatches = <String>[];

  void compare(String label, String? actual, String? expected) {
    final normalizedActual = actual?.trim();
    final normalizedExpected = expected?.trim();
    if (normalizedActual == null ||
        normalizedActual.isEmpty ||
        normalizedExpected == null ||
        normalizedExpected.isEmpty ||
        normalizedActual != normalizedExpected) {
      mismatches.add(
        '$label is "${normalizedActual ?? '<missing>'}", expected '
        '"${normalizedExpected ?? '<missing>'}"',
      );
    }
  }

  compare(
    'runtime bundle ID',
    snapshot.runtimeBundleId,
    snapshot.expectedBundleId,
  );
  compare(
    'active Firebase bundle ID',
    snapshot.activeBundleId,
    snapshot.expectedBundleId,
  );
  compare(
    'active Firebase app ID',
    snapshot.activeAppId,
    snapshot.expectedAppId,
  );
  compare(
    'active Firebase project ID',
    snapshot.activeProjectId,
    snapshot.expectedProjectId,
  );

  return mismatches;
}

Future<AppleFirebaseConfigurationSnapshot?>
snapshotActiveAppleFirebaseConfiguration({
  required FirebaseBackendConfiguration configuration,
  required FirebaseOptions expectedOptions,
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
  PackageInfoLoader? packageInfoLoader,
}) async {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  if (!usesNativeAppleFirebaseConfiguration(
    isWeb: isWeb,
    platform: resolvedPlatform,
    usesEmulators: configuration.usesEmulators,
  )) {
    return null;
  }

  final packageInfo = await (packageInfoLoader ?? PackageInfo.fromPlatform)();
  final activeOptions = configuration.app.options;
  return AppleFirebaseConfigurationSnapshot(
    runtimeBundleId: packageInfo.packageName,
    expectedBundleId: expectedOptions.iosBundleId,
    activeBundleId: activeOptions.iosBundleId,
    expectedAppId: expectedOptions.appId,
    activeAppId: activeOptions.appId,
    expectedProjectId: expectedOptions.projectId,
    activeProjectId: activeOptions.projectId,
  );
}

Future<void> validateActiveAppleFirebaseConfiguration({
  required FirebaseBackendConfiguration configuration,
  required FirebaseOptions expectedOptions,
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
  PackageInfoLoader? packageInfoLoader,
}) async {
  final snapshot = await snapshotActiveAppleFirebaseConfiguration(
    configuration: configuration,
    expectedOptions: expectedOptions,
    isWeb: isWeb,
    platform: platform,
    packageInfoLoader: packageInfoLoader,
  );
  if (snapshot == null) return;

  validateAppleFirebaseConfigurationSnapshot(snapshot);
}

void validateAppleFirebaseConfigurationSnapshot(
  AppleFirebaseConfigurationSnapshot snapshot,
) {
  final mismatches = appleFirebaseConfigurationMismatches(snapshot);
  if (mismatches.isNotEmpty) {
    throw FirebaseAppleConfigurationException(mismatches);
  }
}

Future<String> activeAppleFirebaseDiagnosticContext({
  PackageInfoLoader? packageInfoLoader,
}) async {
  var runtimeBundleId = '<unavailable>';
  try {
    runtimeBundleId =
        (await (packageInfoLoader ?? PackageInfo.fromPlatform)()).packageName;
  } catch (_) {
    // Diagnostics must not replace the original authentication error.
  }

  final active = FirebaseBackend.active;
  final options = active.app.options;
  return 'firebaseApp=${active.appName}, appId=${options.appId}, '
      'project=${options.projectId}, configuredBundle=${options.iosBundleId}, '
      'runtimeBundle=$runtimeBundleId';
}
