import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/sync_logout_check.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

Future<bool> confirmDeviceSignOut(
  BuildContext context, {
  bool warnWithoutRecovery = false,
  bool unavailableLibrary = false,
}) async {
  final isCurrent = AuthService.captureSessionIdentity();
  final uid = AuthService.currentUser?.uid;
  bool active() =>
      context.mounted && isCurrent() && AuthService.currentUser?.uid == uid;
  final l10n = context.l10n;
  final inspection = unavailableLibrary
      ? null
      : currentSyncLogoutState().timeout(
          const Duration(seconds: 5),
          onTimeout: () => SyncLogoutState.unknown,
        );
  var recoveryWarning = false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => FutureBuilder<SyncLogoutState>(
        future: inspection,
        builder: (context, snapshot) {
          final checking =
              inspection != null &&
              snapshot.connectionState != ConnectionState.done;
          final state = snapshot.data ?? SyncLogoutState.unknown;
          final needsSyncWarning = state != SyncLogoutState.complete;
          final warnRecoveryNow =
              recoveryWarning || (warnWithoutRecovery && !needsSyncWarning);
          final destructive =
              !checking &&
              (unavailableLibrary || needsSyncWarning || warnRecoveryNow);
          final message = unavailableLibrary
              ? l10n.signOutLibraryWarning
              : warnRecoveryNow
              ? l10n.signOutNoRecoveryKeyWarning
              : switch (state) {
                  SyncLogoutState.pending => l10n.externalSyncLogoutPending,
                  SyncLogoutState.unknown => l10n.externalSyncLogoutUnknown,
                  SyncLogoutState.complete => l10n.signOutConfirmation,
                };
          return AlertDialog(
            icon: Icon(
              destructive ? Icons.warning_amber_rounded : Icons.logout,
              color: destructive ? Theme.of(context).colorScheme.error : null,
            ),
            title: Text(destructive ? l10n.dataLossWarning : l10n.signOut),
            content: checking
                ? LinearProgressIndicator(semanticsLabel: l10n.checkingStatus)
                : Text(message),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: checking
                    ? null
                    : () {
                        if (!active()) {
                          Navigator.pop(dialogContext, false);
                        } else if (!unavailableLibrary &&
                            warnWithoutRecovery &&
                            !warnRecoveryNow) {
                          update(() => recoveryWarning = true);
                        } else {
                          Navigator.pop(dialogContext, true);
                        }
                      },
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                      )
                    : null,
                child: Text(destructive ? l10n.signOutAnyway : l10n.signOut),
              ),
            ],
          );
        },
      ),
    ),
  );
  return accepted == true && active();
}
