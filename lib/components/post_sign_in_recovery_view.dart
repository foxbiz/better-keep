import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

class PostSignInRecoveryView extends StatelessWidget {
  const PostSignInRecoveryView({
    required this.onRetry,
    required this.onContinueOffline,
    required this.onSignOut,
    super.key,
  });

  final Future<void> Function() onRetry;
  final Future<void> Function() onContinueOffline;
  final Future<void> Function() onSignOut;

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.logout, color: Colors.orange, size: 32),
        title: Text(context.l10n.signOut),
        content: Text(context.l10n.signOutConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(context.l10n.signOut),
          ),
        ],
      ),
    );
    if (confirmed == true) await onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.error_outline,
          size: 64,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 24),
        Text(
          context.l10n.somethingWentWrong,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.somethingWentWrongTryAgain,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.retry),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => _confirmSignOut(context),
          icon: const Icon(Icons.logout),
          label: Text(context.l10n.signOut),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onContinueOffline,
          child: Text(context.l10n.continueOffline),
        ),
      ],
    );
  }
}
