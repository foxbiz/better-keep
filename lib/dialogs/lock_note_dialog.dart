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

    return AlertDialog(
      title: const Text('Lock Note'),
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
                        'If you forget this PIN, there is no way to recover the note.',
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
                  labelText: 'PIN',
                  hintText: 'Enter PIN',
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
                    return 'Please enter a PIN';
                  }
                  if (value.length < 4) {
                    return 'PIN must be at least 4 characters';
                  }
                  // Warn about weak PINs (all same digit or sequential)
                  if (RegExp(r'^(.)\1+$').hasMatch(value)) {
                    return 'PIN is too weak (all same characters)';
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
                    return 'PIN is too common';
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
                  labelText: 'Confirm PIN',
                  hintText: 'Re-enter PIN',
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
                    return 'PINs do not match';
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
          child: const Text('Cancel'),
        ),
        ElevatedButton(onPressed: _save, child: const Text('Lock')),
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
