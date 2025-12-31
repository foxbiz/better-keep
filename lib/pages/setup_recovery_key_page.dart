import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/ui/show_page.dart';
import 'package:flutter/material.dart';

/// Page for setting up or updating a recovery passphrase.
class SetupRecoveryKeyPage extends StatefulWidget {
  final bool isUpdate;

  const SetupRecoveryKeyPage({super.key, this.isUpdate = false});

  @override
  State<SetupRecoveryKeyPage> createState() => _SetupRecoveryKeyPageState();
}

class _SetupRecoveryKeyPageState extends State<SetupRecoveryKeyPage> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;
  String? _strengthWarning;

  @override
  void initState() {
    super.initState();
    _passphraseController.addListener(_checkPasswordStrength);
  }

  void _checkPasswordStrength() {
    final value = _passphraseController.text;
    String? warning;

    if (value.isNotEmpty && value.length >= 6) {
      // Check for common weak passphrases
      if (value.toLowerCase().contains('password') ||
          value.toLowerCase().contains('123456') ||
          value.toLowerCase().contains('qwerty')) {
        warning = 'This passphrase is too common and easy to guess';
      } else {
        // Check for mix of character types
        final hasUppercase = value.contains(RegExp(r'[A-Z]'));
        final hasLowercase = value.contains(RegExp(r'[a-z]'));
        final hasDigit = value.contains(RegExp(r'[0-9]'));
        final hasSpecial = value.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
        final typesCount = [
          hasUppercase,
          hasLowercase,
          hasDigit,
          hasSpecial,
        ].where((x) => x).length;

        if (typesCount < 2) {
          warning =
              'Consider adding uppercase, lowercase, numbers, or symbols for a stronger passphrase';
        }
      }
    }

    if (_strengthWarning != warning) {
      setState(() => _strengthWarning = warning);
    }
  }

  @override
  void dispose() {
    _passphraseController.removeListener(_checkPasswordStrength);
    _passphraseController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await E2EEService.instance.recoveryKeyService.createRecoveryKey(
        _passphraseController.text,
        hint: _hintController.text.isNotEmpty ? _hintController.text : null,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save recovery key: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isUpdate ? 'Update Recovery Key' : 'Set Up Recovery Key',
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Icon(
                    Icons.vpn_key_rounded,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Create a recovery passphrase that can restore access to your '
                    'notes if you lose all your devices.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.errorContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.error,
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Store this passphrase securely. Without it, you cannot '
                            'recover your notes if you lose all devices.',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _passphraseController,
                    obscureText: _obscurePassphrase,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Recovery Passphrase',
                      hintText: 'Enter a strong passphrase',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassphrase
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassphrase = !_obscurePassphrase,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a passphrase';
                      }
                      if (value.length < 6) {
                        return 'Passphrase must be at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  // Real-time strength warning
                  if (_strengthWarning != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _strengthWarning!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.tertiary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmController,
                    obscureText: _obscureConfirm,
                    decoration: InputDecoration(
                      labelText: 'Confirm Passphrase',
                      hintText: 'Re-enter your passphrase',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureConfirm
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () =>
                            setState(() => _obscureConfirm = !_obscureConfirm),
                      ),
                    ),
                    validator: (value) {
                      if (value != _passphraseController.text) {
                        return 'Passphrases do not match';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _hintController,
                    decoration: const InputDecoration(
                      labelText: 'Hint (Optional)',
                      hintText: 'A hint to help you remember',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lightbulb_outline),
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _save,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isLoading ? 'Saving...' : 'Save Recovery Key'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the setup recovery key page.
/// Returns true if recovery key was set up, false if skipped, null if dismissed.
Future<bool?> showSetupRecoveryKeyPage(
  BuildContext context, {
  bool isUpdate = false,
}) async {
  final result = await showPage(
    context,
    SetupRecoveryKeyPage(isUpdate: isUpdate),
  );
  return result as bool?;
}
