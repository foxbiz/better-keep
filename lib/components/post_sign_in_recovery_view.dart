import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

class PostSignInRecoveryView extends StatefulWidget {
  const PostSignInRecoveryView({
    required this.onRetry,
    required this.onSignOut,
    this.message,
    this.canRetry = true,
    this.connectionUnavailable = false,
    super.key,
  });

  final Future<void> Function() onRetry;
  final Future<void> Function() onSignOut;
  final String? message;
  final bool canRetry;
  final bool connectionUnavailable;

  @override
  State<PostSignInRecoveryView> createState() => _PostSignInRecoveryViewState();
}

class _PostSignInRecoveryViewState extends State<PostSignInRecoveryView> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          widget.connectionUnavailable
              ? Icons.wifi_off_rounded
              : Icons.error_outline,
          size: 64,
          color: widget.connectionUnavailable
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 24),
        Text(
          widget.connectionUnavailable
              ? context.l10n.signInConnectionTitle
              : context.l10n.somethingWentWrong,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          widget.message ??
              (widget.connectionUnavailable
                  ? context.l10n.signInConnectionMessage
                  : context.l10n.somethingWentWrongTryAgain),
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        if (widget.canRetry)
          ElevatedButton.icon(
            onPressed: _retrying ? null : _retry,
            icon: _retrying
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(context.l10n.retry),
          ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: widget.onSignOut,
          icon: const Icon(Icons.logout),
          label: Text(context.l10n.signOut),
        ),
      ],
    );
  }
}
