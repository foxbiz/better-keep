import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:better_keep/components/device_verification.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';

import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/pages/account_recovery_page.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
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
  DeviceVerificationRequest? _verification;
  DeviceApprovalReceipt? _receipt;
  bool _verifyingReceipt = false;
  bool _refreshing = false;
  bool _loadingVerification = false;
  bool _verificationFailed = false;
  bool _rememberDevice = true;
  bool _hasRecoveryKey = false;
  bool _isCheckingStatus = false;
  bool _isCancellingRequest = false;

  @override
  void initState() {
    super.initState();
    _loadRememberDevicePreference();
    _loadVerification();
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

  Future<void> _loadVerification({bool regenerate = false}) async {
    if (_loadingVerification ||
        _e2eeService.status.value == E2EEStatus.revoked) {
      return;
    }
    setState(() {
      _loadingVerification = true;
      _verificationFailed = false;
    });
    try {
      final request = await _deviceManager.ensureVerificationRequest(
        regenerate: regenerate,
      );
      final receipt = await _deviceManager.pendingApprovalReceipt();
      if (receipt?.hasPairingProof == true) {
        await _e2eeService.refreshStatus();
        if (!_deviceManager.hasUMK.value) {
          throw StateError('Device pairing could not be authenticated');
        }
      }
      if (mounted) {
        setState(() {
          _verification = request;
          _receipt = receipt?.hasPairingProof == true ? null : receipt;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _verificationFailed = true);
    } finally {
      if (mounted) setState(() => _loadingVerification = false);
    }
  }

  Future<void> _loadRememberDevicePreference() async {
    final remember = await E2EESecureStorage.instance.getRememberDevice();
    if (mounted) {
      setState(() {
        _rememberDevice = remember;
      });
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
    if (_refreshing || _loadingVerification || _verifyingReceipt) return;
    _refreshing = true;
    try {
      await _e2eeService.refreshStatus();
      final receipt = await _deviceManager.pendingApprovalReceipt();
      if (mounted) {
        setState(() {
          _receipt = receipt?.hasPairingProof == true ? null : receipt;
          _verificationFailed =
              receipt?.hasPairingProof == true && !_deviceManager.hasUMK.value;
        });
      }
    } catch (_) {
      if (mounted) {
        // A failed read does not invalidate the last verified request/receipt.
        // Expiration and request binding are still checked before approval.
        setState(() {
          if (_verification == null && _receipt == null) {
            _verificationFailed = true;
          }
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _verifyReceipt() async {
    final receipt = _receipt;
    if (receipt == null || _verifyingReceipt) return;
    setState(() => _verifyingReceipt = true);
    try {
      final verified = await showDeviceReceiptVerificationDialog(
        context,
        receipt,
      );
      if (!mounted || verified == null) return;
      await _deviceManager.acceptVerifiedApproval(verified);
      await _e2eeService.recheckCloudReadinessAfterDeviceChange();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.deviceVerificationRetry)),
        );
      }
    } finally {
      if (mounted) setState(() => _verifyingReceipt = false);
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
      try {
        await _deviceManager.cancelApprovalRequest();
      } catch (_) {
        /* Local keys are discarded even if cancellation is offline. */
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
      await _loadVerification();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.reapprovalRequestSent)),
        );
        setState(() {});
      }
    } catch (error, stackTrace) {
      AppLogger.error('Failed to request device reapproval', error, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.somethingWentWrongTryAgain)),
        );
      }
    } finally {
      if (mounted) setState(() => _isRequestingReapproval = false);
    }
  }

  Future<void> _showMoreOptions() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, updateSheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  context.l10n.moreOptions,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (_hasRecoveryKey)
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: Text(context.l10n.recoverWithPassphrase),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _recoverWithPassphrase();
                  },
                ),
              if (_e2eeService.status.value != E2EEStatus.revoked &&
                  !_deviceManager.wasRevoked.value) ...[
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: Text(context.l10n.checkStatus),
                  enabled: !_isCheckingStatus,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _checkApprovalStatus();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.qr_code_2),
                  title: Text(context.l10n.newVerificationCode),
                  enabled: !_loadingVerification && !_verifyingReceipt,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _loadVerification(regenerate: true);
                  },
                ),
              ],
              if (kIsWeb)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(context.l10n.encryption),
                  subtitle: Text(context.l10n.browserEncryptionSessionOnly),
                )
              else
                SwitchListTile(
                  secondary: const Icon(Icons.devices_outlined),
                  title: Text(context.l10n.rememberThisDevice),
                  subtitle: Text(context.l10n.deviceRemovedOnSignOut),
                  value: _rememberDevice,
                  onChanged: (value) {
                    _setRememberDevice(value);
                    updateSheet(() {});
                  },
                ),
              const Divider(indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: Text(context.l10n.startFresh),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const StartFreshConfirmationPage(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isRevoked =
        _e2eeService.status.value == E2EEStatus.revoked ||
        _deviceManager.wasRevoked.value;
    final hasReceipt = _receipt?.isValidAt(DateTime.now()) == true;
    return AuthScaffold(
      showLogo: false,
      child: DeviceApprovalPanel(
        title: isRevoked
            ? context.l10n.deviceRevoked
            : hasReceipt
            ? context.l10n.verifyTrustedDevice
            : context.l10n.verifyNewDevice,
        icon: isRevoked ? Icons.lock_outline : Icons.devices_outlined,
        onMoreOptions: _isCancellingRequest ? null : _showMoreOptions,
        onCancel: _isCancellingRequest ? null : _cancelRequest,
        cancelLabel: _isCancellingRequest
            ? context.l10n.pleaseWait
            : isRevoked
            ? context.l10n.signOut
            : context.l10n.cancel,
        child: isRevoked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.deviceRevokedDescription,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _isRequestingReapproval
                        ? null
                        : _requestReapproval,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      _isRequestingReapproval
                          ? context.l10n.pleaseWait
                          : context.l10n.requestReapproval,
                    ),
                  ),
                ],
              )
            : hasReceipt
            ? DeviceReceiptVerificationPrompt(
                key: const ValueKey('receipt-verification-prompt'),
                receipt: _receipt!,
                onVerify: _verifyReceipt,
              )
            : _verification != null && !_verificationFailed
            ? DeviceVerificationCard(
                request: _verification!,
                onRegenerate: _loadingVerification
                    ? null
                    : () => _loadVerification(regenerate: true),
              )
            : _loadingVerification
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.deviceVerificationRetry,
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: () => _loadVerification(regenerate: true),
                    child: Text(context.l10n.newVerificationCode),
                  ),
                ],
              ),
      ),
    );
  }
}
