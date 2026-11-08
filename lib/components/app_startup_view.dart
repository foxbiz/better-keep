import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/dialogs/confirm_device_sign_out.dart';
import 'package:better_keep/components/storage_warning.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/services/auth_service.dart';

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
  const AppStartupErrorView({super.key, this.onRetry, this.onLibrarySignOut});

  final VoidCallback? onLibrarySignOut;

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
                    const StorageWarning(),
                    Text(
                      onLibrarySignOut != null
                          ? context.l10n.localLibraryUnavailable
                          : retry == null
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
                    if (onLibrarySignOut != null)
                      TextButton(
                        onPressed: () async {
                          if (await confirmDeviceSignOut(
                                context,
                                unavailableLibrary: true,
                              ) &&
                              context.mounted) {
                            onLibrarySignOut?.call();
                          }
                        },
                        child: Text(context.l10n.signOut),
                      ),
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

/// Replaces the account navigator while shared local storage is being cleared.
class SignOutProgressView extends StatelessWidget {
  const SignOutProgressView({
    super.key,
    required this.stage,
    this.problem,
    required this.onRetry,
  });

  final SignOutStage stage;
  final SignOutProblem? problem;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (stage != SignOutStage.retry) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
              ],
              Semantics(
                liveRegion: true,
                child: Text(switch (stage) {
                  SignOutStage.working => context.l10n.signingOut,
                  SignOutStage.delayed => context.l10n.signOutFinishing,
                  SignOutStage.retry => switch (problem) {
                    SignOutProblem.secureStorage =>
                      context.l10n.signOutSecureStorageRetry,
                    SignOutProblem.otherWindow =>
                      context.l10n.signOutOtherWindowRetry,
                    SignOutProblem.database =>
                      context.l10n.signOutDatabaseRetry,
                    null => context.l10n.signOutCleanupRetry,
                  },
                }, textAlign: TextAlign.center),
              ),
              if (stage == SignOutStage.retry) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onRetry,
                  child: Text(context.l10n.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
