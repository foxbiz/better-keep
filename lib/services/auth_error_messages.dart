import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

enum AuthFailureKind {
  appleVerification,
  accountExists,
  accountNotFound,
  invalidCredentials,
  accountDisabled,
  tooManyRequests,
  network,
  cancelled,
  permissionDenied,
  unavailable,
  missingEmail,
  windowClosed,
  insecureConnection,
  unknown,
}

enum VerificationFailureKind {
  invalidCode,
  tooManyRequests,
  network,
  signInRequired,
  unknown,
}

VerificationFailureKind resolveVerificationFailure(
  Object error, {
  bool codeWasSubmitted = false,
}) {
  if (error is! FirebaseFunctionsException) {
    return VerificationFailureKind.unknown;
  }

  return switch (error.code) {
    'invalid-argument' || 'not-found' || 'failed-precondition'
        when codeWasSubmitted =>
      VerificationFailureKind.invalidCode,
    'resource-exhausted' => VerificationFailureKind.tooManyRequests,
    'unavailable' || 'deadline-exceeded' => VerificationFailureKind.network,
    'unauthenticated' ||
    'permission-denied' => VerificationFailureKind.signInRequired,
    _ => VerificationFailureKind.unknown,
  };
}

AuthFailureKind resolveSignInFailure({
  required String provider,
  required Object error,
}) {
  if (error is GoogleSignInException &&
      error.code == GoogleSignInExceptionCode.canceled) {
    return AuthFailureKind.cancelled;
  }
  if (error is SignInWithAppleAuthorizationException &&
      error.code == AuthorizationErrorCode.canceled) {
    return AuthFailureKind.cancelled;
  }
  if (error is! FirebaseAuthException) return AuthFailureKind.unknown;
  final code = error.code;

  if (provider == 'apple' && code == 'invalid-credential') {
    return AuthFailureKind.appleVerification;
  }
  if (code == 'account-exists-with-different-credential' ||
      code == 'email-already-in-use') {
    return AuthFailureKind.accountExists;
  }
  if (code == 'user-not-found') {
    return AuthFailureKind.accountNotFound;
  }
  if (code == 'wrong-password' || code == 'invalid-credential') {
    return AuthFailureKind.invalidCredentials;
  }
  if (code == 'user-disabled') {
    return AuthFailureKind.accountDisabled;
  }
  if (code == 'too-many-requests') {
    return AuthFailureKind.tooManyRequests;
  }
  if (code == 'network-request-failed' ||
      code == 'timeout' ||
      code == 'deadline-exceeded') {
    return AuthFailureKind.network;
  }
  if (code == 'cancelled' ||
      code == 'popup-closed-by-user' ||
      code == 'user-cancelled') {
    return AuthFailureKind.cancelled;
  }
  if (code == 'permission-denied') {
    return AuthFailureKind.permissionDenied;
  }
  if (code == 'unavailable' || code == 'launch-failed') {
    return AuthFailureKind.unavailable;
  }
  if (code == 'internal-error') {
    return AuthFailureKind.missingEmail;
  }
  if (code == 'web-context-cancelled') {
    return AuthFailureKind.windowClosed;
  }
  if (code == 'operation-not-supported-in-this-environment' ||
      code == 'web-storage-unsupported') {
    return AuthFailureKind.insecureConnection;
  }
  return AuthFailureKind.unknown;
}

bool isInsecureSignInError(Object error) {
  return error is FirebaseAuthException &&
      (error.code == 'operation-not-supported-in-this-environment' ||
          error.code == 'web-storage-unsupported');
}
