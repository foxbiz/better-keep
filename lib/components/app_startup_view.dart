import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// A localized, implementation-agnostic loading screen used before the main
/// application shell is ready.
class AppStartupLoadingView extends StatelessWidget {
  const AppStartupLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(context.l10n.gettingReady),
          ],
        ),
      ),
    );
  }
}

/// A localized startup failure screen that deliberately keeps diagnostics out
/// of user-visible copy. Callers are responsible for logging the root cause.
class AppStartupErrorView extends StatelessWidget {
  const AppStartupErrorView({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.unableToStartApp,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      retry == null
                          ? context.l10n.startupRestartMessage
                          : context.l10n.startupRetryMessage,
                      textAlign: TextAlign.center,
                    ),
                    if (retry != null) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.retry),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
