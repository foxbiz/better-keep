import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/dialogs/confirm_device_sign_out.dart';
import 'package:better_keep/components/storage_warning.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/config.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

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
  const AppStartupErrorView({
    super.key,
    this.onRetry,
    this.onLibrarySignOut,
    this.requiresAppUpdate = false,
  });

  final bool requiresAppUpdate;

  final VoidCallback? onLibrarySignOut;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final retry = requiresAppUpdate ? null : onRetry;

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
                      requiresAppUpdate
                          ? context.l10n.updateApp
                          : context.l10n.unableToStartApp,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const StorageWarning(),
                    Text(
                      requiresAppUpdate
                          ? context.l10n.databaseUpdateRequired
                          : onLibrarySignOut != null
                          ? context.l10n.localLibraryUnavailable
                          : retry == null
                          ? context.l10n.startupRestartMessage
                          : context.l10n.startupRetryMessage,
                      textAlign: TextAlign.center,
                    ),
                    if (requiresAppUpdate) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => _openUpdate(context),
                        icon: const Icon(Icons.system_update),
                        label: Text(context.l10n.updateApp),
                      ),
                    ],
                    if (retry != null) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: Text(context.l10n.retry),
                      ),
                    ],
                    if (!requiresAppUpdate && onLibrarySignOut != null)
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

  Future<void> _openUpdate(BuildContext context) async {
    final url = kIsWeb
        ? 'https://betterkeep.app'
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => playStoreUrl,
            TargetPlatform.iOS => appStoreUrl,
            TargetPlatform.windows => microsoftStoreUrl,
            _ => 'https://betterkeep.app',
          };
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Keep the update path accessible when no external handler is available.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.updateApp),
        content: SelectableText(url),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
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
                const SizedBox(width: 180, child: LinearProgressIndicator()),
                const SizedBox(height: 16),
              ],
              Semantics(
                liveRegion: true,
                child: Text(switch (stage) {
                  SignOutStage.working => context.l10n.signingOut,
                  SignOutStage.clearingDevice =>
                    context.l10n.signOutClearingDevice,
                  SignOutStage.finishing => context.l10n.signOutFinishing,
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
