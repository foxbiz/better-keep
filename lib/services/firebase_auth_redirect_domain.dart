import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

typedef FirebaseAuthDomainSetter = void Function(String domain);

/// Returns the custom Firebase Auth redirect domain for native platforms that
/// support provider-managed OAuth redirects.
///
/// Web and Windows receive their auth domain through [FirebaseOptions].
/// Emulator sessions deliberately keep the emulator's own routing.
@visibleForTesting
String? resolveNativeFirebaseAuthRedirectDomain({
  required bool isWeb,
  required TargetPlatform platform,
  required bool usesEmulators,
  required String? configuredDomain,
}) {
  if (isWeb || usesEmulators) return null;

  final supportsNativeCustomDomain = switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.windows => false,
  };
  if (!supportsNativeCustomDomain) return null;

  final domain = configuredDomain?.trim();
  if (domain == null || domain.isEmpty) {
    throw StateError(
      'A Firebase Auth redirect domain is required for live $platform builds.',
    );
  }

  final parsed = Uri.tryParse('https://$domain');
  if (parsed == null ||
      parsed.host != domain ||
      parsed.hasPort ||
      parsed.path.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty) {
    throw StateError(
      'Firebase Auth redirect domain must be a hostname without a scheme, '
      'port, path, query, or fragment: "$domain".',
    );
  }

  return domain;
}

/// Applies the configured domain directly to the native Firebase Auth instance.
///
/// Android and Apple platforms may auto-create the default Firebase app from
/// native configuration before Dart initializes Firebase. In that case,
/// [FirebaseOptions.authDomain] is not copied to the existing native Auth
/// instance, so it must be applied explicitly before any provider flow starts.
void configureNativeFirebaseAuthRedirectDomain({
  required bool isWeb,
  required TargetPlatform platform,
  required bool usesEmulators,
  required String? configuredDomain,
  FirebaseAuth? firebaseAuth,
  FirebaseAuthDomainSetter? setDomain,
}) {
  final domain = resolveNativeFirebaseAuthRedirectDomain(
    isWeb: isWeb,
    platform: platform,
    usesEmulators: usesEmulators,
    configuredDomain: configuredDomain,
  );
  if (domain == null) return;

  (setDomain ?? (value) => _setFirebaseAuthDomain(firebaseAuth, value))(domain);
}

void _setFirebaseAuthDomain(FirebaseAuth? firebaseAuth, String domain) {
  if (firebaseAuth == null) {
    throw StateError(
      'The selected FirebaseAuth instance is required before configuring its '
      'redirect domain.',
    );
  }
  firebaseAuth.customAuthDomain = domain;
}
