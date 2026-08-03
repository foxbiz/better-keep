import 'package:better_keep/services/firebase_apple_configuration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const valid = AppleFirebaseConfigurationSnapshot(
    runtimeBundleId: 'io.foxbiz.better-keep',
    expectedBundleId: 'io.foxbiz.better-keep',
    activeBundleId: 'io.foxbiz.better-keep',
    expectedAppId: '1:123:ios:correct',
    activeAppId: '1:123:ios:correct',
    expectedProjectId: 'better-keep-notes',
    activeProjectId: 'better-keep-notes',
  );

  test('accepts matching signed and Firebase Apple identities', () {
    expect(appleFirebaseConfigurationMismatches(valid), isEmpty);
    expect(
      () => validateAppleFirebaseConfigurationSnapshot(valid),
      returnsNormally,
    );
  });

  test('rejects stale native auto-initialization before Auth starts', () {
    const stale = AppleFirebaseConfigurationSnapshot(
      runtimeBundleId: 'io.foxbiz.better-keep',
      expectedBundleId: 'io.foxbiz.better-keep',
      activeBundleId: 'com.example.betterKeep',
      expectedAppId: '1:123:ios:correct',
      activeAppId: '1:123:ios:template',
      expectedProjectId: 'better-keep-notes',
      activeProjectId: 'better-keep-notes',
    );

    expect(
      () => validateAppleFirebaseConfigurationSnapshot(stale),
      throwsA(
        isA<FirebaseAppleConfigurationException>()
            .having(
              (error) => error.mismatches.join(' '),
              'mismatches',
              contains('com.example.betterKeep'),
            )
            .having(
              (error) => error.toString(),
              'remediation',
              contains('Replace the Apple Firebase configuration'),
            ),
      ),
    );
  });

  test('validates only live native Apple platforms', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      expect(
        usesNativeAppleFirebaseConfiguration(
          isWeb: false,
          platform: platform,
          usesEmulators: false,
        ),
        isTrue,
      );
      expect(
        usesNativeAppleFirebaseConfiguration(
          isWeb: false,
          platform: platform,
          usesEmulators: true,
        ),
        isFalse,
      );
    }

    expect(
      usesNativeAppleFirebaseConfiguration(
        isWeb: true,
        platform: TargetPlatform.iOS,
        usesEmulators: false,
      ),
      isFalse,
    );
    expect(
      usesNativeAppleFirebaseConfiguration(
        isWeb: false,
        platform: TargetPlatform.android,
        usesEmulators: false,
      ),
      isFalse,
    );
  });
}
