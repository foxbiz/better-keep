import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/sync_logout_check.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

Future<bool> confirmDeviceSignOut(
  BuildContext context, {
  bool warnWithoutRecovery = false,
}) async {
  final isCurrent = AuthService.captureSessionIdentity();
  final uid = AuthService.currentUser?.uid;
  bool active() =>
      context.mounted && isCurrent() && AuthService.currentUser?.uid == uid;
  final l10n = context.l10n;
  final state = await currentSyncLogoutState();
  if (!context.mounted || !active()) return false;
  Future<bool> confirm(String message, {required bool destructive}) async {
    if (!active()) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          destructive ? Icons.warning_amber_rounded : Icons.logout,
          color: destructive ? Theme.of(dialogContext).colorScheme.error : null,
        ),
        title: Text(destructive ? l10n.dataLossWarning : l10n.signOut),
        content: Text(message),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  )
                : null,
            child: Text(destructive ? l10n.signOutAnyway : l10n.signOut),
          ),
        ],
      ),
    );
    return accepted == true && active();
  }

  if (state != SyncLogoutState.complete) {
    final proceed = await confirm(
      state == SyncLogoutState.pending
          ? l10n.externalSyncLogoutPending
          : l10n.externalSyncLogoutUnknown,
      destructive: true,
    );
    if (!proceed) return false;
  }
  if (warnWithoutRecovery) {
    return confirm(l10n.signOutNoRecoveryKeyWarning, destructive: true);
  }
  return state == SyncLogoutState.complete
      ? confirm(l10n.signOutConfirmation, destructive: false)
      : active();
}
