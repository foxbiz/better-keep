import '../../services/monetization/monetization.dart';
import '../../ui/paywall/paywall_sheet.dart';

import 'dart:async';

import 'storage_clear_dialog.dart';
import 'storage_usage_text.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/external_sync/external_sync_service.dart';
import '../../services/external_sync/library_sync_session.dart';
import '../../services/external_sync/nextcloud_login_flow.dart';
import '../../services/external_sync/webdav_sync_transport.dart';
import '../../services/firebase_sync_preference.dart';
import '../../services/external_sync/storage_connection_controller.dart';
import '../../services/external_sync/storage_credential_broker.dart';
import '../../services/external_sync/sync_provider_adapter.dart';
import '../../components/sync_provider_tile.dart';
import '../../utils/l10n_helper.dart';
import '../user_page.dart';

class StorageSyncPage extends StatefulWidget {
  const StorageSyncPage({super.key, this.service, this.firebasePreference});
  final FirebaseSyncPreference? firebasePreference;
  final ExternalSyncService? service;
  @override
  State<StorageSyncPage> createState() => _StorageSyncPageState();
}

class _StorageSyncPageState extends State<StorageSyncPage> {
  ExternalSyncService get _service =>
      widget.service ?? ExternalSyncService.instance;
  FirebaseSyncPreference get _firebase =>
      widget.firebasePreference ?? FirebaseSyncPreference.instance;
  static const _providers = syncProviderOptions;
  bool _switching = false;
  bool get _busy => _switching || _firebase.busy || _firebase.loading;

  void _account() =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const UserPage()));

  Future<void> _run(
    LibrarySyncSession session,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (!mounted || !identical(_service.session, session)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.externalSyncFailure(
              error is SyncProviderFailure ? error.kind.name : 'unavailable',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _select(String provider) async {
    if (_busy || _firebase.selectedProvider == provider) return;
    final session = _service.session;
    setState(() => _switching = true);
    try {
      if (_providers.containsKey(provider)) {
        if (session == null) return;
        // Resume a saved connection before selecting it. The shared selection
        // keeps it inactive until the account-wide write is confirmed.
        if (session.connections.connections[provider]?.isReady != true ||
            session.connections.isLocallyStopped(provider)) {
          await session.connections.setEnabled(provider, true);
        }
        if (!mounted || !identical(session, _service.session)) return;
      }
      await _firebase.selectProvider(provider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.externalSyncFailure('unavailable')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  bool _connecting = false;

  Future<void> _connect(LibrarySyncSession session, String provider) async {
    if (_connecting || !mounted || !identical(_service.session, session)) {
      return;
    }
    _connecting = true;
    try {
      await _showConnectionDialog(session, provider);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _showConnectionDialog(
    LibrarySyncSession session,
    String provider,
  ) async {
    final sharedSetup =
        _providerFailure(session, provider) ==
        SyncProviderFailureKind.sharedSetupRequired;
    if (session.connections.connections[provider]?.credentialVersion == 1) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.storageSecurityUpgrade),
          content: Text(context.l10n.storageSecurityUpgradeInstructions),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.externalSyncAction('reconnect')),
            ),
          ],
        ),
      );
      if (proceed != true ||
          !mounted ||
          !identical(_service.session, session)) {
        return;
      }
    }
    if (provider == 'nextcloud' || provider == 'webdav') {
      final connected = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DavConnectionDialog(
          generic: provider == 'webdav',
          connections: session.connections,
          isCurrent: () => identical(_service.session, session),
        ),
      );
      if (connected == true &&
          mounted &&
          identical(_service.session, session)) {
        await _select(provider);
      }
      return;
    }
    final controller = session.connections;
    // Prepare before the dialog's Connect gesture. Browsers must open the
    // authorization popup directly from that gesture, without another click.
    if (kIsWeb && !controller.canCancelOAuth(provider)) {
      unawaited(_run(session, () => controller.prepareOAuth(provider)));
    }
    var completed = false;
    SyncProviderFailureKind? authorizationError;
    final connected = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        Future<void> authorize() async {
          authorizationError = null;
          await _run(session, () async {
            await controller.authorizeOAuth(provider);
            if (!mounted ||
                !dialogContext.mounted ||
                !identical(_service.session, session)) {
              return;
            }
            if (controller.actions[provider] == null &&
                controller.connections[provider]?.isReady == true) {
              // Keep success terminal while the route animates out. Selection
              // happens on the settings page after the dialog is dismissed.
              completed = true;
              Navigator.pop(dialogContext, true);
            }
          });
          if (kIsWeb &&
              !completed &&
              mounted &&
              dialogContext.mounted &&
              identical(_service.session, session)) {
            authorizationError = controller.errors[provider];
            if (authorizationError != null) {
              // Replace the consumed flow before the next Connect gesture.
              await _run(session, () => controller.prepareOAuth(provider));
            }
          }
        }

        return AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final action = controller.actions[provider];
            final pending = controller.canCancelOAuth(provider);
            final busy = completed || controller.isBusy(provider);
            final error = controller.errors[provider] ?? authorizationError;
            return PopScope(
              canPop: !pending && !busy,
              child: _StorageConnectDialog(
                provider: provider,
                infoEnabled: !busy,
                help: sharedSetup
                    ? context.l10n.externalSyncSharedSetupHelp
                    : context.l10n.externalSyncConnectHelp,
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (busy)
                      _ConnectionProgress(
                        context.l10n.externalSyncState(
                          action == StorageConnectionAction.cancelling
                              ? 'cancelling'
                              : 'connecting',
                        ),
                      )
                    else
                      Text(
                        sharedSetup
                            ? context.l10n.externalSyncNativeSetupPrompt
                            : context.l10n.externalSyncConnectPrompt,
                      ),
                    if (action == StorageConnectionAction.cancelPending) ...[
                      const SizedBox(height: 12),
                      Text(context.l10n.externalSyncState(action!.name)),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.externalSyncFailure(error.name),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
                actions: completed
                    ? []
                    : [
                        TextButton(
                          onPressed:
                              action == StorageConnectionAction.cancelling ||
                                  (busy && !pending)
                              ? null
                              : () async {
                                  if (pending) {
                                    await _cancel(session, provider);
                                    if (controller.canCancelOAuth(provider)) {
                                      return;
                                    }
                                  } else if (busy) {
                                    return;
                                  }
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                          child: Text(context.l10n.cancel),
                        ),
                        FilledButton(
                          onPressed:
                              busy ||
                                  action ==
                                      StorageConnectionAction.cancelPending
                              ? null
                              : () async {
                                  if (action ==
                                      StorageConnectionAction.awaitingConsent) {
                                    await authorize();
                                  } else {
                                    await _run(session, () async {
                                      await controller.prepareOAuth(provider);
                                      if (!kIsWeb &&
                                          mounted &&
                                          dialogContext.mounted &&
                                          identical(
                                            _service.session,
                                            session,
                                          )) {
                                        await authorize();
                                      }
                                    });
                                  }
                                },
                          child: Text(
                            context.l10n.externalSyncAction(
                              !kIsWeb &&
                                      action ==
                                          StorageConnectionAction
                                              .awaitingConsent
                                  ? 'continue'
                                  : 'connect',
                            ),
                          ),
                        ),
                      ],
              ),
            );
          },
        );
      },
    );
    if (connected == true && mounted && identical(_service.session, session)) {
      await _select(provider);
    }
  }

  Future<void> _cancel(LibrarySyncSession session, String provider) =>
      _run(session, () async {
        final cancelled = await session.connections.cancelOAuth(provider);
        if (!cancelled && mounted && identical(_service.session, session)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.externalSyncAlreadyConnected)),
          );
        }
      });

  Future<void> _clearSyncedData(
    LibrarySyncSession session,
    String provider,
  ) async {
    final cleared = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StorageClearDialog(session: session, provider: provider),
    );
    if (!mounted || !identical(_service.session, session) || cleared != true) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.externalSyncClearDone)));
  }

  Future<void> _disconnect(LibrarySyncSession session, String provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.externalSyncDisconnectTitle(_providers[provider]!.name),
        ),
        content: Text(context.l10n.externalSyncDisconnectMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.externalSyncAction('disconnect')),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !identical(_service.session, session)) {
      return;
    }
    await _run(session, () async {
      final revoked = await session.connections.disconnect(provider);
      if (!mounted || !identical(_service.session, session)) return;
      if (_firebase.selectedProvider == provider) await _select('none');
      if (!revoked && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 15),
            content: Text(context.l10n.externalSyncRevocationIncomplete),
          ),
        );
      }
    });
  }

  void _choose(String provider) {
    if (_busy) return;
    if (provider == 'firebase' || provider == 'none') {
      if (_firebase.accountId == null) {
        _account();
      } else {
        _select(provider);
      }
      return;
    }
    final session = _service.session;
    if (session == null) return;
    final controller = session.connections;
    final connection = controller.connections[provider];
    if (controller.isBusy(provider)) {
      return;
    }
    if (connection?.state == 'clearing') {
      _clearSyncedData(session, provider);
    } else if (connection?.state == 'disconnecting') {
      _disconnect(session, provider);
    } else if (controller.needsKeyRecovery(provider)) {
      _account();
    } else if (connection == null ||
        connection.state == 'disconnected' ||
        connection.state == 'reconnect_required' ||
        _providerFailure(session, provider) ==
            SyncProviderFailureKind.reconnectRequired ||
        _providerFailure(session, provider) ==
            SyncProviderFailureKind.sharedSetupRequired ||
        controller.actions[provider] != null) {
      _connect(session, provider);
    } else {
      _select(provider);
    }
  }

  SyncProviderFailureKind? _providerFailure(
    LibrarySyncSession session,
    String provider,
  ) =>
      session.connections.errors[provider] ??
      session
          .scheduler
          .progress[session.connections.connections[provider]?.replicaId]
          ?.failure;

  void _details(LibrarySyncSession session, String provider) {
    final connection = session.connections.connections[provider];
    final progress = session.scheduler.progress[connection?.replicaId];
    final last =
        progress?.lastSuccess ??
        session.status.lastSuccess[connection?.replicaId];
    final failure = session.connections.errors[provider] ?? progress?.failure;
    final formats = MaterialLocalizations.of(context);
    final time = last?.toLocal();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_providers[provider]!.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (connection?.accountLabel.isNotEmpty == true) ...[
                Text(connection!.accountLabel),
                const SizedBox(height: 12),
              ],
              Text(
                time == null
                    ? context.l10n.externalSyncNeverSynced
                    : context.l10n.externalSyncLastSuccess(
                        '${formats.formatMediumDate(time)} ${formats.formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                      ),
              ),
              if (failure != null) ...[
                const SizedBox(height: 12),
                Text(context.l10n.externalSyncFailure(failure.name)),
              ],
              if ((progress?.notesRequiringUnlock ?? 0) > 0) ...[
                const SizedBox(height: 12),
                Text(context.l10n.externalSyncUnlockSketches),
              ] else if ((progress?.blockedEntities ?? 0) > 0) ...[
                const SizedBox(height: 12),
                Text(context.l10n.externalSyncBlocked),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.externalSyncTitle)),
    body: AnimatedBuilder(
      animation: Listenable.merge([
        _service,
        _firebase,
        PlanService.instance.entitlementsNotifier,
      ]),
      builder: (context, _) {
        final session = _service.session;
        return RadioGroup<String>(
          groupValue: _firebase.selectedProvider,
          onChanged: (provider) {
            if (provider != null) _choose(provider);
          },
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                    child: Text(
                      context.l10n.externalSyncDescription,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _tile(
                    id: 'firebase',
                    title: context.l10n.externalSyncCloud,
                    icon: Icons.cloud_outlined,
                    subtitle: context.l10n.externalSyncCloudDescription,
                    selected: _firebase.selectedProvider == 'firebase',
                    onTap: _firebase.accountId == null
                        ? _account
                        : _busy || !_firebase.firebaseAvailable
                        ? null
                        : () => _select('firebase'),
                  ),
                  if (session != null)
                    for (final provider
                        in StorageConnectionController.providers)
                      _provider(session, provider),
                  if (_firebase.accountId != null)
                    _tile(
                      id: 'none',
                      title: context.l10n.externalSyncOff,
                      icon: Icons.cloud_off_outlined,
                      subtitle: context.l10n.externalSyncOffDescription,
                      selected: _firebase.selectedProvider == 'none',
                      onTap: _busy ? null : () => _select('none'),
                    ),
                  if (_busy || _service.initializing)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: LinearProgressIndicator(),
                    ),
                  if (_firebase.failed ||
                      _service.failure != null ||
                      session?.connections.metadataFailure != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        context.l10n.externalSyncFailure('unavailable'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_firebase.failed)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _firebase.retry().catchError((Object _) {}),
                      icon: const Icon(Icons.refresh),
                      label: Text(context.l10n.retry),
                    ),
                  if (session == null)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(context.l10n.externalSyncUnavailable),
                      subtitle: Text(context.l10n.externalSyncAccount),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _account,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _tile({
    required String id,
    required String title,
    required IconData icon,
    required String subtitle,
    int? subtitleMaxLines = 2,
    bool warning = false,
    required bool selected,
    VoidCallback? onTap,
    Widget? menu,
    Widget? detail,
    bool radio = true,
    bool busy = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('storage-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: selected
          ? colors.secondaryContainer.withValues(alpha: .45)
          : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? colors.primary.withValues(alpha: .55)
              : colors.outlineVariant.withValues(alpha: .4),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 28,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: subtitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: warning ? colors.error : colors.onSurfaceVariant,
                      ),
                    ),
                    if (detail != null) ...[const SizedBox(height: 4), detail],
                  ],
                ),
              ),
              ?menu,
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (radio)
                Radio<String>(value: id, enabled: onTap != null),
              if (menu == null && !radio && !busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.chevron_right, size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
    bool destructive = false,
  }) {
    final theme = Theme.of(context);
    final color = !enabled
        ? theme.disabledColor
        : destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Flexible(
            child: Text(label, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }

  bool get _automaticExternalSync =>
      (_firebase.entitlements?.value ?? PlanService.instance.entitlements)
          .automaticExternalSync;

  Future<void> _explainAutomaticSync() async {
    final upgrade = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.automaticExternalSync),
        content: Text(context.l10n.manualSyncDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.upgrade),
          ),
        ],
      ),
    );
    if (upgrade == true && mounted) {
      showPaywall(context, initialPlan: UserPlan.lite);
    }
  }

  Widget _provider(LibrarySyncSession session, String provider) {
    final controller = session.connections;
    final connection = controller.connections[provider];
    final connected = connection != null && connection.state != 'disconnected';
    final recovery = controller.needsKeyRecovery(provider);
    final failure = _providerFailure(session, provider);
    final reconnect =
        connection?.state == 'reconnect_required' ||
        failure == SyncProviderFailureKind.reconnectRequired;
    final action = controller.actions[provider];
    final busy = controller.isBusy(provider);
    final selected = _firebase.selectedProvider == provider;
    final progress = session.scheduler.progress[connection?.replicaId];
    final issue = failure != null || (progress?.blockedEntities ?? 0) > 0;
    final canManage = connected && !busy && !recovery && action == null;
    final canDisconnect = canManage && connection.state != 'clearing';
    final canClear =
        canManage &&
        connection.hasEncryptedCredentials &&
        const ['ready', 'clearing'].contains(connection.state);
    final subtitle = action == StorageConnectionAction.clearing
        ? context.l10n.externalSyncClearing
        : connection?.state == 'clearing'
        ? context.l10n.externalSyncClearPending
        : failure == SyncProviderFailureKind.quotaExceeded
        ? context.l10n.externalSyncStorageFull
        : action != null
        ? context.l10n.externalSyncState(action.name)
        : connection?.state == 'disconnecting'
        ? context.l10n.externalSyncState('disconnecting')
        : recovery
        ? context.l10n.externalSyncState('keyRecovery')
        : failure == SyncProviderFailureKind.sharedSetupRequired
        ? context.l10n.externalSyncSharedSetup
        : reconnect
        ? context.l10n.externalSyncAction('reconnect')
        : issue && connected
        ? context.l10n.externalSyncNeedsAttention
        : selected && progress?.running == true
        ? context.l10n.syncing
        : connected
        ? connection.accountLabel.isNotEmpty
              ? connection.accountLabel
              : context.l10n.externalSyncState('ready')
        : context.l10n.externalSyncState('notConnected');
    return _tile(
      id: provider,
      title: _providers[provider]!.name,
      icon: _providers[provider]!.icon,
      subtitle: connected
          ? subtitle
          : '${action == null ? context.l10n.externalSyncState('notConnected') : subtitle} · ${context.l10n.free}',
      detail: connected && !recovery && connection.state == 'ready'
          ? StorageUsageText(
              key: ValueKey((controller, connection.replicaId)),
              revision: (
                connection.updatedAt,
                connection.enabled,
                selected,
                busy,
                progress?.lastSuccess,
                progress?.failure,
              ),
              load: () => controller.readStorageUsage(provider),
            )
          : null,
      subtitleMaxLines: failure == SyncProviderFailureKind.quotaExceeded
          ? null
          : 2,
      warning: failure == SyncProviderFailureKind.quotaExceeded,
      selected: selected,
      radio: connected,
      busy: busy,
      onTap: _busy || busy ? null : () => _choose(provider),
      menu: !connected && action == null
          ? null
          : PopupMenuButton<String>(
              key: ValueKey('storage-menu-$provider'),
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              onSelected: (value) {
                switch (value) {
                  case 'details':
                    _details(session, provider);
                  case 'automatic':
                    _explainAutomaticSync();
                  case 'sync':
                    _run(session, () async {
                      await _service.refreshWithOutcome();
                    });
                  case 'clear':
                    _clearSyncedData(session, provider);
                  case 'disconnect':
                    _disconnect(session, provider);
                  case 'cancel':
                    _cancel(session, provider);
                  case 'account':
                    _account();
                }
              },
              itemBuilder: (_) => [
                if (connected)
                  _menuItem(
                    'details',
                    Icons.info_outline,
                    context.l10n.externalSyncDetails,
                  ),
                if (recovery)
                  _menuItem(
                    'account',
                    Icons.manage_accounts_outlined,
                    context.l10n.externalSyncAccount,
                  ),
                if (selected &&
                    connection?.isReady == true &&
                    !busy &&
                    !recovery)
                  _menuItem(
                    'sync',
                    Icons.sync,
                    context.l10n.externalSyncAction('sync'),
                    enabled: progress?.running != true,
                  ),
                if (selected && !_automaticExternalSync)
                  _menuItem(
                    'automatic',
                    Icons.sync,
                    context.l10n.automaticExternalSync,
                  ),
                if (controller.canCancelOAuth(provider))
                  _menuItem('cancel', Icons.close, context.l10n.cancel),
                if (canDisconnect || canClear)
                  const PopupMenuDivider(height: 16),
                if (canDisconnect)
                  _menuItem(
                    'disconnect',
                    Icons.link_off,
                    context.l10n.externalSyncAction('disconnect'),
                    destructive: true,
                  ),
                if (canClear)
                  _menuItem(
                    'clear',
                    Icons.delete_outline,
                    context.l10n.externalSyncClear,
                    destructive: true,
                  ),
              ],
            ),
    );
  }
}

class _StorageConnectDialog extends StatelessWidget {
  const _StorageConnectDialog({
    required this.provider,
    required this.help,
    required this.content,
    required this.actions,
    this.infoEnabled = true,
  });
  final bool infoEnabled;
  final String provider, help;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final option = syncProviderOptions[provider]!;
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Row(
        children: [
          Icon(option.icon, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              option.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            key: const ValueKey('storage-connection-info'),
            tooltip: context.l10n.externalSyncConnectionInfo,
            icon: const Icon(Icons.info_outline, size: 22),
            onPressed: !infoEnabled
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      scrollable: true,
                      title: Text(context.l10n.externalSyncConnectionInfo),
                      content: Text(help),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(context.l10n.close),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
      content: SizedBox(width: 360, child: content),
      actions: actions.isEmpty
          ? []
          : [
              Row(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: actions[i],
                      ),
                    ),
                  ],
                ],
              ),
            ],
    );
  }
}

class _ConnectionProgress extends StatelessWidget {
  const _ConnectionProgress(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 12),
      Expanded(child: Text(label)),
    ],
  );
}

class _DavConnectionDialog extends StatefulWidget {
  const _DavConnectionDialog({
    this.generic = false,
    required this.connections,
    required this.isCurrent,
  });
  final StorageConnectionController connections;
  final bool generic;
  final bool Function() isCurrent;
  @override
  State<_DavConnectionDialog> createState() => _DavConnectionDialogState();
}

class _DavConnectionDialogState extends State<_DavConnectionDialog> {
  final _form = GlobalKey<FormState>();
  final _serverKey = GlobalKey<FormFieldState<String>>();
  final _server = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController();
  NextcloudLoginFlow? _flow;
  bool _prepared = false, _busy = false, _registering = false;
  bool _completed = false;
  late bool _manualMode;
  SyncProviderFailureKind? _error;

  @override
  void initState() {
    super.initState();
    _manualMode = widget.generic;
  }

  @override
  void dispose() {
    _flow?.dispose();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || !widget.isCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is SyncProviderFailure
              ? error.kind
              : SyncProviderFailureKind.unavailable,
        );
      }
    } finally {
      if (mounted && !_completed) {
        setState(() {
          _busy = false;
          _registering = false;
        });
      }
    }
  }

  Future<void> _register(StorageDavAccess access) async {
    if (!mounted || !widget.isCurrent()) return;
    setState(() {
      _registering = true;
    });
    if (widget.generic) {
      await widget.connections.connectWebDav(access);
    } else {
      await widget.connections.connectNextcloud(access);
    }
    if (mounted && widget.isCurrent()) {
      setState(() => _completed = true);
      Navigator.pop(context, true);
    }
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    _run(
      () => _register(
        StorageDavAccess(
          Uri.parse(_server.text.trim()),
          _username.text.trim(),
          _password.text,
        ),
      ),
    );
  }

  void _prepareBrowser() {
    if (!_serverKey.currentState!.validate()) return;
    _run(() async {
      _flow?.dispose();
      final flow = widget.connections.createNextcloudLogin(
        Uri.parse(_server.text.trim()),
      );
      _flow = flow;
      await flow.prepare();
      if (mounted && widget.isCurrent()) setState(() => _prepared = true);
    });
  }

  void _authorize() => _run(() async {
    final access = await _flow!.authorize();
    await _register(access);
  });

  void _manual() {
    _flow?.dispose();
    _flow = null;
    setState(() {
      _prepared = false;
      _manualMode = !_manualMode;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_registering,
    child: _StorageConnectDialog(
      provider: widget.generic ? 'webdav' : 'nextcloud',
      infoEnabled: !_busy,
      help: widget.generic
          ? context.l10n.externalSyncWebDavHelp
          : context.l10n.externalSyncNextcloudHelp,
      content: SizedBox(
        width: 360,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: _serverKey,
                controller: _server,
                enabled: !_busy && !_prepared,
                keyboardType: TextInputType.url,
                textInputAction: _manualMode
                    ? TextInputAction.next
                    : TextInputAction.done,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.l10n.externalSyncServer,
                  prefixIcon: const Icon(Icons.link),
                  border: const OutlineInputBorder(),
                  hintText: widget.generic
                      ? 'https://cloud.example.com/dav/'
                      : 'https://cloud.example.com',
                ),
                validator: (value) {
                  try {
                    final uri = Uri.parse(value?.trim() ?? '');
                    if (widget.generic) {
                      WebDavSyncTransport.normalizeServer(uri);
                    } else {
                      NextcloudLoginFlow.normalizeServer(uri);
                    }
                    return null;
                  } catch (_) {
                    return context.l10n.externalSyncInvalidServer;
                  }
                },
              ),
              if (_manualMode) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _username,
                  textInputAction: TextInputAction.next,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.externalSyncUsername,
                    prefixIcon: const Icon(Icons.person_outline),
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value == null ||
                          value.trim().isEmpty ||
                          value.contains(':')
                      ? context.l10n.externalSyncRequired
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.externalSyncAppPassword,
                    prefixIcon: const Icon(Icons.key_outlined),
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? context.l10n.externalSyncRequired
                      : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (!widget.generic)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _manual,
                    child: Text(
                      context.l10n.externalSyncAction(
                        _manualMode ? 'browser' : 'manual',
                      ),
                    ),
                  ),
                ),
              if (_busy) ...[
                const SizedBox(height: 12),
                _ConnectionProgress(
                  context.l10n.externalSyncState('connecting'),
                ),
              ],
              if (_error != null)
                Text(
                  context.l10n.externalSyncFailure(_error!.name),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: _completed
          ? []
          : [
              TextButton(
                onPressed: _registering ? null : () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : _manualMode
                    ? _submit
                    : _prepared
                    ? _authorize
                    : _prepareBrowser,
                child: Text(
                  _manualMode
                      ? context.l10n.externalSyncAction('connect')
                      : _prepared
                      ? context.l10n.externalSyncContinue
                      : context.l10n.signIn,
                ),
              ),
            ],
    ),
  );
}
