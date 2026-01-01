import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A reusable OTP input field component with consistent styling across the app.
///
/// Uses a single TextField with letter spacing to create the OTP appearance,
/// which is more reliable than separate boxes and avoids overflow issues.
class OtpInputField extends StatelessWidget {
  /// Controller for the text field
  final TextEditingController controller;

  /// Focus node for the text field
  final FocusNode? focusNode;

  /// Whether the field is enabled
  final bool enabled;

  /// Accent color for the focused border
  final Color? accentColor;

  /// Error text to display below the field
  final String? errorText;

  /// Callback when the value changes
  final ValueChanged<String>? onChanged;

  /// Callback when the user submits (presses enter/done)
  final VoidCallback? onSubmitted;

  /// Whether to auto-focus this field
  final bool autofocus;

  const OtpInputField({
    super.key,
    required this.controller,
    this.focusNode,
    this.enabled = true,
    this.accentColor,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveAccentColor = accentColor ?? theme.colorScheme.primary;

    return TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      maxLength: 6,
      enabled: enabled,
      autofocus: autofocus,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(
        fontSize: 28,
        letterSpacing: 12,
        fontWeight: FontWeight.bold,
      ),
      decoration: InputDecoration(
        counterText: '',
        hintText: '••••••',
        hintStyle: TextStyle(
          fontSize: 28,
          letterSpacing: 12,
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
        ),
        errorText: errorText,
        errorMaxLines: 2,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.5,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: effectiveAccentColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.error, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 16,
        ),
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted != null ? (_) => onSubmitted!() : null,
    );
  }
}
