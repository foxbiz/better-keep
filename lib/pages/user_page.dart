import 'dart:io';

import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/dialogs/loading_dialog.dart';
import 'package:better_keep/dialogs/otp_dialog.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/share_link.dart';
import 'package:better_keep/pages/setup_recovery_key_page.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/services/note_share_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  bool _isLoading = true;
  int _totalNotes = 0;
  int _upcomingReminders = 0;
  int _totalMedia = 0;

  // E2EE state
  List<DeviceDocument> _devices = [];
  List<DeviceApprovalRequest> _pendingApprovals = [];
  String? _currentDeviceId;
  bool _isFirstDevice = false;
  bool _hasRecoveryKey = true; // Assume true until checked
  final Set<String> _processingDeviceIds = {}; // Track devices being processed
  bool _isLoadingDevices = true;
  String? _devicesError;

  // Share access requests state
  List<ShareAccessRequest> _pendingShareRequests = [];
  // ignore: unused_field - Used for future active shares management UI
  List<ShareLink> _activeShares = [];
  final Set<String> _processingShareRequests = {};

  // Track device deletion batch for consolidated snackbar
  int _pendingDeletionCount = 0;
  int _successfulDeletionCount = 0;

  // Subscription action loading state
  bool _isSubscriptionActionLoading = false;

  @override
  void initState() {
    _fetchStats();
    _fetchE2EEInfo();
    _fetchLinkedProviders();
    _initShareService();
    NoteSyncService().isSyncing.addListener(_onSyncChange);
    E2EEService.instance.status.addListener(_onE2EEStatusChange);
    E2EEService.instance.deviceManager.pendingApprovals.addListener(
      _onPendingApprovalsChange,
    );
    NoteShareService().pendingRequests.addListener(_onShareRequestsChange);
    NoteShareService().activeShares.addListener(_onActiveSharesChange);
    super.initState();
  }

  void _initShareService() {
    NoteShareService().init();
  }

  void _onShareRequestsChange() {
    if (mounted) {
      setState(() {
        _pendingShareRequests = NoteShareService().pendingRequests.value;
      });
    }
  }

  void _onActiveSharesChange() {
    if (mounted) {
      setState(() {
        _activeShares = NoteShareService().activeShares.value;
      });
    }
  }

  Future<void> _fetchLinkedProviders() async {
    await AuthService.refreshLinkedProviders();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    NoteSyncService().isSyncing.removeListener(_onSyncChange);
    E2EEService.instance.status.removeListener(_onE2EEStatusChange);
    E2EEService.instance.deviceManager.pendingApprovals.removeListener(
      _onPendingApprovalsChange,
    );
    NoteShareService().pendingRequests.removeListener(_onShareRequestsChange);
    NoteShareService().activeShares.removeListener(_onActiveSharesChange);
    super.dispose();
  }

  void _onPendingApprovalsChange() {
    if (mounted) {
      setState(() {
        _pendingApprovals =
            E2EEService.instance.deviceManager.pendingApprovals.value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.currentUser;
    final cached = AuthService.cachedProfile;

    final displayName = user?.displayName ?? cached?['displayName'] ?? 'User';
    final email = user?.email ?? cached?['email'];

    return Scaffold(
      appBar: AppBar(
        title: Text(displayName),
        actions: [
          // Refresh button for desktop/web (no pull-to-refresh)
          if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS))
            IconButton(
              onPressed: _handleRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: context.l10n.refresh,
            ),
          TextButton.icon(
            onPressed: () => _handleSignOut(context),
            icon: const Icon(Icons.logout),
            label: Text(context.l10n.signOut),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Pending Approvals Alert (only show on primary device)
                    if (_pendingApprovals.isNotEmpty && _isFirstDevice)
                      _buildPendingApprovalsAlert(context),

                    // Share Access Requests Alert
                    if (_pendingShareRequests.isNotEmpty)
                      _buildPendingShareRequestsAlert(context),

                    UserAvatar(heroTag: 'user_avatar', showProBorder: true),
                    const SizedBox(height: 8),
                    if (email != null)
                      Text(email, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 32),

                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.all(32.0),
                        child: CircularProgressIndicator(),
                      )
                    else ...[
                      // Stats Row
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildStatItem(
                              context,
                              _totalNotes.toString(),
                              context.l10n.notes_,
                              Icons.note_outlined,
                            ),
                            _buildStatItem(
                              context,
                              _upcomingReminders.toString(),
                              context.l10n.reminders,
                              Icons.alarm_outlined,
                            ),
                            _buildStatItem(
                              context,
                              _totalMedia.toString(),
                              context.l10n.media,
                              Icons.image_outlined,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Subscription Section
                      _buildSubscriptionSection(context),

                      const SizedBox(height: 32),

                      // Connected Accounts Section
                      _buildConnectedPlatformsSection(context),

                      const SizedBox(height: 32),

                      // E2EE Section
                      _buildE2EESection(context),

                      const SizedBox(height: 32),

                      // Device Management (show if E2EE is set up, loading, or has error)
                      if (_devices.isNotEmpty ||
                          _isLoadingDevices ||
                          _devicesError != null)
                        _buildDeviceSection(context),

                      const SizedBox(height: 32),
                      // Danger Zone
                      _buildDangerZone(context),
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

  Future<void> _handleRefresh() async {
    // Invalidate avatar cache and reload in case user changed
    UserAvatar.invalidateCache();
    await UserAvatar.preloadAvatar();

    // Force validate subscription with backend (bypasses rate limiting)
    await PlanService.instance.forceValidateSubscription();

    // Refresh linked providers from Firestore
    await AuthService.refreshLinkedProviders();

    // Refresh stats
    await _fetchStats();

    // Refresh E2EE info (devices, pending approvals, recovery key status)
    await _fetchE2EEInfo();

    if (mounted) {
      setState(() {}); // Force rebuild to update avatar and linked accounts
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.allUpToDate),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _handleSignOut(BuildContext context) async {
    // Track if user has already confirmed through a warning dialog
    bool hasConfirmed = false;

    // Check for unsynced notes first
    int pendingSyncCount = 0;
    try {
      pendingSyncCount = await NoteSyncTrack.count(pending: true);
    } catch (e) {
      // If we can't check, assume no pending syncs
      debugPrint('Error checking pending syncs: $e');
    }

    if (pendingSyncCount > 0 && context.mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.sync_problem, color: Colors.red, size: 48),
          ),
          title: Text(
            "⚠️ ${context.l10n.dataLossWarning}",
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.l10n.notesNotSynced(pendingSyncCount),
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(context.l10n.unsyncedNotesWarning),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(context.l10n.signOutAnyway),
            ),
          ],
        ),
      );

      if (proceed != true) return;
      hasConfirmed = true;
    }

    if (!context.mounted) {
      snackbar("Cancelled sign out - context no longer mounted", Colors.red);
      return;
    }

    // Check if recovery key is set - warn user if not
    if (!_hasRecoveryKey && _devices.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_rounded,
              color: Colors.red,
              size: 48,
            ),
          ),
          title: Text(
            "⚠️ ${context.l10n.dataLossWarning}",
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.key_off, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.l10n.noRecoveryKeySet,
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(context.l10n.signOutNoRecoveryKeyWarning),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(context.l10n.signOutAnyway),
            ),
          ],
        ),
      );

      if (confirmed != true) return;
    } else if (!hasConfirmed) {
      // Standard confirmation dialog (only if user hasn't already confirmed)
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.logout, color: Colors.orange, size: 32),
          ),
          title: Text(
            context.l10n.signOut,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Text(context.l10n.signOutConfirmation),
          actions: [
            OutlinedButton(
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

      if (confirmed != true) return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await AuthService.signOut();
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.errorSigningOut(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildPendingApprovalsAlert(BuildContext context) {
    final theme = Theme.of(context);
    final count = _pendingApprovals.length;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.devices,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.nDevicesWaitingForApproval(count),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade800,
                        ),
                      ),
                      Text(
                        context.l10n.reviewAndApprove,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._pendingApprovals.map(
              (request) => _buildPendingDeviceQuickAction(context, request),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingDeviceQuickAction(
    BuildContext context,
    DeviceApprovalRequest request,
  ) {
    final theme = Theme.of(context);

    IconData platformIcon;
    switch (request.platform) {
      case 'android':
        platformIcon = Icons.android;
        break;
      case 'ios':
        platformIcon = Icons.phone_iphone;
        break;
      case 'macos':
        platformIcon = Icons.laptop_mac;
        break;
      case 'windows':
        platformIcon = Icons.laptop_windows;
        break;
      case 'linux':
        platformIcon = Icons.computer;
        break;
      case 'web':
        platformIcon = Icons.language;
        break;
      default:
        platformIcon = Icons.devices_other;
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(platformIcon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.deviceName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _formatPlatform(request.platform),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (_processingDeviceIds.contains(request.deviceId))
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            TextButton(
              onPressed: () => _approveDevice(request.deviceId),
              child: Text(context.l10n.approve),
            ),
            IconButton(
              icon: Icon(Icons.close, color: theme.colorScheme.error, size: 20),
              onPressed: () => _revokeDevice(request.deviceId),
              tooltip: context.l10n.deny,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPendingShareRequestsAlert(BuildContext context) {
    final theme = Theme.of(context);
    final count = _pendingShareRequests.length;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.primary, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.share, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.nShareAccessRequests(count),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        context.l10n.someoneWantsToView,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._pendingShareRequests.map(
              (request) =>
                  _buildPendingShareRequestQuickAction(context, request),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingShareRequestQuickAction(
    BuildContext context,
    ShareAccessRequest request,
  ) {
    final theme = Theme.of(context);

    IconData platformIcon;
    switch (request.platform) {
      case 'android':
        platformIcon = Icons.android;
        break;
      case 'ios':
        platformIcon = Icons.phone_iphone;
        break;
      case 'macos':
        platformIcon = Icons.laptop_mac;
        break;
      case 'windows':
        platformIcon = Icons.desktop_windows;
        break;
      case 'linux':
        platformIcon = Icons.computer;
        break;
      case 'web':
        platformIcon = Icons.language;
        break;
      default:
        platformIcon = Icons.devices_other;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            platformIcon,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.deviceName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _formatPlatform(request.platform),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (_processingShareRequests.contains(request.id))
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            TextButton(
              onPressed: () => _approveShareRequest(request),
              child: Text(context.l10n.approve),
            ),
            IconButton(
              icon: Icon(Icons.close, color: theme.colorScheme.error, size: 20),
              onPressed: () => _denyShareRequest(request),
              tooltip: context.l10n.deny,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _approveShareRequest(ShareAccessRequest request) async {
    setState(() => _processingShareRequests.add(request.id));
    try {
      await NoteShareService().approveRequest(request.shareId, request.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.accessApproved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.failedToApprove(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _processingShareRequests.remove(request.id));
    }
  }

  Future<void> _denyShareRequest(ShareAccessRequest request) async {
    setState(() => _processingShareRequests.add(request.id));
    try {
      await NoteShareService().denyRequest(request.shareId, request.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.accessDenied)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.failedToDeny(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _processingShareRequests.remove(request.id));
    }
  }

  Widget _buildSubscriptionSection(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<SubscriptionStatus>(
      valueListenable: PlanService.instance.statusNotifier,
      builder: (context, status, _) {
        final plan = status.effectivePlan;
        final isPaid = plan.isPaid;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isPaid
                    ? theme.colorScheme.primary.withValues(alpha: 0.3)
                    : theme.colorScheme.outline.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Icon(
                      isPaid ? Icons.workspace_premium : Icons.person_outline,
                      color: isPaid
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.subscription,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            status.isTrialSubscription
                                ? context.l10n.trial
                                : context.l10n.plan(
                                    plan.localizedDisplayName(context.l10n),
                                  ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildPlanBadge(
                      context,
                      plan,
                      isTrial: status.isTrialSubscription,
                    ),
                  ],
                ),

                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 12),

                // Plan details based on subscription state
                if (isPaid) ...[
                  // Subscription details for paid users
                  _buildSubscriptionDetails(context, status),
                  const SizedBox(height: 16),
                  // Show different buttons based on subscription state
                  if (status.isTrialSubscription) ...[
                    // Trial users - show upgrade button
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _handleSubscribe(context),
                            icon: const Icon(Icons.star),
                            label: Text(context.l10n.upgradeToPro),
                          ),
                        ),
                      ],
                    ),
                  ] else if (status.isCancelledButActive) ...[
                    // Cancelled but still in subscription period
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.subscriptionCancelled,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            context.l10n.subscriptionCancelledInfo(
                              _formatDate(status.expiresAt),
                            ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    // For App Store / Play Store, show resubscribe button
                    if (!status.isRazorpaySubscription) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _isSubscriptionActionLoading
                              ? null
                              : () => _handleCancelSubscription(context),
                          icon: const Icon(Icons.refresh),
                          label: Text(context.l10n.renewSubscription),
                        ),
                      ),
                    ],
                    // Debug: Delete subscription button (only in debug mode)
                    if (kDebugMode) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: _isSubscriptionActionLoading
                              ? null
                              : () => _handleDebugDeleteSubscription(context),
                          icon: const Icon(Icons.bug_report, size: 16),
                          label: Text(context.l10n.debugDeleteSubscription),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ] else ...[
                    // Active subscription - show cancel/manage
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _isSubscriptionActionLoading
                            ? null
                            : () => _handleCancelSubscription(context),
                        icon: _isSubscriptionActionLoading
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colorScheme.error,
                                ),
                              )
                            : const Icon(Icons.cancel_outlined),
                        label: Text(
                          _isSubscriptionActionLoading
                              ? context.l10n.cancellingSubscription
                              : status.isRazorpaySubscription
                              ? context.l10n.cancelSubscription
                              : context.l10n.manageSubscription,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    // Debug: Delete subscription button (only in debug mode)
                    if (kDebugMode && status.isRazorpaySubscription) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: _isSubscriptionActionLoading
                              ? null
                              : () => _handleDebugDeleteSubscription(context),
                          icon: const Icon(Icons.bug_report, size: 16),
                          label: Text(context.l10n.debugDeleteSubscription),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ],
                ] else ...[
                  // Upgrade prompt for free users
                  Text(
                    context.l10n.upgradeToProDescription,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _handleSubscribe(context),
                          icon: const Icon(Icons.star),
                          label: Text(context.l10n.upgradeToPro),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlanBadge(
    BuildContext context,
    UserPlan plan, {
    bool isTrial = false,
  }) {
    final theme = Theme.of(context);

    Color backgroundColor;
    Color textColor;
    String label;

    if (isTrial) {
      backgroundColor = theme.colorScheme.tertiaryContainer;
      textColor = theme.colorScheme.onTertiaryContainer;
      label = 'TRIAL';
    } else {
      switch (plan) {
        case UserPlan.free:
          backgroundColor = theme.colorScheme.surfaceContainerHighest;
          textColor = theme.colorScheme.onSurfaceVariant;
          break;
        case UserPlan.pro:
          backgroundColor = theme.colorScheme.primaryContainer;
          textColor = theme.colorScheme.onPrimaryContainer;
          break;
      }
      label = plan.localizedDisplayName(context.l10n).toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: textColor,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSubscriptionDetails(
    BuildContext context,
    SubscriptionStatus status,
  ) {
    final theme = Theme.of(context);

    String billingText;
    if (status.isTrialSubscription) {
      billingText = context.l10n.freeTrial;
    } else {
      switch (status.billingPeriod) {
        case BillingPeriod.monthly:
          billingText = context.l10n.monthlySubscription;
          break;
        case BillingPeriod.yearly:
          billingText = context.l10n.yearlySubscription;
          break;
        case null:
          billingText = context.l10n.subscription;
          break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Show trial banner if on trial
        if (status.isTrialSubscription) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.1),
                  theme.colorScheme.tertiary.withValues(alpha: 0.1),
                ],
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.star,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.freeTrialActive,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (status.expiresAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.expiresOnDaysLeft(
                      _formatDate(status.expiresAt!),
                      status.daysUntilExpiration,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  context.l10n.enjoyProFeatures,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          _buildDetailRow(
            context,
            Icons.payment,
            context.l10n.billing,
            billingText,
          ),
          if (status.expiresAt != null) ...[
            const SizedBox(height: 8),
            _buildDetailRow(
              context,
              status.willAutoRenew ? Icons.autorenew : Icons.event,
              status.willAutoRenew ? context.l10n.renews : context.l10n.expires,
              _formatDate(status.expiresAt!),
            ),
          ],
        ],
        if (status.inGracePeriod) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.subscriptionInGracePeriod,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Unknown';
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Future<void> _handleSubscribe(BuildContext context) async {
    // First, refresh subscription status to ensure we have the latest state
    // This catches cases where trial was just granted but UI hasn't updated
    await PlanService.instance.refreshSubscription();

    final status = PlanService.instance.status;

    // If user already has an active paid subscription (not trial), inform them
    if (status.isActive && status.plan.isPaid && !status.isTrialSubscription) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.alreadyHaveSubscription(
              status.plan.localizedDisplayName(context.l10n),
            ),
          ),
          backgroundColor: Colors.green,
        ),
      );
      return;
    }

    // Show warning for trial users
    if (status.isTrialSubscription && status.isActive) {
      if (!context.mounted) return;

      final daysLeft = status.daysUntilExpiration;
      final expiryText = daysLeft > 0
          ? '$daysLeft day${daysLeft > 1 ? 's' : ''} left'
          : 'less than a day left';

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          return AlertDialog(
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.info_outline,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(context.l10n.upgradeNowQuestion)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.trialTimeLeft(expiryText),
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.subscribeNowTrialEnds,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.end,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.continueTrial),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(context.l10n.upgradeNow),
              ),
            ],
          );
        },
      );

      if (confirmed != true) return;
    }

    if (!context.mounted) return;
    showPaywall(context, feature: GatedFeature.realtimeCloudSync);
  }

  Future<void> _handleCancelSubscription(BuildContext context) async {
    final subscriptionService = SubscriptionService.instance;
    final subscriptionStatus = PlanService.instance.status;

    // For Razorpay subscriptions, show confirmation dialog
    if (subscriptionStatus.isRazorpaySubscription) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.cancelSubscription),
          content: Text(context.l10n.cancelSubscriptionConfirmation),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.keepSubscription),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(context.l10n.cancelSubscription),
            ),
          ],
        ),
      );

      if (confirmed != true || !context.mounted) return;
    }

    setState(() => _isSubscriptionActionLoading = true);

    try {
      final result = await subscriptionService.cancelSubscription();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          behavior: SnackBarBehavior.floating,
        ),
      );

      // After the user returns from the store management page, wait briefly
      // for the background restore+refresh to update Firestore, then rebuild.
      if (result.isPending) {
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) {
        setState(() => _isSubscriptionActionLoading = false);
      }
    }
  }

  /// DEBUG ONLY: Delete subscription for testing
  Future<void> _handleDebugDeleteSubscription(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.bug_report, color: Colors.orange),
            const SizedBox(width: 8),
            Flexible(child: Text(context.l10n.debugDeleteSubscription)),
          ],
        ),
        content: Text(context.l10n.debugDeleteSubscriptionWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _isSubscriptionActionLoading = true);

    try {
      final success = await RazorpayService.instance.debugDeleteSubscription();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? context.l10n.debugSubscriptionDeleted
                : context.l10n.debugSubscriptionDeleteFailed,
          ),
          backgroundColor: success ? Colors.green : Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubscriptionActionLoading = false);
      }
    }
  }

  // ============================================================
  // CONNECTED ACCOUNTS SECTION
  // ============================================================

  Widget _buildConnectedPlatformsSection(BuildContext context) {
    final theme = Theme.of(context);
    final linkedProviders = AuthService.getLinkedProviderIds();

    // Define all available providers with their metadata
    final providers = [
      _ProviderInfo(
        id: 'google.com',
        name: 'Google',
        icon: CustomIcons.google,
        color: Colors.red.shade600,
        onLink: () => _linkProvider('google'),
      ),
      _ProviderInfo(
        id: 'facebook.com',
        name: 'Facebook',
        icon: CustomIcons.facebook,
        color: const Color(0xFF1877F2),
        onLink: () => _linkProvider('facebook'),
      ),
      _ProviderInfo(
        id: 'github.com',
        name: 'GitHub',
        icon: CustomIcons.github,
        color: theme.brightness == Brightness.dark
            ? Colors.white
            : Colors.black87,
        onLink: () => _linkProvider('github'),
      ),
      // TODO: Re-enable Twitter login when API issues are resolved
      // _ProviderInfo(
      //   id: 'twitter.com',
      //   name: 'X (Twitter)',
      //   icon: CustomIcons.xTwitter,
      //   color: theme.brightness == Brightness.dark
      //       ? Colors.white
      //       : Colors.black87,
      //   onLink: () => _linkProvider('twitter'),
      // ),
      _ProviderInfo(
        id: 'apple.com',
        name: 'Apple',
        icon: Icons.apple,
        color: theme.brightness == Brightness.dark
            ? Colors.white
            : Colors.black,
        onLink: () => _linkProvider('apple'),
      ),
      _ProviderInfo(
        id: 'password',
        name: 'Email',
        icon: Icons.email_outlined,
        color: theme.colorScheme.primary,
        onLink: null, // Email/password linking requires different flow
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.link, color: theme.colorScheme.primary, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.connectedAccounts,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        context.l10n.signInWithAnyLinked,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),

            // Security notice
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.security, color: Colors.blue.shade700, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10n.linkingRequiresAuth,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Provider list
            ...providers.map((provider) {
              final isLinked = linkedProviders.contains(provider.id);
              return _buildProviderRow(
                context,
                provider,
                isLinked,
                linkedProviders.length,
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderRow(
    BuildContext context,
    _ProviderInfo provider,
    bool isLinked,
    int totalLinkedCount,
  ) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Provider icon
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isLinked
                  ? provider.color.withValues(alpha: 0.15)
                  : theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              provider.icon,
              color: isLinked
                  ? provider.color
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),

          // Provider name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (isLinked)
                  Text(
                    context.l10n.connected,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                    ),
                  ),
              ],
            ),
          ),

          // Action button
          if (isLinked) ...[
            // Check if this is the primary provider (original sign-up method)
            if (provider.id == AuthService.getPrimaryProviderId())
              Tooltip(
                message: context.l10n.cannotUnlinkPrimary,
                child: TextButton(
                  onPressed: null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text(context.l10n.primary),
                ),
              )
            // All other linked providers can be unlinked
            else
              TextButton(
                onPressed: () => _unlinkProvider(provider),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(context.l10n.unlink),
              ),
          ] else if (provider.onLink != null)
            FilledButton.tonal(
              onPressed: provider.onLink,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: Text(context.l10n.link),
            ),
        ],
      ),
    );
  }

  Future<void> _linkProvider(String providerName) async {
    final functions = FirebaseFunctions.instance;

    // Map display name to Firebase provider ID
    final providerIds = {
      'google': 'google.com',
      'facebook': 'facebook.com',
      'github': 'github.com',
      'apple': 'apple.com',
      'twitter': 'twitter.com',
    };
    final providerId = providerIds[providerName.toLowerCase()];
    if (providerId == null) {
      snackbar(context.l10n.unknownProviderError(providerName), Colors.red);
      return;
    }

    try {
      // Step 1: Show loading and request OTP
      if (!mounted) return;

      final loadingResult = await showLoadingDialog<Map<String, dynamic>>(
        context: context,
        config: LoadingDialogConfig(
          message: context.l10n.sendingVerificationCode,
          showCancelAfter: const Duration(seconds: 5),
          timeout: const Duration(seconds: 30),
          timeoutMessage: context.l10n.takingTooLong,
        ),
        operation: () async {
          final sendOtpCallable = functions.httpsCallable(
            'requestAccountLinkOtp',
          );
          final sendResult = await sendOtpCallable.call({
            'provider': providerId,
          });
          return sendResult.data as Map<String, dynamic>;
        },
      );

      if (!mounted) return;

      // Handle cancellation or timeout
      if (loadingResult.cancelled) {
        return;
      }
      if (loadingResult.timedOut) {
        snackbar(context.l10n.requestTimedOut, Colors.orange);
        return;
      }
      if (!loadingResult.success) {
        snackbar(
          loadingResult.error ?? context.l10n.failedSendCode,
          Colors.red,
        );
        return;
      }

      final maskedEmail =
          loadingResult.data?['email'] as String? ?? 'your email';

      // Step 2: Show OTP verification dialog
      final otpResult = await showOtpDialog(
        context,
        OtpDialogConfig(
          title: context.l10n.verifyAccountLink,
          maskedEmail: maskedEmail,
          icon: Icons.link,
          verifyButtonLabel: context.l10n.verifyAndLink,
          verifyFunctionName: 'verifyAccountLinkOtp',
          verifyFunctionParams: {'provider': providerId},
        ),
      );

      // User cancelled or verification failed
      if (otpResult == null || !otpResult.success) {
        if (otpResult?.error != null) {
          snackbar(otpResult!.error!, Colors.red);
        }
        return;
      }

      // Step 3: OTP verified, now perform the OAuth linking
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(context.l10n.linkingAccount),
                ],
              ),
            ),
          ),
        ),
      );

      // Perform the OAuth linking - this opens the provider's auth page
      // and stores the link in Firestore upon success
      switch (providerName.toLowerCase()) {
        case 'google':
          await AuthService.linkWithGoogle();
          break;
        case 'facebook':
          await AuthService.linkWithFacebook();
          break;
        case 'github':
          await AuthService.linkWithGitHub();
          break;
        case 'apple':
          await AuthService.linkWithApple();
          break;
        case 'twitter':
          await AuthService.linkWithTwitter();
          break;
      }

      // Dismiss loading dialog
      if (mounted) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }

        await _fetchE2EEInfo(); // Refresh user data including linked providers
        if (mounted) {
          setState(() {});
          snackbar(
            context.l10n.successfullyLinkedProvider(providerName),
            Colors.green,
          );
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;

      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      String errorMessage = context.l10n.failedLinkAccount;

      switch (e.code) {
        case 'unauthenticated':
          errorMessage = context.l10n.pleaseSignInAgain;
          break;
        case 'failed-precondition':
          errorMessage = context.l10n.noEmailAssociated;
          break;
        case 'already-exists':
          errorMessage = context.l10n.providerAlreadyLinked(providerName);
          break;
        case 'resource-exhausted':
          errorMessage = e.message ?? context.l10n.pleaseWaitBeforeRequesting;
          break;
        case 'deadline-exceeded':
          errorMessage = context.l10n.sessionExpired_;
          break;
        default:
          errorMessage = e.message ?? context.l10n.failedLinkAccount;
      }

      if (mounted) snackbar(errorMessage, Colors.red);
    } catch (e) {
      if (!mounted) return;

      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      String errorMessage = context.l10n.failedLinkAccount;
      final errorStr = e.toString();

      if (errorStr.contains('credential-already-in-use')) {
        errorMessage = context.l10n.providerLinkedToAnother(providerName);
      } else if (errorStr.contains('provider-already-linked')) {
        errorMessage = context.l10n.providerAlreadyLinked(providerName);
      } else if (errorStr.contains('email-already-in-use')) {
        errorMessage = context.l10n.emailAlreadyInUse;
      } else if (errorStr.contains('cancelled') ||
          errorStr.contains('canceled')) {
        errorMessage = context.l10n.linkingCancelled;
      } else if (e is Exception) {
        final msg = errorStr.replaceFirst('Exception: ', '');
        if (msg.length < 100) errorMessage = msg;
      }

      if (mounted) {
        snackbar(errorMessage, Colors.red);
      }
    }
  }

  Future<void> _unlinkProvider(_ProviderInfo provider) async {
    try {
      // Show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.link_off, color: Colors.red, size: 32),
          ),
          title: Text(context.l10n.unlinkProviderQuestion(provider.name)),
          content: Text(context.l10n.unlinkProviderWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(context.l10n.unlink),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      await AuthService.unlinkProvider(provider.id);

      if (mounted) {
        setState(() {});
        snackbar(
          context.l10n.unlinkedSuccessfully(provider.name),
          Colors.green,
        );
      }
    } catch (e) {
      if (mounted) {
        String errorMessage = context.l10n.failedUnlinkAccount;
        final errorStr = e.toString();

        if (errorStr.contains('Cannot unlink')) {
          errorMessage = context.l10n.cannotUnlinkOnlyMethod;
        } else if (e is Exception) {
          final msg = errorStr.replaceFirst('Exception: ', '');
          if (msg.length < 100) errorMessage = msg;
        }
        snackbar(errorMessage, Colors.red);
      }
    }
  }

  Widget _buildE2EESection(BuildContext context) {
    final e2ee = E2EEService.instance;
    final status = e2ee.status.value;
    final theme = Theme.of(context);

    String statusText;
    Color statusColor;
    IconData statusIcon;

    switch (status) {
      case E2EEStatus.ready:
        statusText = "Your notes are protected";
        statusColor = Colors.green;
        statusIcon = Icons.lock;
        break;
      case E2EEStatus.pendingApproval:
        statusText = "Waiting for device approval";
        statusColor = Colors.orange;
        statusIcon = Icons.hourglass_empty;
        break;
      case E2EEStatus.notSetUp:
        statusText = "Protection not enabled";
        statusColor = Colors.grey;
        statusIcon = Icons.lock_open;
        break;
      case E2EEStatus.error:
        statusText = "Something went wrong";
        statusColor = Colors.orange;
        statusIcon = Icons.error_outline;
        break;
      case E2EEStatus.revoked:
        statusText = "Device access removed";
        statusColor = Colors.red;
        statusIcon = Icons.block;
        break;
      default:
        statusText = "Getting ready...";
        statusColor = Colors.grey;
        statusIcon = Icons.lock_open;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                      if (status == E2EEStatus.ready)
                        Text(
                          "Your notes and attachments are encrypted",
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),

            if (status == E2EEStatus.ready) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // Encryption details
              _buildInfoRow(
                context,
                "Encryption",
                "XChaCha20-Poly1305",
                Icons.shield,
              ),
              const SizedBox(height: 8),
              _buildInfoRow(
                context,
                "Key Exchange",
                "X25519 ECDH",
                Icons.swap_horiz,
              ),
              const SizedBox(height: 8),
              _buildInfoRow(context, "Key Size", "256-bit", Icons.key),
              const SizedBox(height: 8),
              _buildInfoRow(
                context,
                "Devices",
                "${_devices.where((d) => d.isApproved).length} authorized",
                Icons.devices,
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // Recovery key management
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.vpn_key),
                title: Row(
                  children: [
                    Text(context.l10n.recoveryKey),
                    if (!_hasRecoveryKey) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          context.l10n.important,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(context.l10n.manageRecoveryPassphrase),
                trailing: const Icon(Icons.chevron_right),
                onTap: _manageRecoveryKey,
              ),
            ],

            if (status == E2EEStatus.notSetUp) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _setupE2EE,
                  icon: const Icon(Icons.lock),
                  label: Text(context.l10n.enableE2EE),
                ),
              ),
            ],

            if (status == E2EEStatus.pendingApproval) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.approveOnOtherDevice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceSection(BuildContext context) {
    final theme = Theme.of(context);
    final approvedDevices = _devices.where((d) => d.isApproved).toList();
    final pendingDevices = _devices.where((d) => d.isPending).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices, size: 24),
                const SizedBox(width: 12),
                Text(
                  context.l10n.yourDevices,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (_isLoadingDevices)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // Show error message if there's an error
            if (_devicesError != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_off,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _devicesError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _fetchE2EEInfo,
                      child: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
            ]
            // Show skeleton loader while loading
            else if (_isLoadingDevices && _devices.isEmpty) ...[
              _buildDeviceSkeletonLoader(context),
            ]
            // Show devices
            else ...[
              // Pending devices (show approval buttons) - only on primary device
              if (pendingDevices.isNotEmpty && _isFirstDevice) ...[
                Text(
                  context.l10n.pendingApprovalSection,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                ...pendingDevices.map(
                  (device) =>
                      _buildDeviceTile(context, device, isPending: true),
                ),
                const SizedBox(height: 16),
              ],

              // Approved devices
              if (approvedDevices.isNotEmpty) ...[
                Text(
                  context.l10n.authorizedDevices,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                ...approvedDevices.map(
                  (device) =>
                      _buildDeviceTile(context, device, isPending: false),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Builds a skeleton loader for the device list.
  Widget _buildDeviceSkeletonLoader(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label skeleton
        Container(
          width: 120,
          height: 12,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(height: 12),
        // Device tile skeletons
        for (int i = 0; i < 2; i++) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                // Icon skeleton
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name skeleton
                      Container(
                        width: 140,
                        height: 14,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Platform skeleton
                      Container(
                        width: 80,
                        height: 10,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDeviceTile(
    BuildContext context,
    DeviceDocument device, {
    required bool isPending,
  }) {
    final theme = Theme.of(context);
    final isCurrentDevice = device.id == _currentDeviceId;
    final canManage = _isFirstDevice && !isCurrentDevice;

    IconData platformIcon;
    switch (device.platform) {
      case 'android':
        platformIcon = Icons.android;
        break;
      case 'ios':
        platformIcon = Icons.phone_iphone;
        break;
      case 'macos':
        platformIcon = Icons.laptop_mac;
        break;
      case 'windows':
        platformIcon = Icons.laptop_windows;
        break;
      case 'linux':
        platformIcon = Icons.computer;
        break;
      case 'web':
        platformIcon = Icons.language;
        break;
      default:
        platformIcon = Icons.devices_other;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: isCurrentDevice
            ? Border.all(color: theme.colorScheme.primary, width: 1)
            : null,
      ),
      child: Row(
        children: [
          Icon(
            platformIcon,
            size: 24,
            color: isPending ? Colors.orange : theme.colorScheme.onSurface,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (isCurrentDevice) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          context.l10n.thisDevice,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  _formatDeviceSubtitle(device),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          // Action buttons
          if (_processingDeviceIds.contains(device.id))
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (isPending && _isFirstDevice)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_circle, color: Colors.green),
                  onPressed: () => _approveDevice(device.id),
                  tooltip: context.l10n.approve,
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.red),
                  onPressed: () => _revokeDevice(device.id),
                  tooltip: context.l10n.deny,
                ),
              ],
            )
          else if (canManage)
            IconButton(
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              onPressed: () => _confirmRevokeDevice(device),
              tooltip: context.l10n.removeDevice,
            ),
        ],
      ),
    );
  }

  /// Formats the device subtitle with platform and OS version info.
  String _formatDeviceSubtitle(DeviceDocument device) {
    final platformText = _formatPlatform(device.platform);

    // Check for OS version from device details
    final osVersion = device.osVersion;
    if (osVersion != null && osVersion.isNotEmpty) {
      return osVersion;
    }

    // For web, show browser info if available
    if (device.platform == 'web') {
      final browserName = device.deviceDetails?['browser_name'];
      final os = device.deviceDetails?['os'];
      if (browserName != null && os != null) {
        return '$browserName on $os';
      }
    }

    return platformText;
  }

  String _formatPlatform(String platform) {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iPhone/iPad';
      case 'macos':
        return 'macOS';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'web':
        return 'Web Browser';
      default:
        return platform;
    }
  }

  Future<void> _setupE2EE() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.enableE2EE),
        content: Text(context.l10n.enableE2EEConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.enableE2EE_),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        await E2EEService.instance.setupE2EE();
        await _fetchE2EEInfo();

        // Show mandatory recovery key setup page
        if (mounted) {
          setState(() => _isLoading = false);
          final scaffoldMessenger = ScaffoldMessenger.of(context);
          final recoverySetup = await showSetupRecoveryKeyPage(context);
          if (recoverySetup == true && mounted) {
            scaffoldMessenger.showSnackBar(
              SnackBar(
                content: Text(context.l10n.recoveryKeySavedSuccessfully),
              ),
            );
          } else if (mounted) {
            // User skipped - show warning
            scaffoldMessenger.showSnackBar(
              SnackBar(
                content: Text(context.l10n.noRecoveryKeyWarning),
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.failedEnableE2EE(e.toString())),
            ),
          );
        }
      }
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _manageRecoveryKey() async {
    final hasRecovery = await E2EEService.instance.recoveryKeyService
        .hasRecoveryKey();

    if (!mounted) return;

    if (hasRecovery) {
      // Show options: Update or Remove
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.recoveryKey),
          content: Text(context.l10n.recoveryKeySetUp),
          actions: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'remove'),
                  child: Text(
                    context.l10n.remove,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'update'),
                  child: Text(context.l10n.update),
                ),
              ],
            ),
          ],
        ),
      );

      if (action == 'update' && mounted) {
        // Use secure update dialog that requires current passphrase
        final updated = await showUpdateRecoveryKeyDialog(context);
        if (updated == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.recoveryKeyUpdated)),
          );
        }
      } else if (action == 'remove' && mounted) {
        // Use secure remove dialog that requires current passphrase
        final removed = await showRemoveRecoveryKeyDialog(context);
        if (removed == true && mounted) {
          setState(() => _hasRecoveryKey = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.recoveryKeyRemoved)),
          );
        }
      }
    } else {
      // No recovery key - set one up
      final created = await showSetupRecoveryKeyPage(context);
      if (created == true && mounted) {
        setState(() => _hasRecoveryKey = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.recoveryKeySaved)));
      }
    }
  }

  Future<void> _approveDevice(String deviceId) async {
    setState(() => _processingDeviceIds.add(deviceId));
    try {
      await E2EEService.instance.deviceManager.approveDevice(deviceId);
      // Cancel the notification for this device
      await DeviceApprovalNotificationService().cancelNotification(deviceId);
      await _fetchE2EEInfo();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.deviceApproved_)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.failedApproveDevice(e.toString())),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processingDeviceIds.remove(deviceId));
    }
  }

  Future<void> _revokeDevice(String deviceId) async {
    setState(() {
      _processingDeviceIds.add(deviceId);
      _pendingDeletionCount++;
    });
    try {
      await E2EEService.instance.deviceManager.revokeDevice(deviceId);
      // Cancel the notification for this device
      await DeviceApprovalNotificationService().cancelNotification(deviceId);
      _successfulDeletionCount++;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.failedRemoveDevice(e.toString())),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _processingDeviceIds.remove(deviceId));
      }
      _pendingDeletionCount--;

      // Show consolidated snackbar when all deletions are complete
      if (_pendingDeletionCount == 0 && mounted) {
        final scaffoldMessenger = ScaffoldMessenger.of(context);
        await _fetchE2EEInfo();
        if (_successfulDeletionCount > 0 && mounted) {
          final message = _successfulDeletionCount == 1
              ? context.l10n.deviceRemoved
              : context.l10n.nDevicesRemoved(_successfulDeletionCount);
          scaffoldMessenger.showSnackBar(SnackBar(content: Text(message)));
        }
        // Reset counters
        _successfulDeletionCount = 0;
      }
    }
  }

  Future<void> _confirmRevokeDevice(DeviceDocument device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.removeDevice_),
        content: Text(context.l10n.removeDeviceConfirmation(device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.remove),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _revokeDevice(device.id);
    }
  }

  void _onSyncChange() {
    if (!NoteSyncService().isSyncing.value) {
      _fetchStats();
    }
  }

  void _onE2EEStatusChange() {
    _fetchE2EEInfo();
  }

  Future<void> _fetchE2EEInfo() async {
    final e2ee = E2EEService.instance;

    if (mounted) {
      setState(() {
        _isLoadingDevices = true;
        _devicesError = null;
      });
    }

    try {
      // Check if current device is still authorized (detects revocation/removal)
      await e2ee.deviceManager.checkCurrentDeviceAuthorization();

      final devices = await e2ee.deviceManager.getDevices();
      final currentDeviceId = await E2EESecureStorage.instance.getDeviceId();
      final isFirst = await e2ee.deviceManager.isFirstDevice();
      final hasRecovery = await e2ee.recoveryKeyService.hasRecoveryKey();

      // Determine if this is the "master" device (first approved device)
      bool isMaster = false;
      if (devices.isNotEmpty && currentDeviceId != null) {
        final approvedDevices = devices.where((d) => d.isApproved).toList();
        if (approvedDevices.isNotEmpty) {
          // Sort by creation date, first one is the master
          approvedDevices.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          isMaster = approvedDevices.first.id == currentDeviceId;
        }
      }

      if (mounted) {
        setState(() {
          _devices = devices;
          _currentDeviceId = currentDeviceId;
          _isFirstDevice = isMaster || isFirst;
          _hasRecoveryKey = hasRecovery;
          _isLoadingDevices = false;
          _devicesError = null;
        });
      }
    } catch (e) {
      // Check if it's a network error
      final errorMessage = e.toString().toLowerCase();
      final isNetworkError =
          errorMessage.contains('network') ||
          errorMessage.contains('internet') ||
          errorMessage.contains('socket') ||
          errorMessage.contains('connection') ||
          errorMessage.contains('host') ||
          errorMessage.contains('unavailable');

      if (mounted) {
        setState(() {
          _isLoadingDevices = false;
          _devicesError = isNetworkError
              ? context.l10n.noInternetConnection
              : null; // Silently ignore other errors (E2EE not set up)
        });
      }
    }
  }

  Widget _buildDangerZone(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.red.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Text(
                  context.l10n.dangerZone,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.dangerZoneDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _scheduleAccountDeletion,
                icon: const Icon(Icons.delete_forever, color: Colors.red),
                label: Text(context.l10n.deleteMyAccount),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _exportData() async {
    final exportService = ExportDataService();
    String? exportPath;
    bool cancelled = false;
    bool exportComplete = false;

    // Start export and show dialog concurrently
    final exportFuture = exportService
        .exportAllData(
          includeAttachments: true,
          onStatus: (status) {
            // Status updates handled by ValueNotifier
          },
        )
        .then((path) {
          exportPath = path;
          exportComplete = true;
          return path;
        });

    // Show export progress dialog
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(context.l10n.exportingData),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: exportService.progress,
                builder: (context, progress, _) {
                  // Auto-close dialog when export completes
                  if (progress >= 1.0 && exportComplete && !cancelled) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (Navigator.canPop(dialogContext)) {
                        Navigator.pop(dialogContext);
                      }
                    });
                  }
                  return Column(
                    children: [
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 16),
                      Text("${(progress * 100).toInt()}%"),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: exportService.status,
                builder: (context, status, _) {
                  return Text(
                    status,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  );
                },
              ),
            ],
          ),
          actions: [
            ValueListenableBuilder<double>(
              valueListenable: exportService.progress,
              builder: (context, progress, _) {
                if (progress >= 1.0) {
                  return TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(context.l10n.done),
                  );
                }
                return TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(dialogContext);
                  },
                  child: Text(context.l10n.cancel),
                );
              },
            ),
          ],
        );
      },
    );

    // Wait for export to complete if not cancelled
    if (!cancelled && !exportComplete) {
      exportPath = await exportFuture;
    }

    if (cancelled || exportPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cancelled
                  ? context.l10n.exportCancelled
                  : context.l10n.exportFailed,
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return false;
    }

    if (mounted) {
      final shareExport = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.exportComplete),
          content: Text(context.l10n.exportCompleteMessage(exportPath!)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.close),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.share),
            ),
          ],
        ),
      );

      if (shareExport == true && exportPath != null) {
        await exportService.shareExport(exportPath!);
      }
    }

    return true;
  }

  /// Sends OTP to user's email and shows input dialog
  /// Returns the OTP string if entered, null if cancelled
  Future<String?> _getVerificationCode() async {
    final functions = FirebaseFunctions.instance;

    // Show loading dialog with timeout and cancel support
    final loadingResult = await showLoadingDialog<Map<String, dynamic>>(
      context: context,
      config: LoadingDialogConfig(
        message: context.l10n.sendingVerificationCode,
        showCancelAfter: Duration(seconds: 5),
        timeout: Duration(seconds: 30),
        timeoutMessage: context.l10n.takingTooLong,
      ),
      operation: () async {
        final sendOtpCallable = functions.httpsCallable('sendDeletionOtp');
        final result = await sendOtpCallable.call();
        return result.data as Map<String, dynamic>;
      },
    );

    if (!mounted) return null;

    // Handle cancellation or timeout
    if (loadingResult.cancelled || loadingResult.timedOut) {
      if (loadingResult.timedOut) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.requestTimedOut),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return null;
    }

    if (!loadingResult.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loadingResult.error ?? context.l10n.failedSendCode),
          backgroundColor: Colors.red,
        ),
      );
      return null;
    }

    final maskedEmail = loadingResult.data?['email'] as String?;

    // Show OTP input dialog using reusable component
    // Note: We don't verify on server here - just collect the OTP
    // The OTP is verified atomically with the deletion request
    if (!mounted) return null;
    final result = await showOtpDialog(
      context,
      OtpDialogConfig(
        title: context.l10n.verifyYourIdentity,
        maskedEmail: maskedEmail ?? 'your email',
        icon: Icons.delete_forever,
        isDestructive: true,
        verifyButtonLabel: context.l10n.continue_,
        // No verifyFunctionName - we just want to collect the OTP
      ),
    );

    return result?.otp;
  }

  Future<void> _scheduleAccountDeletion() async {
    // Show a dangerous-looking warning dialog
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          icon: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.warning_rounded,
              color: Colors.red.shade700,
              size: 48,
            ),
          ),
          title: Text(
            context.l10n.deleteYourAccount,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.red.shade700,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Colors.red.shade700,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.actionIrreversible,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildWarningItem(
                      context.l10n.allNotesDeleted,
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      context.l10n.allAttachmentsRemoved,
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      context.l10n.loggedOutAllDevices,
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      context.l10n.accountCannotBeRecovered,
                      Colors.red.shade700,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.gracePeriodInfo,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.verificationCodeViaEmail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.keepMyAccount),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
              ),
              child: Text(context.l10n.deleteAccount),
            ),
          ],
        );
      },
    );

    if (proceed != true || !mounted) return;

    // Get verification code from user (OTP will be verified atomically with deletion)
    final otp = await _getVerificationCode();
    if (otp == null || !mounted) {
      return;
    }

    // Schedule deletion first (OTP verified atomically on server)
    String? deleteAt;
    try {
      setState(() => _isLoading = true);

      final user = AuthService.currentUser;
      if (user == null) {
        throw Exception(context.l10n.userNotSignedIn);
      }

      // Call Cloud Function to schedule deletion with OTP for atomic verification
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('scheduleAccountDeletion');
      final result = await callable.call({'otp': otp});

      deleteAt = result.data['deleteAt'] as String?;
      setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        String errorMessage = context.l10n.failedScheduleDeletion;
        if (e is FirebaseFunctionsException) {
          errorMessage = e.message ?? errorMessage;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
        );
      }
      return;
    }

    if (!mounted) return;

    // Deletion scheduled successfully - now offer to export data before signing out
    final exportChoice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final deleteDate = deleteAt != null
            ? DateTime.parse(deleteAt).toLocal().toString().split(' ')[0]
            : "30 days from now";
        return AlertDialog(
          icon: Icon(
            Icons.check_circle,
            color: Colors.green.shade600,
            size: 48,
          ),
          title: Text(context.l10n.deletionScheduled),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.accountWillBeDeletedOn(deleteDate),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.exportBeforeSignOut,
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'skip'),
              child: Text(context.l10n.skip),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'export'),
              icon: const Icon(Icons.download),
              label: Text(context.l10n.exportData),
            ),
          ],
        );
      },
    );

    // If user wants to export, do that before signing out
    if (exportChoice == 'export' && mounted) {
      await _exportData();
    }

    // Sign out after scheduling deletion
    await AuthService.signOut();

    if (mounted) {
      final deleteDate = deleteAt != null
          ? DateTime.parse(deleteAt).toLocal().toString().split(' ')[0]
          : "30 days from now";

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.deletionScheduledMessage(deleteDate)),
          duration: const Duration(seconds: 6),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  Future<void> _fetchStats() async {
    final db = AppState.db;

    final total = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM note WHERE trashed = 0'),
    );

    final notes = await Note.get(NoteType.all);

    int reminders = 0;
    int media = 0;
    final now = DateTime.now();

    for (final note in notes) {
      if (note.reminder != null) {
        try {
          if (note.reminder!.dateTime.isAfter(now)) {
            reminders++;
          }
        } catch (e) {
          // ignore
        }
      }

      media += note.attachments.length;
    }

    if (mounted) {
      setState(() {
        _totalNotes = total ?? 0;
        _upcomingReminders = reminders;
        _totalMedia = media;
        _isLoading = false;
      });
    }
  }

  Widget _buildWarningItem(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.remove_circle_outline, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    String value,
    String label,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Helper class for provider information
class _ProviderInfo {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final VoidCallback? onLink;

  const _ProviderInfo({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    this.onLink,
  });
}
