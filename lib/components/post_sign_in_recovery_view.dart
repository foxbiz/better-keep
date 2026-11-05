import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

class PostSignInRecoveryView extends StatelessWidget {
  const PostSignInRecoveryView({
    required this.onRetry,
    this.onContinueOffline,
    required this.onSignOut,
    this.message,
    this.canRetry = true,
    super.key,
  });

  final Future<void> Function() onRetry;
  final Future<void> Function()? onContinueOffline;
  final Future<void> Function() onSignOut;
  final String? message;
  final bool canRetry;

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
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          message ?? context.l10n.somethingWentWrongTryAgain,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        if (canRetry)
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.retry),
          ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: onSignOut,
          icon: const Icon(Icons.logout),
          label: Text(context.l10n.signOut),
        ),
        const SizedBox(height: 8),
        if (onContinueOffline != null)
          TextButton(
            onPressed: onContinueOffline,
            child: Text(context.l10n.continueOffline),
          ),
      ],
    );
  }
}
