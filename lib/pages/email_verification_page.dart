import 'dart:async';

import 'package:better_keep/components/auth_scaffold.dart';
import 'package:better_keep/components/otp_input_field.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Page shown when a user is logged in but their email is not verified.
/// This page blocks access to the app until the email is verified via OTP.
class EmailVerificationPage extends StatefulWidget {
  const EmailVerificationPage({super.key});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  final _otpController = TextEditingController();
  final _focusNode = FocusNode();

  bool _isSendingOtp = false;
  bool _isVerifying = false;
  bool _otpSent = false;
  String? _maskedEmail;
  String? _errorMessage;
  Timer? _resendTimer;
  int _resendCountdown = 0;

  @override
  void initState() {
    super.initState();
    // Automatically send OTP when page loads
    _sendOtp();
  }

  @override
  void dispose() {
    _otpController.dispose();
    _focusNode.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  String get _otpValue => _otpController.text;

  Future<void> _sendOtp() async {
    if (_isSendingOtp) return;

    setState(() {
      _isSendingOtp = true;
      _errorMessage = null;
    });

    try {
      final result = await AuthService.sendEmailVerificationOtp();

      if (result['alreadyVerified'] == true) {
        // Email is already verified, reload user to trigger navigation
        await AuthService.currentUser?.reload();
        if (mounted) {
          setState(() {});
        }
        return;
      }

      if (mounted) {
        setState(() {
          _otpSent = true;
          _maskedEmail = result['email'] as String?;
          _startResendCountdown();
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? 'Failed to send verification code';
        });
      }
    } catch (e) {
      AppLogger.error('Error sending email verification OTP: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to send verification code. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingOtp = false);
      }
    }
  }

  void _startResendCountdown() {
    _resendCountdown = 60; // 60 seconds countdown
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _resendCountdown--;
          if (_resendCountdown <= 0) {
            timer.cancel();
          }
        });
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _verifyOtp() async {
    final otp = _otpValue;
    if (otp.length != 6) {
      setState(() {
        _errorMessage = 'Please enter the complete 6-digit code';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorMessage = null;
    });

    try {
      final result = await AuthService.verifyEmailVerificationOtp(otp);

      if (result['success'] == true) {
        // Email verified! Reload user to trigger navigation
        await AuthService.currentUser?.reload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Email verified successfully!'),
              backgroundColor: Colors.green.shade700,
            ),
          );
          // The app.dart StreamBuilder will handle navigation
          setState(() {});
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? 'Verification failed';
        });
        // Clear OTP field on error
        _otpController.clear();
        _focusNode.requestFocus();
      }
    } catch (e) {
      AppLogger.error('Error verifying email OTP: $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Verification failed. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _signOut() async {
    try {
      await AuthService.signOut();
    } catch (e) {
      AppLogger.error('Error signing out: $e');
    }
  }

  void _onOtpChanged(String value) {
    // Auto-verify when all 6 digits are entered
    if (value.length == 6) {
      _verifyOtp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final user = AuthService.currentUser;
    final email = _maskedEmail ?? user?.email ?? 'your email';

    return AuthScaffold(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Title
            Text(
              'Verify Your Email',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // Description
            Text(
              _otpSent
                  ? 'Enter the 6-digit code sent to:'
                  : 'Sending verification code to:',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),

            // Email address
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                email,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Loading state while sending OTP
            if (_isSendingOtp && !_otpSent) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Sending verification code...',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            // OTP Input
            if (_otpSent) ...[
              OtpInputField(
                controller: _otpController,
                focusNode: _focusNode,
                enabled: !_isVerifying,
                autofocus: true,
                onChanged: _onOtpChanged,
                onSubmitted: _otpValue.length == 6 ? _verifyOtp : null,
              ),
              const SizedBox(height: 24),

              // Verify button
              if (_isVerifying)
                const CircularProgressIndicator()
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _otpValue.length == 6 ? _verifyOtp : null,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Verify'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
            ],

            // Error message
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Resend code button
            if (_otpSent)
              TextButton.icon(
                onPressed: _resendCountdown > 0 || _isSendingOtp
                    ? null
                    : _sendOtp,
                icon: _isSendingOtp
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(
                  _resendCountdown > 0
                      ? 'Resend code in ${_resendCountdown}s'
                      : 'Resend code',
                ),
              ),

            const SizedBox(height: 16),

            // Sign out option
            TextButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Use a different account'),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
