import 'package:better_keep/components/otp_input_field.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Configuration for the OTP dialog
class OtpDialogConfig {
  /// Title displayed in the dialog
  final String title;

  /// Icon to display in the dialog header
  final IconData icon;

  /// Color theme for the icon and accents
  final Color? accentColor;

  /// Email address to display (masked)
  final String maskedEmail;

  /// Optional Cloud Function name to call for verification
  /// If null, the dialog will just return the OTP string
  final String? verifyFunctionName;

  /// Additional parameters to pass to the verify function
  final Map<String, dynamic>? verifyFunctionParams;

  /// How long before the code expires (shown to user)
  final int expiresInMinutes;

  /// Label for the verify/continue button
  final String verifyButtonLabel;

  /// Whether this is a destructive action (red theme)
  final bool isDestructive;

  const OtpDialogConfig({
    required this.title,
    required this.maskedEmail,
    this.icon = Icons.mail_lock,
    this.accentColor,
    this.verifyFunctionName,
    this.verifyFunctionParams,
    this.expiresInMinutes = 10,
    this.verifyButtonLabel = 'Verify',
    this.isDestructive = false,
  });
}

/// Result from the OTP dialog
class OtpDialogResult {
  final bool success;
  final String? otp;
  final Map<String, dynamic>? data;
  final String? error;

  const OtpDialogResult({
    required this.success,
    this.otp,
    this.data,
    this.error,
  });

  factory OtpDialogResult.cancelled() => const OtpDialogResult(success: false);

  factory OtpDialogResult.verified({
    required String otp,
    Map<String, dynamic>? data,
  }) => OtpDialogResult(success: true, otp: otp, data: data);

  factory OtpDialogResult.error(String message) =>
      OtpDialogResult(success: false, error: message);
}

/// Shows a consistent OTP verification dialog across the app
///
/// If [config.verifyFunctionName] is provided, the dialog will call the
/// Cloud Function to verify the OTP and return the result data.
///
/// If [config.verifyFunctionName] is null, the dialog will simply return
/// the entered OTP string for the caller to handle verification.
Future<OtpDialogResult?> showOtpDialog(
  BuildContext context,
  OtpDialogConfig config,
) {
  return showDialog<OtpDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _OtpDialog(config: config),
  );
}

class _OtpDialog extends StatefulWidget {
  final OtpDialogConfig config;

  const _OtpDialog({required this.config});

  @override
  State<_OtpDialog> createState() => _OtpDialogState();
}

class _OtpDialogState extends State<_OtpDialog> {
  final _otpController = TextEditingController();
  final _focusNode = FocusNode();
  String? _errorText;
  bool _isVerifying = false;

  OtpDialogConfig get config => widget.config;

  Color get _accentColor {
    if (config.accentColor != null) return config.accentColor!;
    if (config.isDestructive) return Colors.red;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  void initState() {
    super.initState();
    // Auto-focus the text field after dialog opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _otpController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.isEmpty || otp.length != 6) {
      setState(() => _errorText = 'Please enter a 6-digit code');
      return;
    }

    // If no verify function, just return the OTP
    if (config.verifyFunctionName == null) {
      Navigator.of(context).pop(OtpDialogResult.verified(otp: otp));
      return;
    }

    setState(() {
      _isVerifying = true;
      _errorText = null;
    });

    try {
      final functions = FirebaseFunctions.instance;
      final params = <String, dynamic>{'otp': otp};
      if (config.verifyFunctionParams != null) {
        params.addAll(config.verifyFunctionParams!);
      }

      final result = await functions
          .httpsCallable(config.verifyFunctionName!)
          .call(params);

      if (result.data['success'] == true) {
        if (mounted) {
          Navigator.of(context).pop(
            OtpDialogResult.verified(
              otp: otp,
              data: Map<String, dynamic>.from(result.data),
            ),
          );
        }
      } else {
        setState(() {
          _isVerifying = false;
          _errorText = result.data['message'] ?? 'Verification failed';
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _isVerifying = false;
        _errorText = e.message ?? 'Verification failed';
      });
    } catch (e) {
      setState(() {
        _isVerifying = false;
        _errorText = 'Verification failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _accentColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(config.icon, color: _accentColor, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(config.title, style: theme.textTheme.titleLarge),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'We sent a verification code to:',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            config.maskedEmail,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          // OTP input field with consistent styling
          OtpInputField(
            controller: _otpController,
            focusNode: _focusNode,
            enabled: !_isVerifying,
            accentColor: _accentColor,
            errorText: _errorText,
            onSubmitted: _verifyOtp,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.timer_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'Code expires in ${config.expiresInMinutes} minutes',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isVerifying
              ? null
              : () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isVerifying ? null : _verifyOtp,
          style: config.isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                )
              : null,
          child: _isVerifying
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: config.isDestructive
                        ? Colors.white
                        : theme.colorScheme.onPrimary,
                  ),
                )
              : Text(config.verifyButtonLabel),
        ),
      ],
    );
  }
}
