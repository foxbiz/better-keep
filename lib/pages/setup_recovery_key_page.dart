import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
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
        warning = context.l10n.passphraseTooCommon;
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
          warning = context.l10n.passphraseStrengthAdvice;
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
          SnackBar(
            content: Text(context.l10n.failedSaveRecoveryKey(e.toString())),
          ),
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
          widget.isUpdate
              ? context.l10n.updateRecoveryKey
              : context.l10n.setupRecoveryKey,
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
                    context.l10n.recoveryPassphraseDescription,
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
                            context.l10n.recoveryPassphraseWarning,
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
                      labelText: context.l10n.recoveryPassphrase,
                      hintText: context.l10n.enterAStrongPassphrase,
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
                        return context.l10n.pleaseEnterPassphrase;
                      }
                      if (value.length < 6) {
                        return context.l10n.passphraseMinLength;
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
                      labelText: context.l10n.confirmPassphrase,
                      hintText: context.l10n.reenterPassphrase,
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
                        return context.l10n.passphrasesDoNotMatch;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _hintController,
                    decoration: InputDecoration(
                      labelText: context.l10n.hintOptional,
                      hintText: context.l10n.hintToRemember,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lightbulb_outline),
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
                    label: Text(
                      _isLoading
                          ? context.l10n.saving
                          : context.l10n.saveRecoveryKey,
                    ),
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
