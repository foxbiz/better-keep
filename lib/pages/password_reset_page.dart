import 'dart:async';

import 'package:better_keep/components/otp_input_field.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Page for resetting password via OTP verification.
/// Three-step flow: email → OTP → new password → login
class PasswordResetPage extends StatefulWidget {
  /// Optional email to pre-fill the email field
  final String? initialEmail;

  const PasswordResetPage({super.key, this.initialEmail});

  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

enum _ResetStep { email, otp, newPassword }

class _PasswordResetPageState extends State<PasswordResetPage> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _otpFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  _ResetStep _currentStep = _ResetStep.email;
  bool _isLoading = false;
  bool _isResending = false;
  String? _maskedEmail;
  String? _errorMessage;
  Timer? _resendTimer;
  int _resendCountdown = 0;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null) {
      _emailController.text = widget.initialEmail!;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _otpFocusNode.dispose();
    _passwordFocusNode.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  String get _email => _emailController.text.trim();
  String get _otp => _otpController.text;
  String get _password => _passwordController.text;
  String get _confirmPassword => _confirmPasswordController.text;

  /// Validate email format
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    return emailRegex.hasMatch(email);
  }

  /// Check password strength and return warning message if weak
  String? _getPasswordWarning() {
    if (_password.isEmpty) return null;
    if (_password.length < 6) {
      return context.l10n.passwordShortWarning;
    }
    if (_password.length < 8) {
      return context.l10n.passwordLongerAdvice;
    }
    final hasLetter = RegExp(r'[a-zA-Z]').hasMatch(_password);
    final hasNumber = RegExp(r'[0-9]').hasMatch(_password);
    if (!hasLetter || !hasNumber) {
      return context.l10n.passwordMixAdvice;
    }
    return null;
  }

  /// Step 1: Send OTP to email
  Future<void> _sendOtp() async {
    if (_email.isEmpty) {
      setState(() {
        _errorMessage = context.l10n.pleaseEnterEmailAddress;
      });
      return;
    }

    if (!_isValidEmail(_email)) {
      setState(() {
        _errorMessage = context.l10n.pleaseEnterValidEmail;
      });
      return;
    }

    final isResend = _currentStep == _ResetStep.otp;

    setState(() {
      _isLoading = true;
      _isResending = isResend;
      _errorMessage = null;
    });

    try {
      final result = await AuthService.sendPasswordResetOtp(_email);

      if (mounted) {
        setState(() {
          _maskedEmail = result['maskedEmail'] as String?;
          _currentStep = _ResetStep.otp;
          _startResendCountdown();
        });
        // Focus the OTP field
        Future.delayed(const Duration(milliseconds: 100), () {
          _otpFocusNode.requestFocus();
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? 'Failed to send verification code';
        });
      }
    } catch (e) {
      AppLogger.error('Error sending password reset OTP: $e');
      if (mounted) {
        setState(() {
          _errorMessage = context.l10n.failedSendVerificationCode;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isResending = false;
        });
      }
    }
  }

  /// Start the 60-second resend countdown
  void _startResendCountdown() {
    _resendCountdown = 60;
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

  /// Step 2: Verify OTP before proceeding to password step
  Future<void> _verifyOtpAndProceed() async {
    if (_otp.length != 6) {
      setState(() {
        _errorMessage = context.l10n.pleaseEnterCompleteCode;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await AuthService.verifyPasswordResetOtp(email: _email, otp: _otp);

      if (mounted) {
        setState(() {
          _currentStep = _ResetStep.newPassword;
        });
        Future.delayed(const Duration(milliseconds: 100), () {
          _passwordFocusNode.requestFocus();
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? 'Invalid verification code';
        });
        _otpController.clear();
        _otpFocusNode.requestFocus();
      }
    } catch (e) {
      AppLogger.error('Error verifying OTP: $e');
      if (mounted) {
        setState(() {
          _errorMessage = context.l10n.verificationFailed;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Step 3: Reset password with OTP verification
  Future<void> _resetPassword() async {
    // Validate password match
    if (_password != _confirmPassword) {
      setState(() {
        _errorMessage = context.l10n.passwordsDoNotMatch;
      });
      return;
    }

    if (_password.isEmpty) {
      setState(() {
        _errorMessage = context.l10n.pleaseEnterNewPassword;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await AuthService.resetPasswordWithOtp(
        email: _email,
        otp: _otp,
        newPassword: _password,
      );

      if (result['success'] == true && mounted) {
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.passwordResetSuccess),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 4),
          ),
        );

        // Navigate back to login
        Navigator.of(context).pop();
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        final errorMessage = e.message ?? 'Password reset failed';

        // If OTP is invalid or expired, go back to OTP step
        if (errorMessage.contains('expired') ||
            errorMessage.contains('Invalid verification') ||
            errorMessage.contains('not found')) {
          setState(() {
            _isLoading = false;
            _errorMessage = errorMessage;
            _currentStep = _ResetStep.otp;
            _otpController.clear();
          });
          _otpFocusNode.requestFocus();
        } else {
          setState(() {
            _errorMessage = errorMessage;
          });
        }
      }
    } catch (e) {
      AppLogger.error('Error resetting password: $e');
      if (mounted) {
        setState(() {
          _errorMessage = context.l10n.passwordResetFailed;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Handle OTP input changes - auto-verify when 6 digits entered
  void _onOtpChanged(String value) {
    if (value.length == 6) {
      _verifyOtpAndProceed();
    }
  }

  /// Go back to previous step
  void _goBack() {
    setState(() {
      _errorMessage = null;
      switch (_currentStep) {
        case _ResetStep.email:
          Navigator.of(context).pop();
          break;
        case _ResetStep.otp:
          _currentStep = _ResetStep.email;
          break;
        case _ResetStep.newPassword:
          _currentStep = _ResetStep.otp;
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    colorScheme.surface,
                    colorScheme.surface,
                    Colors.deepPurple.shade900.withValues(alpha: 0.3),
                  ]
                : [
                    colorScheme.surface,
                    colorScheme.primaryContainer.withValues(alpha: 0.3),
                    colorScheme.secondaryContainer.withValues(alpha: 0.5),
                  ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: IconButton(
                    onPressed: _goBack,
                    icon: const Icon(Icons.arrow_back),
                    tooltip: context.l10n.back,
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: _buildCurrentStep(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case _ResetStep.email:
        return _buildEmailStep();
      case _ResetStep.otp:
        return _buildOtpStep();
      case _ResetStep.newPassword:
        return _buildPasswordStep();
    }
  }

  /// Step 1: Email input
  Widget _buildEmailStep() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 48),

        // Icon
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.lock_reset, size: 48, color: colorScheme.error),
        ),
        const SizedBox(height: 24),

        // Title
        Text(
          context.l10n.resetPassword,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),

        // Description
        Text(
          context.l10n.resetPasswordDescription,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // Email input
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          enabled: !_isLoading,
          autofocus: true,
          onSubmitted: (_) => _sendOtp(),
          decoration: InputDecoration(
            labelText: context.l10n.email,
            hintText: context.l10n.enterEmailAddress,
            prefixIcon: const Icon(Icons.email_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),

        // Error message
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(),
        ],

        const SizedBox(height: 24),

        // Send OTP button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isLoading ? null : _sendOtp,
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
            label: Text(
              _isLoading
                  ? context.l10n.sending
                  : context.l10n.sendVerificationCode,
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  /// Step 2: OTP input
  Widget _buildOtpStep() {
    final colorScheme = Theme.of(context).colorScheme;
    final displayEmail = _maskedEmail ?? _email;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 48),

        // Icon
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.pin, size: 48, color: colorScheme.error),
        ),
        const SizedBox(height: 24),

        // Title
        Text(
          context.l10n.enterVerificationCode,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),

        // Description
        Text(
          context.l10n.enterCodeSentTo,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 8),

        // Email display
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            displayEmail,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.error,
            ),
          ),
        ),
        const SizedBox(height: 32),

        // OTP input
        OtpInputField(
          controller: _otpController,
          focusNode: _otpFocusNode,
          enabled: !_isLoading,
          autofocus: true,
          accentColor: colorScheme.error,
          onChanged: _onOtpChanged,
          onSubmitted: _otp.length == 6 && !_isLoading
              ? _verifyOtpAndProceed
              : null,
        ),

        // Error message
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(),
        ],

        const SizedBox(height: 24),

        // Continue button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _otp.length == 6 && !_isLoading
                ? _verifyOtpAndProceed
                : null,
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.arrow_forward),
            label: Text(
              _isLoading ? context.l10n.verifying : context.l10n.continue_,
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: colorScheme.error,
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Resend code button
        TextButton.icon(
          onPressed: _resendCountdown > 0 || _isResending || _isLoading
              ? null
              : _sendOtp,
          icon: _isResending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: Text(
            _resendCountdown > 0
                ? context.l10n.resendCodeIn(_resendCountdown)
                : context.l10n.resendCode,
          ),
        ),

        const SizedBox(height: 8),

        // Expires in note
        Text(
          context.l10n.codeExpiresIn,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Step 3: New password input
  Widget _buildPasswordStep() {
    final colorScheme = Theme.of(context).colorScheme;
    final passwordWarning = _getPasswordWarning();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 48),

        // Icon
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.password, size: 48, color: colorScheme.error),
        ),
        const SizedBox(height: 24),

        // Title
        Text(
          context.l10n.createNewPassword,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),

        // Description
        Text(
          context.l10n.enterNewPasswordDescription,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // New password input
        TextField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          obscureText: _obscurePassword,
          enabled: !_isLoading,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: context.l10n.newPassword,
            hintText: context.l10n.enterNewPasswordHint,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),

        // Password strength warning (advisory)
        if (passwordWarning != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    passwordWarning,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Confirm password input
        TextField(
          controller: _confirmPasswordController,
          obscureText: _obscureConfirmPassword,
          enabled: !_isLoading,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetPassword(),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: context.l10n.confirmPassword,
            hintText: context.l10n.reenterNewPasswordHint,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () => setState(
                () => _obscureConfirmPassword = !_obscureConfirmPassword,
              ),
              icon: Icon(
                _obscureConfirmPassword
                    ? Icons.visibility
                    : Icons.visibility_off,
              ),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            errorText:
                _confirmPassword.isNotEmpty && _password != _confirmPassword
                ? context.l10n.passwordsDoNotMatch
                : null,
          ),
        ),

        // Error message
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorMessage(),
        ],

        const SizedBox(height: 24),

        // Reset password button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                _isLoading || _password.isEmpty || _password != _confirmPassword
                ? null
                : _resetPassword,
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            label: Text(
              _isLoading
                  ? context.l10n.resettingPassword
                  : context.l10n.resetPassword,
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  /// Build error message widget
  Widget _buildErrorMessage() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
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
    );
  }
}
