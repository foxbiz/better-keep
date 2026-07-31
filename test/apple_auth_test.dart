import 'dart:math';

import 'package:better_keep/services/apple_auth.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
  group('Apple auth platform policy', () {
    test('uses popup auth on web regardless of browser platform', () {
      for (final platform in TargetPlatform.values) {
        expect(
          appleAuthFlowFor(isWeb: true, platform: platform),
          AppleAuthFlow.webPopup,
        );
        expect(supportsAppleAuth(isWeb: true, platform: platform), isTrue);
      }
    });

    test('uses Firebase provider auth on Android and Windows', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        expect(
          appleAuthFlowFor(isWeb: false, platform: platform),
          AppleAuthFlow.firebaseProvider,
        );
        expect(supportsAppleAuth(isWeb: false, platform: platform), isTrue);
      }
    });

    test('uses native credentials on Apple platforms', () {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(
          appleAuthFlowFor(isWeb: false, platform: platform),
          AppleAuthFlow.nativeCredential,
        );
        expect(supportsAppleAuth(isWeb: false, platform: platform), isTrue);
      }
    });

    test('rejects unsupported native platforms', () {
      for (final platform in [TargetPlatform.fuchsia, TargetPlatform.linux]) {
        expect(
          appleAuthFlowFor(isWeb: false, platform: platform),
          AppleAuthFlow.unsupported,
        );
        expect(supportsAppleAuth(isWeb: false, platform: platform), isFalse);
      }
    });
  });

  test('Apple Firebase provider requests email and name', () {
    final provider = buildAppleAuthProvider();

    expect(provider.providerId, 'apple.com');
    expect(provider.scopes, unorderedEquals(['email', 'name']));
  });

  group('Apple auth dispatch', () {
    test('web flow invokes only the popup delegate', () async {
      var webCalls = 0;
      var firebaseCalls = 0;
      var nativeCalls = 0;

      final result = await runAppleAuthFlow<String>(
        flow: AppleAuthFlow.webPopup,
        webPopup: () async {
          webCalls++;
          return 'web';
        },
        firebaseProvider: () async {
          firebaseCalls++;
          return 'firebase';
        },
        nativeCredential: () async {
          nativeCalls++;
          return 'native';
        },
      );

      expect(result, 'web');
      expect(webCalls, 1);
      expect(firebaseCalls, 0);
      expect(nativeCalls, 0);
    });

    test('provider flow invokes only the Firebase delegate', () async {
      var webCalls = 0;
      var firebaseCalls = 0;
      var nativeCalls = 0;

      final result = await runAppleAuthFlow<String>(
        flow: AppleAuthFlow.firebaseProvider,
        webPopup: () async {
          webCalls++;
          return 'web';
        },
        firebaseProvider: () async {
          firebaseCalls++;
          return 'firebase';
        },
        nativeCredential: () async {
          nativeCalls++;
          return 'native';
        },
      );

      expect(result, 'firebase');
      expect(webCalls, 0);
      expect(firebaseCalls, 1);
      expect(nativeCalls, 0);
    });

    test('Apple-platform flow invokes only the native delegate', () async {
      var webCalls = 0;
      var firebaseCalls = 0;
      var nativeCalls = 0;

      final result = await runAppleAuthFlow<String>(
        flow: AppleAuthFlow.nativeCredential,
        webPopup: () async {
          webCalls++;
          return 'web';
        },
        firebaseProvider: () async {
          firebaseCalls++;
          return 'firebase';
        },
        nativeCredential: () async {
          nativeCalls++;
          return 'native';
        },
      );

      expect(result, 'native');
      expect(webCalls, 0);
      expect(firebaseCalls, 0);
      expect(nativeCalls, 1);
    });

    test('unsupported flow invokes neither delegate', () async {
      var calls = 0;

      await expectLater(
        runAppleAuthFlow<void>(
          flow: AppleAuthFlow.unsupported,
          webPopup: () async {
            calls++;
          },
          firebaseProvider: () async {
            calls++;
          },
          nativeCredential: () async {
            calls++;
          },
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(calls, 0);
    });

    for (final flow in [
      AppleAuthFlow.webPopup,
      AppleAuthFlow.firebaseProvider,
      AppleAuthFlow.nativeCredential,
    ]) {
      test('${flow.name} propagates the selected delegate error', () async {
        final error = StateError('${flow.name}-failed');

        Future<String> delegate(AppleAuthFlow delegateFlow) async {
          if (delegateFlow != flow) {
            fail('Invoked ${delegateFlow.name} instead of ${flow.name}');
          }
          throw error;
        }

        await expectLater(
          runAppleAuthFlow<String>(
            flow: flow,
            webPopup: () => delegate(AppleAuthFlow.webPopup),
            firebaseProvider: () => delegate(AppleAuthFlow.firebaseProvider),
            nativeCredential: () => delegate(AppleAuthFlow.nativeCredential),
          ),
          throwsA(same(error)),
        );
      });
    }
  });

  group('native Apple credentials', () {
    test('hashes the raw nonce and generates a new nonce per attempt', () {
      final fixed = AppleNonce.fromRaw('fixed-nonce');
      expect(
        fixed.hashed,
        'a19f92cd4f03a707e7352e2d718a0a3457948954255108a51cfe9a07c57b886b',
      );

      final random = Random(7);
      final first = AppleNonce.generate(random: random);
      final second = AppleNonce.generate(random: random);

      expect(first.raw, hasLength(32));
      expect(second.raw, hasLength(32));
      expect(first.raw, isNot(second.raw));
      expect(first.hashed, hasLength(64));
      expect(second.hashed, hasLength(64));
    });

    test('passes the identity token and raw nonce to Firebase', () {
      const appleCredential = AuthorizationCredentialAppleID(
        userIdentifier: 'apple-user',
        givenName: 'Test',
        familyName: 'User',
        authorizationCode: 'authorization-code-is-not-an-access-token',
        email: 'test@example.com',
        identityToken: 'identity-token',
        state: null,
      );

      final credential = buildNativeAppleFirebaseCredential(
        appleCredential: appleCredential,
        rawNonce: 'raw-nonce',
      );

      expect(credential.providerId, 'apple.com');
      expect(credential.signInMethod, 'apple.com');
      expect(credential, isA<AppleAuthCredential>());
      expect(credential.idToken, 'identity-token');
      expect(credential.rawNonce, 'raw-nonce');
      expect(credential.accessToken, isNull);
      expect(credential.appleFullPersonName?.givenName, 'Test');
      expect(credential.appleFullPersonName?.familyName, 'User');
    });

    test('rejects a missing identity token', () {
      const appleCredential = AuthorizationCredentialAppleID(
        userIdentifier: 'apple-user',
        givenName: null,
        familyName: null,
        authorizationCode: 'authorization-code',
        email: null,
        identityToken: null,
        state: null,
      );

      expect(
        () => buildNativeAppleFirebaseCredential(
          appleCredential: appleCredential,
          rawNonce: 'raw-nonce',
        ),
        throwsA(
          isA<FirebaseAuthException>().having(
            (error) => error.code,
            'code',
            'missing-apple-id-token',
          ),
        ),
      );
    });
  });
}
