import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// Dialog for setting a PIN to lock a note.
/// Shows a warning about the unrecoverable nature of the PIN.
class LockNoteDialog extends StatefulWidget {
  const LockNoteDialog({super.key});

  @override
  State<LockNoteDialog> createState() => _LockNoteDialogState();
}

class _LockNoteDialogState extends State<LockNoteDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscurePin = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_pinController.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.lockNote),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.pinForgotWarning,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _pinController,
                obscureText: _obscurePin,
                autofocus: true,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: l10n.pin,
                  hintText: l10n.enterPin,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePin ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscurePin = !_obscurePin),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return l10n.pleaseEnterAPin;
                  }
                  if (value.length < 4) {
                    return l10n.pinMinLength;
                  }
                  // Warn about weak PINs (all same digit or sequential)
                  if (RegExp(r'^(.)\1+$').hasMatch(value)) {
                    return l10n.pinTooWeak;
                  }
                  if ([
                    '1234',
                    '0000',
                    '1111',
                    '2222',
                    '3333',
                    '4444',
                    '5555',
                    '6666',
                    '7777',
                    '8888',
                    '9999',
                    '4321',
                  ].contains(value)) {
                    return l10n.pinTooCommon;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: _obscureConfirm,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: l10n.confirmPin,
                  hintText: l10n.reenterPin,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                validator: (value) {
                  if (value != _pinController.text) {
                    return l10n.pinsDoNotMatch;
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(onPressed: _save, child: Text(l10n.lock)),
      ],
    );
  }
}

/// Shows a dialog to set a PIN for locking a note.
/// Returns the PIN if confirmed, or null if cancelled.
Future<String?> showLockNoteDialog(BuildContext context) {
  return showDialog<String?>(
    context: context,
    builder: (context) => const LockNoteDialog(),
  );
}
