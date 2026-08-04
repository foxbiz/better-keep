import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/auth_error_messages.dart';

extension AuthProgressLocalizations on AuthProgress {
  String localized(AppLocalizations l10n) => switch (this) {
    AuthProgress.startingSignIn => l10n.startingSignIn,
    AuthProgress.waitingForSignIn || AuthProgress.signingIn => l10n.signingIn,
    AuthProgress.creatingAccount => l10n.creatingAccount,
    AuthProgress.verifying => l10n.verifying,
    AuthProgress.checkingAccount => l10n.checkingAccountStatus,
    AuthProgress.protectingNotes => l10n.gettingReady,
  };
}

extension AuthFailureLocalizations on AuthFailureKind {
  String localized(AppLocalizations l10n) => switch (this) {
    AuthFailureKind.accountExists => l10n.emailAlreadyInUse,
    AuthFailureKind.accountNotFound => l10n.accountNotFound,
    AuthFailureKind.invalidCredentials => l10n.invalidCredentials,
    AuthFailureKind.accountDisabled => l10n.accountDisabled,
    AuthFailureKind.tooManyRequests => l10n.pleaseWaitBeforeRequesting,
    AuthFailureKind.network => l10n.noInternetConnection,
    AuthFailureKind.cancelled ||
    AuthFailureKind.windowClosed => l10n.signInCancelledMessage,
    AuthFailureKind.missingEmail => l10n.noEmailAssociated,
    AuthFailureKind.appleVerification => l10n.appleSignInVerificationFailed,
    AuthFailureKind.permissionDenied ||
    AuthFailureKind.unavailable ||
    AuthFailureKind.insecureConnection ||
    AuthFailureKind.unknown => l10n.somethingWentWrongTryAgain,
  };
}

extension VerificationFailureLocalizations on VerificationFailureKind {
  String localized(AppLocalizations l10n) => switch (this) {
    VerificationFailureKind.invalidCode => l10n.invalidVerificationCode,
    VerificationFailureKind.tooManyRequests => l10n.pleaseWaitBeforeRequesting,
    VerificationFailureKind.network => l10n.noInternetConnection,
    VerificationFailureKind.signInRequired => l10n.pleaseSignInAgain,
    VerificationFailureKind.unknown => l10n.somethingWentWrongTryAgain,
  };
}

extension ProtectionProgressLocalizations on ProtectionProgress {
  String localized(AppLocalizations l10n) => switch (this) {
    ProtectionProgress.checkingAccount => l10n.checkingAccountStatus,
    ProtectionProgress.verifying => l10n.verifying,
    ProtectionProgress.gettingReady ||
    ProtectionProgress.connecting ||
    ProtectionProgress.protectingNotes ||
    ProtectionProgress.addingDevice ||
    ProtectionProgress.almostThere => l10n.gettingReady,
  };
}

extension RecoveryProgressLocalizations on RecoveryProgress {
  String localized(AppLocalizations l10n) => switch (this) {
    RecoveryProgress.checkingAccount => l10n.checkingAccountStatus,
    RecoveryProgress.verifying => l10n.verifying,
    RecoveryProgress.addingDevice ||
    RecoveryProgress.protectingNotes ||
    RecoveryProgress.almostThere => l10n.gettingReady,
  };
}

extension SyncProgressLocalizations on SyncProgress {
  String localized(AppLocalizations l10n) => switch (phase) {
    SyncPhase.idle => '',
    SyncPhase.complete => l10n.syncComplete,
    SyncPhase.failed when failedCount > 0 => l10n.syncFailedCount(failedCount),
    SyncPhase.failed => l10n.syncFailed,
    SyncPhase.resuming ||
    SyncPhase.checkingForUpdates ||
    SyncPhase.syncing ||
    SyncPhase.restarting ||
    SyncPhase.savingChanges ||
    SyncPhase.fetchingUpdates ||
    SyncPhase.uploadingMedia => l10n.syncing,
  };
}

extension ExportPhaseLocalizations on ExportPhase {
  String localized(AppLocalizations l10n) => switch (this) {
    ExportPhase.idle => '',
    ExportPhase.complete => l10n.exportComplete,
    ExportPhase.failed => l10n.exportFailed,
    ExportPhase.preparing ||
    ExportPhase.notes ||
    ExportPhase.labels ||
    ExportPhase.attachments ||
    ExportPhase.packaging ||
    ExportPhase.compressing ||
    ExportPhase.saving => l10n.exportingData,
  };
}
