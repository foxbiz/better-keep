import 'dart:async';

import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/paywall/paywall_sheet.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Quiet, local-only reminder. Never starts sync or requests cloud data.
class CloudSyncUpgradeNotice extends StatefulWidget {
  const CloudSyncUpgradeNotice({
    super.key,
    this.visible = true,
    this.changes,
    this.eligibleAccount = _eligibleAccount,
    this.hasPendingChanges = _hasPendingChanges,
    this.onUpgrade,
  });

  // Memory-only: survives navigation, resets when the app/browser restarts.
  static final Set<String> _dismissedAccounts = {};

  @visibleForTesting
  static void resetSessionDismissals() => _dismissedAccounts.clear();

  final bool visible;
  final Listenable? changes;
  final String? Function() eligibleAccount;
  final Future<bool> Function() hasPendingChanges;
  final VoidCallback? onUpgrade;

  static String? _eligibleAccount() {
    if (!FirebaseBackend.isConfigured) return null;
    final preference = FirebaseSyncPreference.instance;
    final uid = AuthService.currentUser?.uid;
    if (uid == null ||
        !AuthService.canSyncCloud ||
        !E2EEService.instance.isCryptoReady ||
        AuthService.postSignInState.value.isRunning ||
        PlanService.instance.entitlements.realtimeCloudSync ||
        !preference.allowsDownload(uid)) {
      return null;
    }
    return uid;
  }

  static Future<bool> _hasPendingChanges() async =>
      AppState.get('db') != null &&
      await NoteSyncTrack.count(pending: true) > 0;

  @override
  State<CloudSyncUpgradeNotice> createState() => _CloudSyncUpgradeNoticeState();
}

class _CloudSyncUpgradeNoticeState extends State<CloudSyncUpgradeNotice> {
  late final Listenable _changes;
  Timer? _debounce;
  int _generation = 0;
  String? _account;
  bool _pending = false;
  bool _openingPaywall = false;

  @override
  void initState() {
    super.initState();
    _changes =
        widget.changes ??
        Listenable.merge([
          FirebaseSyncPreference.instance,
          PlanService.instance.entitlementsNotifier,
          AuthService.cloudRecovery.state,
          AuthService.postSignInState,
          E2EEService.instance.status,
          NoteSyncService().isSyncing,
        ]);
    _changes.addListener(_scheduleCheck);
    Note.on('changed', _noteChanged);
    _scheduleCheck();
  }

  void _noteChanged(ModelEvent<Note> _) => _scheduleCheck();

  void _scheduleCheck() {
    final generation = ++_generation;
    _debounce?.cancel();
    final account = widget.eligibleAccount();
    if (_account != account) {
      setState(() {
        _account = account;
        _pending = false;
      });
    }
    if (account == null ||
        CloudSyncUpgradeNotice._dismissedAccounts.contains(account)) {
      return;
    }
    // Coalesce saves and incoming note batches; no timer-based polling.
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final pending = await widget.hasPendingChanges();
        if (!mounted ||
            generation != _generation ||
            account != widget.eligibleAccount()) {
          return;
        }
        if (_pending != pending) setState(() => _pending = pending);
      } catch (_) {
        // Uncertain local state must not produce an upgrade prompt.
        if (mounted && generation == _generation) {
          setState(() => _pending = false);
        }
      }
    });
  }

  void _dismiss() {
    final account = _account;
    if (account == null) return;
    _generation++;
    _debounce?.cancel();
    setState(() => CloudSyncUpgradeNotice._dismissedAccounts.add(account));
  }

  Future<void> _upgrade() async {
    if (_openingPaywall) return;
    _openingPaywall = true;
    try {
      if (widget.onUpgrade != null) {
        widget.onUpgrade!();
      } else {
        await showPaywall(context); // Built-in uploads require Pro.
      }
    } finally {
      _openingPaywall = false;
      if (mounted) _scheduleCheck();
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _changes.removeListener(_scheduleCheck);
    Note.off('changed', _noteChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible ||
        !_pending ||
        _account == null ||
        CloudSyncUpgradeNotice._dismissedAccounts.contains(_account) ||
        _account != widget.eligibleAccount()) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final swipeToDismiss =
        !kIsWeb &&
        (theme.platform == TargetPlatform.android ||
            theme.platform == TargetPlatform.iOS);
    final notice = Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final theme = Theme.of(context);
                  final scaler = MediaQuery.textScalerOf(context);
                  final actionText = TextPainter(
                    text: TextSpan(
                      text: context.l10n.upgrade,
                      style: theme.textTheme.labelLarge,
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: scaler,
                  )..layout();
                  final actionWidth = actionText.width + 32;
                  actionText.dispose();
                  final stackAction =
                      constraints.maxWidth - actionWidth - 34 <
                      scaler.scale(140);
                  final message = Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            context.l10n.syncUpgradeReminder,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                  final action = TextButton(
                    onPressed: _upgrade,
                    child: Text(context.l10n.upgrade),
                  );
                  if (stackAction) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        message,
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: action,
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: message),
                      const SizedBox(width: 4),
                      action,
                    ],
                  );
                },
              ),
            ),
            if (!swipeToDismiss)
              IconButton(
                onPressed: _dismiss,
                tooltip: context.l10n.dismiss,
                icon: const Icon(Icons.close, size: 18),
                color: colors.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
    if (!swipeToDismiss) return notice;
    return Semantics(
      onDismiss: _dismiss,
      child: Dismissible(
        key: ValueKey('sync_upgrade_notice_$_account'),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => _dismiss(),
        child: notice,
      ),
    );
  }
}
