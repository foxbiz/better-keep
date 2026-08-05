import 'package:better_keep/services/firebase_auth_redirect_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveNativeFirebaseAuthRedirectDomain', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      test('uses the branded domain for live $platform OAuth redirects', () {
        expect(
          resolveNativeFirebaseAuthRedirectDomain(
            isWeb: false,
            platform: platform,
            usesEmulators: false,
            configuredDomain: ' betterkeep.app ',
          ),
          'betterkeep.app',
        );
      });
    }

    test('does not override Firebase Auth emulator routing', () {
      expect(
        resolveNativeFirebaseAuthRedirectDomain(
          isWeb: false,
          platform: TargetPlatform.android,
          usesEmulators: true,
          configuredDomain: 'betterkeep.app',
        ),
        isNull,
      );
    });

    test('leaves web FirebaseOptions responsible for the auth domain', () {
      expect(
        resolveNativeFirebaseAuthRedirectDomain(
          isWeb: true,
          platform: TargetPlatform.android,
          usesEmulators: false,
          configuredDomain: 'betterkeep.app',
        ),
        isNull,
      );
    });

    for (final platform in [
      TargetPlatform.fuchsia,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      test('does not call the unsupported native setter on $platform', () {
        expect(
          resolveNativeFirebaseAuthRedirectDomain(
            isWeb: false,
            platform: platform,
            usesEmulators: false,
            configuredDomain: 'betterkeep.app',
          ),
          isNull,
        );
      });
    }

    test('rejects a missing live native auth domain', () {
      expect(
        () => resolveNativeFirebaseAuthRedirectDomain(
          isWeb: false,
          platform: TargetPlatform.android,
          usesEmulators: false,
          configuredDomain: '',
        ),
        throwsStateError,
      );
    });

    for (final invalidDomain in [
      'https://betterkeep.app',
      'betterkeep.app/path',
      'betterkeep.app:443',
      'betterkeep.app?source=oauth',
    ]) {
      test('rejects invalid auth domain "$invalidDomain"', () {
        expect(
          () => resolveNativeFirebaseAuthRedirectDomain(
            isWeb: false,
            platform: TargetPlatform.android,
            usesEmulators: false,
            configuredDomain: invalidDomain,
          ),
          throwsStateError,
        );
      });
    }
  });

  group('configureNativeFirebaseAuthRedirectDomain', () {
    test('applies the resolved domain exactly once', () {
      final appliedDomains = <String>[];

      configureNativeFirebaseAuthRedirectDomain(
        isWeb: false,
        platform: TargetPlatform.android,
        usesEmulators: false,
        configuredDomain: 'betterkeep.app',
        setDomain: appliedDomains.add,
      );

      expect(appliedDomains, ['betterkeep.app']);
    });

    test('does not invoke the setter when no override is needed', () {
      final appliedDomains = <String>[];

      configureNativeFirebaseAuthRedirectDomain(
        isWeb: false,
        platform: TargetPlatform.android,
        usesEmulators: true,
        configuredDomain: 'betterkeep.app',
        setDomain: appliedDomains.add,
      );

      expect(appliedDomains, isEmpty);
    });
  });
}
