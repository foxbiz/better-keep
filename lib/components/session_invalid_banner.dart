import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// A banner that shows when the user's session is invalid.
/// This happens when the user was deleted from Firebase Auth
/// but still has local data. Sync is disabled in this state.
class SessionInvalidBanner extends StatefulWidget {
  const SessionInvalidBanner({super.key});

  @override
  State<SessionInvalidBanner> createState() => _SessionInvalidBannerState();
}

class _SessionInvalidBannerState extends State<SessionInvalidBanner> {
  bool _isDismissed = false;

  Future<void> _handleSignOut() async {
    // Use the navigator key context since this banner is above the Navigator
    final navContext = AppState.navigatorKey.currentContext;
    if (navContext == null) return;

    final confirmed = await showDialog<bool>(
      context: navContext,
      builder: (dialogContext) => AlertDialog(
        icon: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.logout, color: Colors.orange, size: 32),
        ),
        title: Text(
          navContext.l10n.signOut,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(navContext.l10n.signOutConfirmationWithNote),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(navContext.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(navContext.l10n.signOut),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await AuthService.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.sessionInvalid,
      builder: (context, isInvalid, child) {
        if (!isInvalid || _isDismissed) {
          return const SizedBox.shrink();
        }

        return Material(
          color: Colors.orange.shade800,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.l10n.sessionProblem,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.l10n.syncDisabledPleaseSignOut,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _handleSignOut,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    child: Text(context.l10n.signOut),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _isDismissed = true;
                      });
                    },
                    icon: const Icon(Icons.close, color: Colors.white),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    tooltip: 'Dismiss',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
