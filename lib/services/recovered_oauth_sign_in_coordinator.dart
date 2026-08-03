import 'dart:async';

import 'package:better_keep/services/oauth_transaction.dart';

typedef OAuthCompletionRedeemer =
    Future<String> Function(
      String completionCode,
      OAuthTransaction transaction,
    );
typedef OAuthCustomTokenAuthenticator<TUser extends Object> =
    Future<TUser?> Function(String customToken);
typedef OAuthSignInFinalizer<TUser extends Object> =
    Future<void> Function(TUser user, String provider);
typedef OAuthTransactionRemover = Future<void> Function(String transactionId);
typedef OAuthVerificationStateSetter = void Function(bool isVerifying);
typedef OAuthSecondaryFailureReporter =
    void Function(Object error, StackTrace stackTrace);

class RecoveredOAuthSignInException implements Exception {
  const RecoveredOAuthSignInException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'RecoveredOAuthSignInException($code): $message';
}

/// Completes a custom OAuth callback after the initiating app process was lost.
///
/// An in-process callback is handed back to the original sign-in future. Only a
/// restarted flow performs authentication and post-login initialization here.
class RecoveredOAuthSignInCoordinator<TUser extends Object> {
  const RecoveredOAuthSignInCoordinator({
    required this.redeemCompletion,
    required this.authenticateWithCustomToken,
    required this.finalizeSignIn,
    required this.removeTransaction,
    required this.setVerificationState,
    this.reportSecondaryFailure,
  });

  final OAuthCompletionRedeemer redeemCompletion;
  final OAuthCustomTokenAuthenticator<TUser> authenticateWithCustomToken;
  final OAuthSignInFinalizer<TUser> finalizeSignIn;
  final OAuthTransactionRemover removeTransaction;
  final OAuthVerificationStateSetter setVerificationState;
  final OAuthSecondaryFailureReporter? reportSecondaryFailure;

  Future<void> completeCallback({
    required OAuthTransaction transaction,
    required String completionCode,
    required Future<void> appServicesReady,
    FutureOr<void> Function()? completeInFlight,
  }) async {
    if (completeInFlight != null) {
      await completeInFlight();
      return;
    }

    Object? primaryFailure;
    StackTrace? primaryStackTrace;

    try {
      if (transaction.mode != 'signin') {
        throw const RecoveredOAuthSignInException(
          'invalid-transaction-mode',
          'Only sign-in transactions can resume after an app restart.',
        );
      }

      await appServicesReady;
      setVerificationState(true);

      final customToken = await redeemCompletion(completionCode, transaction);
      final user = await authenticateWithCustomToken(customToken);
      if (user == null) {
        throw const RecoveredOAuthSignInException(
          'missing-user',
          'Custom-token authentication completed without a user.',
        );
      }

      await finalizeSignIn(user, transaction.provider);
    } catch (error, stackTrace) {
      primaryFailure = error;
      primaryStackTrace = stackTrace;
    }

    try {
      setVerificationState(false);
    } catch (error, stackTrace) {
      if (primaryFailure == null) {
        primaryFailure = error;
        primaryStackTrace = stackTrace;
      } else {
        _reportSecondaryFailure(error, stackTrace);
      }
    }

    try {
      await removeTransaction(transaction.id);
    } catch (error, stackTrace) {
      if (primaryFailure == null) {
        primaryFailure = error;
        primaryStackTrace = stackTrace;
      } else {
        _reportSecondaryFailure(error, stackTrace);
      }
    }

    if (primaryFailure != null) {
      Error.throwWithStackTrace(primaryFailure, primaryStackTrace!);
    }
  }

  void _reportSecondaryFailure(Object error, StackTrace stackTrace) {
    try {
      reportSecondaryFailure?.call(error, stackTrace);
    } catch (_) {
      // Diagnostics must never prevent the remaining cleanup from running.
    }
  }
}
