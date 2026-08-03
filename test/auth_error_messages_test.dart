import 'package:better_keep/services/auth_error_messages.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Apple invalid credential receives Apple-specific guidance', () {
    final message = resolveSignInErrorMessage(
      provider: 'apple',
      error: FirebaseAuthException(
        code: 'invalid-credential',
        message: 'Invalid OAuth response from apple.com',
      ),
    );

    expect(message, contains('Apple sign-in could not be verified'));
    expect(message, isNot(contains('password')));
  });

  test('password invalid credential keeps password guidance', () {
    final message = resolveSignInErrorMessage(
      provider: 'password',
      error: FirebaseAuthException(
        code: 'invalid-credential',
        message: 'The supplied auth credential is incorrect.',
      ),
    );

    expect(
      message,
      'Invalid credentials. Please check your password and try again.',
    );
  });

  test('provider errors retain Firebase messages when no policy matches', () {
    final message = resolveSignInErrorMessage(
      provider: 'apple',
      error: FirebaseAuthException(
        code: 'operation-not-allowed',
        message: 'Apple sign-in is disabled.',
      ),
    );

    expect(message, 'Apple sign-in is disabled.');
  });
}
