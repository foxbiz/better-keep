import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/dialogs/loading_dialog.dart';
import 'package:better_keep/dialogs/otp_dialog.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Page shown when no approved devices exist and user needs to recover or start fresh.
class AccountRecoveryPage extends StatefulWidget {
  const AccountRecoveryPage({super.key});

  @override
  State<AccountRecoveryPage> createState() => _AccountRecoveryPageState();
}

class _AccountRecoveryPageState extends State<AccountRecoveryPage> {
  bool _hasRecoveryKey = false;
  bool _isLoading = true;
  bool _isRequestingApproval = false;
  bool _isSigningOut = false;

  @override
  void initState() {
    super.initState();
    _checkRecoveryKey();
  }

  Future<void> _checkRecoveryKey() async {
    try {
      final hasKey = await RecoveryKeyService.instance.hasRecoveryKey();
      if (mounted) {
        setState(() {
          _hasRecoveryKey = hasKey;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.log('AccountRecoveryPage: Error checking recovery key: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _recoverWithPassphrase() async {
    final success = await showRecoverWithPassphraseDialog(context);
    if (success == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.recoverySuccessfulWelcomeBack),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _requestApproval() async {
    setState(() => _isRequestingApproval = true);

    try {
      AppLogger.log('AccountRecoveryPage: User requesting approval');

      // Register this device as pending
      await DeviceManager.instance.registerNewDevice();

      // Update E2EE status to pending approval
      E2EEService.instance.status.value = E2EEStatus.pendingApproval;
      E2EEService.instance.listenForStatusChanges();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.approvalRequestSent),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      AppLogger.log('AccountRecoveryPage: Error requesting approval: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isRequestingApproval = false);
      }
    }
  }

  Future<void> _startFresh() async {
    // Navigate to start fresh confirmation page
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const StartFreshConfirmationPage(),
        ),
      );
    }
  }

  Future<void> _signOut() async {
    if (_isSigningOut) return;
    setState(() => _isSigningOut = true);
    try {
      await AuthService.signOut();
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return AuthScaffold(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
            Text(
              context.l10n.checkingAccountStatus,
              style: TextStyle(
                fontSize: 16,
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return AuthScaffold(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            _hasRecoveryKey
                ? context.l10n.recoverYourAccount
                : context.l10n.accountRecoveryRequired,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            _hasRecoveryKey
                ? context.l10n.noActiveDevicesRecoveryKey
                : context.l10n.noActiveDevicesNoRecoveryKey,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          if (_hasRecoveryKey) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _recoverWithPassphrase,
                icon: const Icon(Icons.key),
                label: Text(context.l10n.recoverWithPassphrase),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Start fresh as secondary option
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _startFresh,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.startFreshInstead),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ] else ...[
            // Warning container for no recovery key
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.error.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: colorScheme.error),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.l10n.previousNotesEncryptedWarning,
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Start fresh as primary option
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _startFresh,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.startFresh),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                ),
              ),
            ),
          ],

          // Divider with "Or" text
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: Divider(color: colorScheme.outline)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'OR',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Expanded(child: Divider(color: colorScheme.outline)),
            ],
          ),
          const SizedBox(height: 24),

          // Request approval option
          Text(
            context.l10n.notYourMainDevice,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.anotherDeviceApprovalHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isRequestingApproval ? null : _requestApproval,
              icon: _isRequestingApproval
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    )
                  : const Icon(Icons.devices),
              label: Text(
                _isRequestingApproval
                    ? context.l10n.requesting
                    : context.l10n.requestApprovalFromAnotherDevice,
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),

          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: _isSigningOut ? null : _signOut,
            icon: _isSigningOut
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout),
            label: Text(
              _isSigningOut ? context.l10n.signingOut : context.l10n.signOut,
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirmation page for starting fresh - requires OTP verification.
class StartFreshConfirmationPage extends StatefulWidget {
  const StartFreshConfirmationPage({super.key});

  @override
  State<StartFreshConfirmationPage> createState() =>
      _StartFreshConfirmationPageState();
}

class _StartFreshConfirmationPageState
    extends State<StartFreshConfirmationPage> {
  bool _isLoading = false;
  bool _confirmed = false;

  /// Sends OTP to user's email and shows input dialog.
  /// Returns the OTP string if entered, null if cancelled.
  Future<String?> _getVerificationCode() async {
    final functions = FirebaseFunctions.instance;

    // Show loading dialog with timeout and cancel support
    final loadingResult = await showLoadingDialog<Map<String, dynamic>>(
      context: context,
      config: LoadingDialogConfig(
        message: context.l10n.sendingVerificationCode,
        showCancelAfter: const Duration(seconds: 5),
        timeout: const Duration(seconds: 30),
        timeoutMessage: context.l10n.takingTooLongTryAgain,
      ),
      operation: () async {
        final sendOtpCallable = functions.httpsCallable('sendStartFreshOtp');
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
          content: Text(
            loadingResult.error ?? context.l10n.failedToSendVerificationCode,
          ),
          backgroundColor: Colors.red,
        ),
      );
      return null;
    }

    final maskedEmail = loadingResult.data?['email'] as String?;

    // Show OTP input dialog using reusable component
    if (!mounted) return null;
    final result = await showOtpDialog(
      context,
      OtpDialogConfig(
        title: context.l10n.verifyYourIdentity,
        maskedEmail: maskedEmail ?? context.l10n.yourEmail,
        icon: Icons.refresh,
        isDestructive: true,
        verifyButtonLabel: context.l10n.continueLabel,
        // No verifyFunctionName - OTP is verified atomically with startFreshWithOtp
      ),
    );

    return result?.otp;
  }

  Future<void> _confirmAndStartFresh() async {
    if (!_confirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pleaseConfirmConsequences),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Get OTP verification first
    final otp = await _getVerificationCode();
    if (otp == null) {
      // User cancelled or error occurred
      return;
    }

    setState(() => _isLoading = true);

    try {
      AppLogger.log('StartFresh: User confirmed, verifying OTP');

      // Call Firebase function with OTP
      final functions = FirebaseFunctions.instance;
      final startFreshCallable = functions.httpsCallable('startFreshWithOtp');

      await startFreshCallable.call({'otp': otp});

      AppLogger.log('StartFresh: Server-side reset complete');

      // Complete start fresh locally
      await E2EEService.instance.startFresh();

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.accountResetSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      AppLogger.error('StartFresh: Firebase error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? context.l10n.failedToResetAccount),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      AppLogger.error('StartFresh: Error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.failedToResetAccountError(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AuthScaffold(
      showLogo: false,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.warning_amber, size: 80, color: colorScheme.error),
          const SizedBox(height: 24),
          Text(
            context.l10n.startFreshQuestion,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.thisActionWill,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          _buildConsequenceItem(
            context,
            context.l10n.removeAllDeviceAuthorizations,
          ),
          _buildConsequenceItem(
            context,
            context.l10n.makeOldNotesUnrecoverable,
          ),
          _buildConsequenceItem(context, context.l10n.createNewEncryptionKey),
          _buildConsequenceItem(context, context.l10n.startWithBlankAccount),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.error.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                Checkbox(
                  value: _confirmed,
                  onChanged: (value) =>
                      setState(() => _confirmed = value ?? false),
                  activeColor: colorScheme.error,
                ),
                Expanded(
                  child: Text(
                    context.l10n.iUnderstandOldNotesInaccessible,
                    style: TextStyle(
                      color: colorScheme.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (_isLoading)
            const CircularProgressIndicator()
          else ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _confirmAndStartFresh,
                icon: const Icon(Icons.delete_forever),
                label: Text(context.l10n.startFresh),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(context.l10n.cancel),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConsequenceItem(BuildContext context, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.cancel, size: 20, color: colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
