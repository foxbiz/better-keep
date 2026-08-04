import 'package:better_keep/services/auth_error_messages.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
  test('Apple invalid credential resolves to a stable failure kind', () {
    final failure = resolveSignInFailure(
      provider: 'apple',
      error: FirebaseAuthException(
        code: 'invalid-credential',
        message: 'Invalid OAuth response from apple.com',
      ),
    );

    expect(failure, AuthFailureKind.appleVerification);
  });

  test('password invalid credential keeps password guidance', () {
    final failure = resolveSignInFailure(
      provider: 'password',
      error: FirebaseAuthException(
        code: 'invalid-credential',
        message: 'The supplied auth credential is incorrect.',
      ),
    );

    expect(failure, AuthFailureKind.invalidCredentials);
  });

  test('native Google cancellation resolves to cancelled', () {
    final failure = resolveSignInFailure(
      provider: 'google',
      error: const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
      ),
    );

    expect(failure, AuthFailureKind.cancelled);
  });

  test('native Apple cancellation resolves to cancelled', () {
    final failure = resolveSignInFailure(
      provider: 'apple',
      error: const SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.canceled,
        message: 'The authorization request was cancelled.',
      ),
    );

    expect(failure, AuthFailureKind.cancelled);
  });

  test('non-cancellation provider exceptions remain generic', () {
    final googleFailure = resolveSignInFailure(
      provider: 'google',
      error: const GoogleSignInException(
        code: GoogleSignInExceptionCode.providerConfigurationError,
        description: 'Sensitive provider details',
      ),
    );
    final appleFailure = resolveSignInFailure(
      provider: 'apple',
      error: const SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.failed,
        message: 'Sensitive provider details',
      ),
    );

    expect(googleFailure, AuthFailureKind.unknown);
    expect(appleFailure, AuthFailureKind.unknown);
  });

  test('unknown provider errors never expose provider messages', () {
    final failure = resolveSignInFailure(
      provider: 'apple',
      error: FirebaseAuthException(
        code: 'operation-not-allowed',
        message: 'Apple sign-in is disabled.',
      ),
    );

    expect(failure, AuthFailureKind.unknown);
  });
}
