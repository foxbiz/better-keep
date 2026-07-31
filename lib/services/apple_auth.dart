import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

enum AppleAuthFlow { webPopup, firebaseProvider, nativeCredential, unsupported }

AppleAuthFlow appleAuthFlowFor({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return AppleAuthFlow.webPopup;

  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.windows => AppleAuthFlow.firebaseProvider,
    TargetPlatform.iOS ||
    TargetPlatform.macOS => AppleAuthFlow.nativeCredential,
    TargetPlatform.fuchsia || TargetPlatform.linux => AppleAuthFlow.unsupported,
  };
}

bool supportsAppleAuth({
  required bool isWeb,
  required TargetPlatform platform,
}) =>
    appleAuthFlowFor(isWeb: isWeb, platform: platform) !=
    AppleAuthFlow.unsupported;

AppleAuthProvider buildAppleAuthProvider() => AppleAuthProvider()
  ..addScope('email')
  ..addScope('name');

Future<T> runAppleAuthFlow<T>({
  required AppleAuthFlow flow,
  required Future<T> Function() webPopup,
  required Future<T> Function() firebaseProvider,
  required Future<T> Function() nativeCredential,
}) {
  return switch (flow) {
    AppleAuthFlow.webPopup => webPopup(),
    AppleAuthFlow.firebaseProvider => firebaseProvider(),
    AppleAuthFlow.nativeCredential => nativeCredential(),
    AppleAuthFlow.unsupported => Future<T>.error(
      UnsupportedError('Sign in with Apple is not supported on this platform'),
    ),
  };
}

@immutable
class AppleNonce {
  const AppleNonce._({required this.raw, required this.hashed});

  static const _characters =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';

  final String raw;
  final String hashed;

  factory AppleNonce.generate({Random? random, int length = 32}) {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'Must be greater than zero');
    }

    final source = random ?? Random.secure();
    final raw = List.generate(
      length,
      (_) => _characters[source.nextInt(_characters.length)],
    ).join();

    return AppleNonce.fromRaw(raw);
  }

  factory AppleNonce.fromRaw(String raw) {
    if (raw.isEmpty) {
      throw ArgumentError.value(raw, 'raw', 'Must not be empty');
    }

    return AppleNonce._(
      raw: raw,
      hashed: sha256.convert(utf8.encode(raw)).toString(),
    );
  }
}

OAuthCredential buildNativeAppleFirebaseCredential({
  required AuthorizationCredentialAppleID appleCredential,
  required String rawNonce,
}) {
  final identityToken = appleCredential.identityToken;
  if (identityToken == null || identityToken.isEmpty) {
    throw FirebaseAuthException(
      code: 'missing-apple-id-token',
      message: 'Apple did not return an identity token.',
    );
  }

  return AppleAuthProvider.credentialWithIDToken(
    identityToken,
    rawNonce,
    AppleFullPersonName(
      givenName: appleCredential.givenName,
      familyName: appleCredential.familyName,
    ),
  );
}
