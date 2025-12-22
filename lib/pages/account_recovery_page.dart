import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/dialogs/recovery_key_dialog.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
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
        const SnackBar(
          content: Text('Recovery successful! Welcome back.'),
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
          const SnackBar(
            content: Text(
              'Approval request sent! Approve from another device.',
            ),
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
              'Checking account status...',
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
                ? 'Recover Your Account'
                : 'Account Recovery Required',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            _hasRecoveryKey
                ? 'No active devices found. Use your recovery passphrase to restore access to your encrypted notes.'
                : 'No active devices found and no recovery key is set up. You can start fresh with a new account, but your previous notes cannot be recovered.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          if (_hasRecoveryKey) ...[
            // Recovery option
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _recoverWithPassphrase,
                icon: const Icon(Icons.key),
                label: const Text('Recover with Passphrase'),
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
                label: const Text('Start Fresh Instead'),
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
                      'Your previous notes are encrypted and cannot be recovered without a recovery key.',
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
                label: const Text('Start Fresh'),
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
            'Not your main device?',
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'If you have another device with access to your notes, you can request approval from that device.',
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
                    ? 'Requesting...'
                    : 'Request Approval from Another Device',
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
            label: Text(_isSigningOut ? 'Signing out...' : 'Sign Out'),
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

    // Show loading indicator while sending OTP
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Sending verification code...'),
          ],
        ),
      ),
    );

    String? maskedEmail;

    try {
      // Send OTP for start fresh
      final sendOtpCallable = functions.httpsCallable('sendStartFreshOtp');
      final result = await sendOtpCallable.call();
      maskedEmail = result.data['email'] as String?;

      if (!mounted) return null;
      Navigator.of(context).pop(); // Close loading dialog
    } catch (e) {
      if (!mounted) return null;
      Navigator.of(context).pop(); // Close loading dialog

      String errorMessage = 'Failed to send verification code';
      if (e is FirebaseFunctionsException) {
        errorMessage = e.message ?? errorMessage;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
      );
      return null;
    }

    // Show OTP input dialog
    final otp = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        String otpInput = '';
        String? errorText;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Verify Your Identity'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A 6-digit verification code has been sent to:',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    maskedEmail ?? 'your email',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      labelText: 'Verification Code',
                      hintText: 'Enter 6-digit code',
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                    onChanged: (value) {
                      otpInput = value;
                      if (errorText != null) {
                        setState(() => errorText = null);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Code expires in 10 minutes',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, null),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    if (otpInput.length != 6) {
                      setState(() => errorText = 'Please enter 6 digits');
                      return;
                    }
                    Navigator.pop(dialogContext, otpInput);
                  },
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        );
      },
    );

    return otp;
  }

  Future<void> _confirmAndStartFresh() async {
    if (!_confirmed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please confirm that you understand the consequences'),
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

      // Call Firebase function with OTP to clear devices server-side
      final functions = FirebaseFunctions.instance;
      final startFreshCallable = functions.httpsCallable('startFreshWithOtp');
      await startFreshCallable.call({'otp': otp});

      AppLogger.log('StartFresh: Server-side reset complete');

      // Now clear local data and set up as first device
      await E2EEService.instance.startFresh();

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account reset successfully. Welcome!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      AppLogger.error('StartFresh: Firebase error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? 'Failed to reset account'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      AppLogger.error('StartFresh: Error', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reset account: $e'),
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
            'Start Fresh?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'This action will:',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          _buildConsequenceItem(context, 'Remove all device authorizations'),
          _buildConsequenceItem(context, 'Make your old notes unrecoverable'),
          _buildConsequenceItem(context, 'Create a new encryption key'),
          _buildConsequenceItem(context, 'Start with a blank account'),
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
                    'I understand that my old notes will be permanently inaccessible',
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
                label: const Text('Start Fresh'),
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
                child: const Text('Cancel'),
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
