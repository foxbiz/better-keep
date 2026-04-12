import 'dart:async';

import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/pages/account_recovery_page.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// Page shown when a device is pending approval or has been revoked.
class PendingApprovalPage extends StatefulWidget {
  const PendingApprovalPage({super.key});

  @override
  State<PendingApprovalPage> createState() => _PendingApprovalPageState();
}

class _PendingApprovalPageState extends State<PendingApprovalPage> {
  final E2EEService _e2eeService = E2EEService.instance;
  final DeviceManager _deviceManager = DeviceManager.instance;
  final RecoveryKeyService _recoveryKeyService = RecoveryKeyService.instance;
  Timer? _refreshTimer;
  bool _rememberDevice = true;
  String? _masterDeviceName;
  bool _hasRecoveryKey = false;
  bool _isCheckingStatus = false;
  bool _isCancellingRequest = false;

  @override
  void initState() {
    super.initState();
    _loadRememberDevicePreference();
    _loadMasterDeviceInfo();
    _checkRecoveryKey();
    // Periodically check for approval (silently)
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _silentRefreshStatus();
    });
    // Also listen to device manager
    _deviceManager.hasUMK.addListener(_onUMKChanged);
    _deviceManager.wasRevoked.addListener(_onRevokedChanged);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _deviceManager.hasUMK.removeListener(_onUMKChanged);
    _deviceManager.wasRevoked.removeListener(_onRevokedChanged);
    super.dispose();
  }

  Future<void> _loadRememberDevicePreference() async {
    final remember = await E2EESecureStorage.instance.getRememberDevice();
    if (mounted) {
      setState(() {
        _rememberDevice = remember;
      });
    }
  }

  Future<void> _loadMasterDeviceInfo() async {
    try {
      final devices = await _deviceManager.getDevices();
      // Find the first approved device (master device) by approval date
      final approvedDevices = devices.where((d) => d.isApproved).toList()
        ..sort((a, b) {
          final aApproved = a.approvedAt ?? a.createdAt;
          final bApproved = b.approvedAt ?? b.createdAt;
          return aApproved.compareTo(bApproved);
        });

      if (approvedDevices.isNotEmpty && mounted) {
        setState(() {
          _masterDeviceName =
              '${approvedDevices.first.name} (${approvedDevices.first.platform})';
        });
      }
    } catch (_) {
      // Ignore errors, we'll just not show the device name
    }
  }

  Future<void> _checkRecoveryKey() async {
    try {
      final hasKey = await _recoveryKeyService.hasRecoveryKey();
      if (mounted) {
        setState(() => _hasRecoveryKey = hasKey);
      }
    } catch (_) {
      // Ignore errors
    }
  }

  Future<void> _recoverWithPassphrase() async {
    final success = await showRecoverWithPassphraseDialog(context);
    if (success == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.recoverySuccessful)));
    }
  }

  Future<void> _setRememberDevice(bool value) async {
    setState(() {
      _rememberDevice = value;
    });
    await E2EESecureStorage.instance.setRememberDevice(value);
  }

  void _onUMKChanged() {
    if (_deviceManager.hasUMK.value) {
      _e2eeService.status.value = E2EEStatus.ready;
    }
  }

  void _onRevokedChanged() {
    if (_deviceManager.wasRevoked.value) {
      setState(() {});
    }
  }

  /// Silent refresh - called by periodic timer, no snackbar feedback
  Future<void> _silentRefreshStatus() async {
    await _e2eeService.refreshStatus();
    if (mounted) {
      setState(() {});
    }
  }

  /// Manual check - called by button, shows snackbar feedback
  Future<void> _checkApprovalStatus() async {
    if (_isCheckingStatus) return;
    setState(() => _isCheckingStatus = true);
    try {
      await _e2eeService.refreshStatus();
      if (mounted) {
        final status = _e2eeService.status.value;
        if (status == E2EEStatus.ready) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.l10n.deviceApproved)));
        } else if (status == E2EEStatus.revoked) {
          // Don't show snackbar for revoked - UI already shows revoked state
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.waitingForApproval)),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isCheckingStatus = false);
      }
    }
  }

  Future<void> _cancelRequest() async {
    if (_isCancellingRequest) return;
    setState(() => _isCancellingRequest = true);

    try {
      // Delete the device registration and sign out
      final deviceId = await E2EESecureStorage.instance.getDeviceId();
      if (deviceId != null) {
        try {
          await _deviceManager.revokeDevice(deviceId);
        } catch (_) {
          // Device might not exist, that's ok
        }
      }
      await E2EESecureStorage.instance.clearAll();
      await AuthService.signOut();
    } finally {
      if (mounted) setState(() => _isCancellingRequest = false);
    }
  }

  bool _isRequestingReapproval = false;

  Future<void> _requestReapproval() async {
    setState(() => _isRequestingReapproval = true);
    try {
      await _deviceManager.requestReapproval();
      _e2eeService.status.value = E2EEStatus.pendingApproval;
      _deviceManager.clearRevokedFlag();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.reapprovalRequestSent)),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.failedReapproval(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isRequestingReapproval = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRevoked =
        _e2eeService.status.value == E2EEStatus.revoked ||
        _deviceManager.wasRevoked.value;
    final colorScheme = Theme.of(context).colorScheme;

    return AuthScaffold(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            isRevoked
                ? context.l10n.deviceRevoked
                : context.l10n.waitingForApprovalTitle,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (isRevoked)
            Text(
              context.l10n.deviceRevokedDescription,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          if (!isRevoked) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_masterDeviceName != null) ...[
              Text(
                context.l10n.pleaseApproveFrom,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smartphone, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _masterDeviceName!,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Text(
                context.l10n.waitingForApprovalFromDevice,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _rememberDevice,
                  onChanged: (value) => _setRememberDevice(value ?? true),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.rememberThisDevice),
                      Text(
                        context.l10n.deviceRemovedOnSignOut,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          if (_hasRecoveryKey) ...[
            TextButton.icon(
              onPressed: _recoverWithPassphrase,
              icon: const Icon(Icons.key),
              label: Text(context.l10n.recoverWithPassphrase),
            ),
            const SizedBox(height: 8),
          ],
          // Start Fresh option - for users who can't access primary device
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const StartFreshConfirmationPage(),
                ),
              );
            },
            icon: const Icon(Icons.restart_alt),
            label: Text(context.l10n.startFresh),
          ),
          const SizedBox(height: 8),
          if (isRevoked) ...[
            // Show re-approval button for revoked devices
            if (_isRequestingReapproval)
              const CircularProgressIndicator()
            else
              ElevatedButton.icon(
                onPressed: _requestReapproval,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.requestReapproval),
              ),
            const SizedBox(height: 16),
          ] else ...[
            // Manual check button for pending approval
            ElevatedButton.icon(
              onPressed: _isCheckingStatus ? null : _checkApprovalStatus,
              icon: _isCheckingStatus
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(
                _isCheckingStatus
                    ? context.l10n.checkingStatus
                    : context.l10n.checkStatus,
              ),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: _isCancellingRequest ? null : _cancelRequest,
            icon: _isCancellingRequest
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(isRevoked ? Icons.logout : Icons.cancel),
            label: Text(
              _isCancellingRequest
                  ? context.l10n.pleaseWait
                  : (isRevoked
                        ? context.l10n.signOut
                        : context.l10n.cancelRequest),
            ),
          ),
        ],
      ),
    );
  }
}
