import 'dart:io';

import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/dialogs/loading_dialog.dart';
import 'package:better_keep/dialogs/otp_dialog.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/pages/setup_recovery_key_page.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/sync/note_sync_track.dart';
import 'package:better_keep/services/auth/auth_service.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/services/device_approval_notification_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/services/sync/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
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
    NoteSyncService().isSyncing.addListener(_onSyncChange);
    E2EEService.instance.status.addListener(_onE2EEStatusChange);
    E2EEService.instance.deviceManager.pendingApprovals.addListener(
      _onPendingApprovalsChange,
    );
    super.initState();
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
              tooltip: 'Refresh',
            ),
          TextButton.icon(
            onPressed: () => _handleSignOut(context),
            icon: const Icon(Icons.logout),
            label: const Text("Sign Out"),
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
                              "Notes",
                              Icons.note_outlined,
                            ),
                            _buildStatItem(
                              context,
                              _upcomingReminders.toString(),
                              "Reminders",
                              Icons.alarm_outlined,
                            ),
                            _buildStatItem(
                              context,
                              _totalMedia.toString(),
                              "Media",
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
        const SnackBar(
          content: Text('All up to date'),
          duration: Duration(seconds: 2),
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
          title: const Text(
            "⚠️ UNSYNCED NOTES",
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
                        "$pendingSyncCount note${pendingSyncCount == 1 ? '' : 's'} not synced",
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
              const Text(
                "You have notes that haven't been synced to the cloud yet. "
                "If you sign out now, these notes will be LOST FOREVER.\n\n"
                "Consider waiting for sync to complete or exporting your data first.",
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text("Sign Out Anyway"),
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
          title: const Text(
            "⚠️ DATA LOSS WARNING",
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
                child: const Row(
                  children: [
                    Icon(Icons.key_off, color: Colors.red),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "No recovery key set up",
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "If you sign out and lose access to all your approved devices, "
                "you will PERMANENTLY lose access to ALL your encrypted notes.\n\n"
                "This action cannot be undone.",
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text("Sign Out Anyway"),
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
          title: const Text(
            "Sign Out",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: const Text(
            "Are you sure you want to sign out?\n\n"
            "You will need to sign in again to access your notes.",
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text("Sign Out"),
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
            content: Text('Error signing out: $e'),
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
                        count == 1
                            ? "1 Device Waiting for Approval"
                            : "$count Devices Waiting for Approval",
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade800,
                        ),
                      ),
                      Text(
                        "Review and approve to grant access",
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
              child: const Text("Approve"),
            ),
            IconButton(
              icon: Icon(Icons.close, color: theme.colorScheme.error, size: 20),
              onPressed: () => _revokeDevice(request.deviceId),
              tooltip: "Deny",
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
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
                            'Subscription',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            status.isTrialSubscription
                                ? 'Trial'
                                : '${plan.displayName} Plan',
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
                            label: const Text('Upgrade to Pro'),
                          ),
                        ),
                      ],
                    ),
                  ] else if (status.isCancelledButActive &&
                      status.isRazorpaySubscription) ...[
                    // Cancelled but still in subscription period
                    // Razorpay doesn't support resuming cancel_at_cycle_end subscriptions
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
                            'Subscription Cancelled',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Your Pro access will end on ${_formatDate(status.expiresAt)}. '
                            'You can subscribe again after it expires.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
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
                          label: const Text('DEBUG: Delete Subscription'),
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
                              ? 'Cancelling...'
                              : status.isRazorpaySubscription
                              ? 'Cancel Subscription'
                              : 'Manage Subscription',
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
                          label: const Text('DEBUG: Delete Subscription'),
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
                    'Upgrade to Pro for unlimited locked notes, cloud sync, and more.',
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
                          label: const Text('Upgrade to Pro'),
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
      label = plan.displayName.toUpperCase();
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
      billingText = 'Free Trial';
    } else {
      switch (status.billingPeriod) {
        case BillingPeriod.monthly:
          billingText = 'Monthly subscription';
          break;
        case BillingPeriod.yearly:
          billingText = 'Yearly subscription';
          break;
        case null:
          billingText = 'Subscription';
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
                      'Free Trial Active',
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
                    'Expires ${_formatDate(status.expiresAt!)} (${status.daysUntilExpiration} days left)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Enjoy all Pro features during your trial!',
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
          _buildDetailRow(context, Icons.payment, 'Billing', billingText),
          if (status.expiresAt != null) ...[
            const SizedBox(height: 8),
            _buildDetailRow(
              context,
              status.willAutoRenew ? Icons.autorenew : Icons.event,
              status.willAutoRenew ? 'Renews' : 'Expires',
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
                    'Your subscription is in a grace period. Please update your payment method.',
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
            'You already have an active ${status.plan.displayName} subscription!',
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
                const Expanded(child: Text('Upgrade Now?')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You still have $expiryText on your free trial.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'If you subscribe now, your trial will end immediately and billing will start right away.',
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
                child: const Text('Continue Trial'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Upgrade Now'),
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
          title: const Text('Cancel Subscription'),
          content: const Text(
            'Are you sure you want to cancel your subscription?\n\n'
            'Your subscription will remain active until the end of the current billing period. '
            'After that, you will lose access to Pro features.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep Subscription'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Cancel Subscription'),
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
        title: const Row(
          children: [
            Icon(Icons.bug_report, color: Colors.orange),
            SizedBox(width: 8),
            Text('DEBUG: Delete Subscription'),
          ],
        ),
        content: const Text(
          'This will immediately delete your subscription from the database.\n\n'
          'This is for TESTING ONLY and will not cancel the actual Razorpay subscription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Delete'),
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
                ? 'DEBUG: Subscription deleted successfully'
                : 'DEBUG: Failed to delete subscription',
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
                        'Connected Accounts',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Sign in with any linked account',
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
                      'Linking requires authentication with each platform to verify ownership.',
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
                    'Connected',
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
                message: 'Cannot unlink the original sign-in method',
                child: TextButton(
                  onPressed: null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('Primary'),
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
                child: const Text('Unlink'),
              ),
          ] else if (provider.onLink != null)
            FilledButton.tonal(
              onPressed: provider.onLink,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Link'),
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
      'twitter': 'twitter.com',
    };
    final providerId = providerIds[providerName.toLowerCase()];
    if (providerId == null) {
      snackbar('Unknown provider: $providerName', Colors.red);
      return;
    }

    try {
      // Step 1: Show loading and request OTP
      if (!mounted) return;

      final loadingResult = await showLoadingDialog<Map<String, dynamic>>(
        context: context,
        config: const LoadingDialogConfig(
          message: 'Sending verification code...',
          showCancelAfter: Duration(seconds: 5),
          timeout: Duration(seconds: 30),
          timeoutMessage: 'Taking too long. You can cancel and try again.',
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
        snackbar('Request timed out. Please try again.', Colors.orange);
        return;
      }
      if (!loadingResult.success) {
        snackbar(
          loadingResult.error ?? 'Failed to send verification code',
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
          title: 'Verify Account Link',
          maskedEmail: maskedEmail,
          icon: Icons.link,
          verifyButtonLabel: 'Verify & Link',
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
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Linking account...'),
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
        case 'twitter':
          await AuthService.linkWithTwitter();
          break;
      }

      // Dismiss loading dialog
      if (mounted) Navigator.of(context).pop();

      // Refresh UI to show new linked provider
      if (mounted) {
        await _fetchE2EEInfo(); // Refresh user data including linked providers
        setState(() {});
        snackbar('Successfully linked $providerName account', Colors.green);
      }
    } on FirebaseFunctionsException catch (e) {
      // Dismiss any dialogs
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      String errorMessage = 'Failed to link account';

      switch (e.code) {
        case 'unauthenticated':
          errorMessage = 'Please sign in again and try.';
          break;
        case 'failed-precondition':
          errorMessage = 'No email associated with your account.';
          break;
        case 'already-exists':
          errorMessage = '$providerName is already linked to your account.';
          break;
        case 'resource-exhausted':
          errorMessage = e.message ?? 'Please wait before requesting again.';
          break;
        case 'deadline-exceeded':
          errorMessage = 'Session expired. Please try again.';
          break;
        default:
          errorMessage = e.message ?? 'Failed to link account';
      }

      if (mounted) snackbar(errorMessage, Colors.red);
    } catch (e) {
      // Dismiss loading dialog if showing
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      String errorMessage = 'Failed to link account';
      final errorStr = e.toString();

      if (errorStr.contains('credential-already-in-use')) {
        errorMessage =
            'This $providerName account is already linked to another user.';
      } else if (errorStr.contains('provider-already-linked')) {
        errorMessage = '$providerName is already linked to your account.';
      } else if (errorStr.contains('email-already-in-use')) {
        errorMessage =
            'An account with this email already exists. '
            'Sign in with that account first, then link from there.';
      } else if (errorStr.contains('cancelled') ||
          errorStr.contains('canceled')) {
        errorMessage = 'Linking was cancelled.';
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
          title: Text('Unlink ${provider.name}?'),
          content: const Text(
            'You will no longer be able to sign in with this account. '
            'Make sure you have another way to access your account.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Unlink'),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      await AuthService.unlinkProvider(provider.id);

      if (mounted) {
        setState(() {});
        snackbar('Unlinked ${provider.name}', Colors.green);
      }
    } catch (e) {
      String errorMessage = 'Failed to unlink account';
      final errorStr = e.toString();

      if (errorStr.contains('Cannot unlink')) {
        errorMessage = 'Cannot unlink the only sign-in method.';
      } else if (e is Exception) {
        final msg = errorStr.replaceFirst('Exception: ', '');
        if (msg.length < 100) errorMessage = msg;
      }

      if (mounted) {
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
                    const Text("Recovery Key"),
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
                          "Important",
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
                subtitle: const Text("Manage your recovery passphrase"),
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
                  label: const Text("Enable End-to-End Encryption"),
                ),
              ),
            ],

            if (status == E2EEStatus.pendingApproval) ...[
              const SizedBox(height: 12),
              Text(
                "Open Better Keep on an already-authorized device to approve this device.",
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
                  "Your Devices",
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
                      child: const Text('Retry'),
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
                  "Pending Approval",
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
                  "Authorized Devices",
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
                          "This device",
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
                  tooltip: "Approve",
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.red),
                  onPressed: () => _revokeDevice(device.id),
                  tooltip: "Deny",
                ),
              ],
            )
          else if (canManage)
            IconButton(
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              onPressed: () => _confirmRevokeDevice(device),
              tooltip: "Remove device",
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
        title: const Text("Enable End-to-End Encryption"),
        content: const Text(
          "This will encrypt all your notes and attachments. "
          "Only devices you authorize will be able to read them.\n\n"
          "Make sure to set up a recovery key after enabling E2EE, "
          "or you may lose access to your notes if you lose all your devices.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Enable E2EE"),
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
          if (recoverySetup == true) {
            scaffoldMessenger.showSnackBar(
              const SnackBar(content: Text('Recovery key saved successfully!')),
            );
          } else {
            // User skipped - show warning
            scaffoldMessenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Warning: Without a recovery key, you may lose access to your notes if you lose all devices.',
                ),
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Failed to enable E2EE: $e")));
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
          title: const Text('Recovery Key'),
          content: const Text(
            'You have a recovery key set up. What would you like to do?',
          ),
          actions: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'remove'),
                  child: Text(
                    'Remove',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'update'),
                  child: const Text('Update'),
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
            const SnackBar(content: Text('Recovery key updated!')),
          );
        }
      } else if (action == 'remove' && mounted) {
        // Use secure remove dialog that requires current passphrase
        final removed = await showRemoveRecoveryKeyDialog(context);
        if (removed == true && mounted) {
          setState(() => _hasRecoveryKey = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Recovery key removed')));
        }
      }
    } else {
      // No recovery key - set one up
      final created = await showSetupRecoveryKeyPage(context);
      if (created == true && mounted) {
        setState(() => _hasRecoveryKey = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recovery key saved!')));
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
        ).showSnackBar(const SnackBar(content: Text("Device approved")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Failed to approve device: $e")));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Failed to remove device: $e")));
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
        if (_successfulDeletionCount > 0) {
          final message = _successfulDeletionCount == 1
              ? "Device removed"
              : "$_successfulDeletionCount devices removed";
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
        title: const Text("Remove Device"),
        content: Text(
          'Are you sure you want to remove "${device.name}"?\n\n'
          "This device will no longer have access to your notes.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Remove"),
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
              ? 'No internet connection. Please check your network and try again.'
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
                  "Danger Zone",
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "Permanently delete your account and all associated data. "
              "This action will be completed after a 30-day grace period.",
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
                label: const Text("Delete My Account"),
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
          title: const Text("Exporting Data"),
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
                    child: const Text("Done"),
                  );
                }
                return TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.pop(dialogContext);
                  },
                  child: const Text("Cancel"),
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
            content: Text(cancelled ? "Export cancelled" : "Export failed"),
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
          title: const Text("Export Complete"),
          content: Text(
            "Your data has been exported successfully.\n\n"
            "File saved to:\n$exportPath\n\n"
            "Would you like to share the export file?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Close"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Share"),
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
      config: const LoadingDialogConfig(
        message: 'Sending verification code...',
        showCancelAfter: Duration(seconds: 5),
        timeout: Duration(seconds: 30),
        timeoutMessage: 'Taking too long. You can cancel and try again.',
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
          const SnackBar(
            content: Text('Request timed out. Please try again.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return null;
    }

    if (!loadingResult.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loadingResult.error ?? 'Failed to send verification code',
          ),
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
        title: 'Verify Your Identity',
        maskedEmail: maskedEmail ?? 'your email',
        icon: Icons.delete_forever,
        isDestructive: true,
        verifyButtonLabel: 'Continue',
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
            "Delete Your Account?",
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
                          "This action is irreversible",
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildWarningItem(
                      "All your notes will be permanently deleted",
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      "All attachments and media will be removed",
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      "You will be logged out from all devices",
                      Colors.red.shade700,
                    ),
                    _buildWarningItem(
                      "Your account cannot be recovered",
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
                        "30-day grace period: Sign back in to cancel deletion.",
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "You will receive a verification code via email.",
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
              child: const Text("Keep My Account"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
              ),
              child: const Text("Delete Account"),
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
        throw Exception("User not signed in");
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
        String errorMessage = "Failed to schedule deletion";
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
          title: const Text("Deletion Scheduled"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Your account will be deleted on $deleteDate.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                "Would you like to export your data before signing out?",
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'skip'),
              child: const Text("Skip"),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'export'),
              icon: const Icon(Icons.download),
              label: const Text("Export Data"),
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
          content: Text(
            "Account deletion scheduled for $deleteDate. "
            "Sign in again to cancel.",
          ),
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
