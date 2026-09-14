import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/auth_error_messages.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ja = lookupAppLocalizations(const Locale('ja'));

  test('OTP cooldown survives as localized remaining time', () {
    final error = FirebaseFunctionsException(
      code: 'resource-exhausted',
      message: 'Please wait 10 seconds before requesting a new code.',
    );
    for (final locale in [en, ja]) {
      expect(
        accountLinkFailureMessage(
          error,
          locale,
          providerName: 'GitHub',
          sendingCode: true,
        ),
        locale.resendCodeIn(10),
      );
    }
    for (final message in [
      'Sensitive server detail',
      'Please wait 999 seconds before requesting a new code.',
    ]) {
      expect(
        accountLinkFailureMessage(
          FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: message,
          ),
          en,
          providerName: 'GitHub',
        ),
        en.pleaseWaitBeforeRequesting,
      );
    }
  });

  test('callable errors give actionable account-link guidance', () {
    final cases = {
      'unauthenticated': en.pleaseSignInAgain,
      'failed-precondition': en.noEmailAssociated,
      'already-exists': en.providerAlreadyLinked('GitHub'),
      'deadline-exceeded': en.sessionExpired_,
      'unavailable': en.noInternetConnection,
      'internal': en.failedSendVerificationCode,
    };
    for (final entry in cases.entries) {
      expect(
        accountLinkFailureMessage(
          FirebaseFunctionsException(
            code: entry.key,
            message: 'Private diagnostic',
          ),
          en,
          providerName: 'GitHub',
          sendingCode: true,
        ),
        entry.value,
      );
    }
  });

  test('known legacy OAuth failures resolve without exposing arbitrary text', () {
    final cases = {
      'This github account is already associated with a different user. Please use a different github account.':
          en.emailAlreadyInUse,
      'A different github account is already linked. Please unlink it first before linking a new one.':
          en.providerAlreadyLinked('GitHub'),
      'User not found. Please sign in again.': en.pleaseSignInAgain,
      'Account-link authorization is invalid, expired, or already used':
          en.sessionExpired_,
      'Private provider diagnostic': en.failedLinkAccount,
    };
    for (final entry in cases.entries) {
      expect(
        accountLinkFailureMessage(
          FirebaseAuthException(code: 'oauth-error', message: entry.key),
          en,
          providerName: 'GitHub',
        ),
        entry.value,
      );
    }
    expect(
      resolveAccountLinkFailure(
        FirebaseAuthException(code: 'credential-already-in-use'),
      ),
      AccountLinkFailureKind.accountExists,
    );
    expect(
      resolveAccountLinkFailure(FirebaseAuthException(code: 'cancelled')),
      AccountLinkFailureKind.cancelled,
    );
  });
}
