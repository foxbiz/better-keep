import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';

/// The authenticated destination shown while post-sign-in services initialize.
enum AuthenticatedStartupRoute {
  loading,
  pendingApproval,
  accountRecovery,
  recovery,
  home,
}

/// Resolves post-sign-in and encryption state into one stable UI destination.
///
/// Once encryption is usable, successful background initialization must not
/// replace Home with a blocking loading screen. Required-stage failures still
/// take priority so the user can retry, continue offline, or sign out.
AuthenticatedStartupRoute resolveAuthenticatedStartupRoute({
  required PostSignInState postSignInState,
  required E2EEStatus e2eeStatus,
}) {
  if (postSignInState.hasRecoverableFailure) {
    return AuthenticatedStartupRoute.recovery;
  }

  return switch (e2eeStatus) {
    E2EEStatus.pendingApproval ||
    E2EEStatus.revoked => AuthenticatedStartupRoute.pendingApproval,
    E2EEStatus.needsRecovery => AuthenticatedStartupRoute.accountRecovery,
    E2EEStatus.error => AuthenticatedStartupRoute.recovery,
    E2EEStatus.ready ||
    E2EEStatus.verifyingInBackground => AuthenticatedStartupRoute.home,
    E2EEStatus.notInitialized ||
    E2EEStatus.notSetUp => AuthenticatedStartupRoute.loading,
  };
}
