import 'package:better_keep/services/auth_error_messages.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
  test(
    'Auth wrapping preserves the deletion marker and paused callable reason',
    () {
      expect(
        isAccountDeletionInProgress(
          FirebaseAuthException(
            code: 'internal-error',
            message: '[account-deletion-in-progress] localized text',
          ),
        ),
        true,
      );
      expect(
        isAccountDeletionPaused(
          FirebaseFunctionsException(
            code: 'unavailable',
            message: 'Paused',
            details: {'reason': 'account-deletion-paused'},
          ),
        ),
        true,
      );
      expect(
        isAccountDeletionPaused(
          FirebaseFunctionsException(code: 'unavailable', message: 'Retry'),
        ),
        false,
      );
    },
  );
  test(
    'deletion errors are actionable and unrelated preconditions stay generic',
    () {
      final error = FirebaseFunctionsException(
        message: 'Synthetic test failure',
        code: 'failed-precondition',
        details: {'reason': 'account-deletion-in-progress'},
      );
      expect(isAccountDeletionInProgress(error), true);
      expect(
        resolveSignInFailure(provider: 'google', error: error),
        AuthFailureKind.deletionInProgress,
      );
      expect(
        isAccountDeletionInProgress(
          FirebaseFunctionsException(
            message: 'Synthetic test failure',
            code: 'failed-precondition',
          ),
        ),
        false,
      );
      expect(
        resolveSignInFailure(
          provider: 'google',
          error: FirebaseAuthException(
            code: 'internal-error',
            message: 'Account deletion has already started. Contact support.',
          ),
        ),
        AuthFailureKind.deletionInProgress,
      );
    },
  );
  test(
    'only deletion cooldown errors allow using the previously requested code',
    () {
      expect(
        deletionOtpCooldown(
          FirebaseFunctionsException(
            message: 'Synthetic test failure',
            code: 'resource-exhausted',
            details: {
              'reason': 'deletion-otp-cooldown',
              'retryAfterSeconds': 30,
            },
          ),
        )?['retryAfterSeconds'],
        30,
      );
      expect(
        deletionOtpCooldown(
          FirebaseFunctionsException(
            message: 'Synthetic test failure',
            code: 'resource-exhausted',
          ),
        ),
        null,
      );
    },
  );
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

  test('OAuth token failures never blame an email password', () {
    for (final provider in ['google', 'github', 'facebook', 'twitter']) {
      expect(
        resolveSignInFailure(
          provider: provider,
          error: FirebaseAuthException(code: 'invalid-credential'),
        ),
        AuthFailureKind.providerVerification,
      );
    }
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
