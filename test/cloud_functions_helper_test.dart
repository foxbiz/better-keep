import 'dart:convert';

import 'package:better_keep/services/auth_error_messages.dart';
import 'package:better_keep/services/cloud_functions_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HTTP cooldown details reach the code-entry decision', () {
    final details = {
      'reason': 'deletion-otp-cooldown',
      'email': 'sy*****@example.invalid',
      'retryAfterSeconds': 42,
    };
    final error = parseCloudFunctionError(
      jsonEncode({
        'error': {
          'status': 'RESOURCE_EXHAUSTED',
          'message': 'Wait before requesting another code',
          'details': details,
        },
      }),
    );

    expect(error.code, 'resource-exhausted');
    expect(error.details, details);
    expect(deletionOtpCooldown(error), details);
  });

  test('HTTP deletion-in-progress error remains terminal and actionable', () {
    final error = parseCloudFunctionError(
      jsonEncode({
        'error': {
          'status': 'FAILED_PRECONDITION',
          'message': 'Account deletion has already started. Contact support.',
          'details': {'reason': 'account-deletion-in-progress'},
        },
      }),
    );

    expect(isAccountDeletionInProgress(error), isTrue);
    expect(
      resolveSignInFailure(provider: 'google', error: error),
      AuthFailureKind.deletionInProgress,
    );
  });

  test('older responses without details keep their status and message', () {
    final error = parseCloudFunctionError(
      jsonEncode({
        'error': {'status': 'UNAUTHENTICATED', 'message': 'Sign in again'},
      }),
    );
    expect(error.code, 'unauthenticated');
    expect(error.message, 'Sign in again');
    expect(error.details, isNull);
    expect(deletionOtpCooldown(error), isNull);
  });

  test(
    'malformed proxy responses become generic errors, not parsing failures',
    () {
      for (final body in [
        '<html>Unavailable</html>',
        '[]',
        '{"error":"unavailable"}',
        '{"error":{"status":503,"message":[],"details":null}}',
      ]) {
        final error = parseCloudFunctionError(body);
        expect(error.code, 'internal');
        expect(error.message, 'Cloud Function call failed');
        expect(isAccountDeletionInProgress(error), isFalse);
      }
    },
  );
}
