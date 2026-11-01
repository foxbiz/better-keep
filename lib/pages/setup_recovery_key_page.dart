import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

/// Page for setting up or updating a recovery passphrase.
class SetupRecoveryKeyPage extends StatefulWidget {
  final bool isUpdate;
  final bool legacyRecovery;

  const SetupRecoveryKeyPage({
    super.key,
    this.isUpdate = false,
    this.legacyRecovery = false,
  });

  @override
  State<SetupRecoveryKeyPage> createState() => _SetupRecoveryKeyPageState();
}

class _SetupRecoveryKeyPageState extends State<SetupRecoveryKeyPage> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  final _confirmFocusNode = FocusNode();
  final _hintFocusNode = FocusNode();
  bool _isLoading = false;
  bool _checkingRecovery = false;
  bool _verifyExisting = false;
  String? _error;
  final _currentController = TextEditingController();
  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;
  String? _strengthWarning;

  @override
  void initState() {
    super.initState();
    _passphraseController.addListener(_checkPasswordStrength);
    if (widget.legacyRecovery) _prepareRecovery();
  }

  Future<void> _prepareRecovery() async {
    setState(() {
      _checkingRecovery = true;
      _error = null;
    });
    try {
      final existing = await E2EEService.instance.recoveryKeyService
          .hasRecoveryKey();
      if (mounted) setState(() => _verifyExisting = existing);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.somethingWentWrongTryAgain);
      }
    } finally {
      if (mounted) setState(() => _checkingRecovery = false);
    }
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
    _currentController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    _confirmFocusNode.dispose();
    _hintFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final recovery = E2EEService.instance.recoveryKeyService;
      if (_verifyExisting) {
        await recovery.verifyLegacyRecovery(_passphraseController.text);
      } else if (widget.isUpdate) {
        await recovery.updateRecoveryKey(
          _currentController.text,
          _passphraseController.text,
          hint: _hintController.text.isEmpty ? null : _hintController.text,
        );
      } else {
        await recovery.createRecoveryKey(
          _passphraseController.text,
          hint: _hintController.text.isEmpty ? null : _hintController.text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to save recovery key', error, stackTrace);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error =
              error is RecoveryKeyException &&
                  error.kind == RecoveryKeyFailureKind.incorrectPassphrase
              ? context.l10n.incorrectPassphrase
              : error is UnsupportedError
              ? context.l10n.recoveryKeyMobileOnly
              : context.l10n.somethingWentWrongTryAgain;
        });
        if (widget.legacyRecovery &&
            error is RecoveryKeyException &&
            error.kind == RecoveryKeyFailureKind.alreadyExists) {
          await _prepareRecovery();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingRecovery) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _verifyExisting
              ? context.l10n.verifyRecoveryKey
              : widget.isUpdate
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
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    if (widget.legacyRecovery && !_verifyExisting)
                      TextButton(
                        onPressed: _prepareRecovery,
                        child: Text(context.l10n.retry),
                      ),
                  ],
                  if (!_verifyExisting) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.recoveryPassphraseDescription,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Theme.of(context).colorScheme.error,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              context.l10n.recoveryPassphraseWarning,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (widget.isUpdate) ...[
                    TextFormField(
                      controller: _currentController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: context.l10n.currentPassphrase,
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? context.l10n.currentPassphrase
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passphraseController,
                    obscureText: _obscurePassphrase,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: (_) => _confirmFocusNode.requestFocus(),
                    decoration: InputDecoration(
                      labelText: context.l10n.recoveryPassphrase,
                      hintText: _verifyExisting
                          ? null
                          : context.l10n.enterAStrongPassphrase,
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
                      if (!_verifyExisting && value.length < 6) {
                        return context.l10n.passphraseMinLength;
                      }
                      return null;
                    },
                  ),
                  // Real-time strength warning
                  if (!_verifyExisting && _strengthWarning != null)
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
                                    color: Theme.of(context)
                                        .colorScheme
                                        .tertiary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!_verifyExisting) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirmController,
                      obscureText: _obscureConfirm,
                      focusNode: _confirmFocusNode,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _hintFocusNode.requestFocus(),
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
                          onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm,
                          ),
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
                      focusNode: _hintFocusNode,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: context.l10n.hintOptional,
                        hintText: context.l10n.hintToRemember,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lightbulb_outline),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed:
                        _isLoading ||
                            (widget.legacyRecovery &&
                                _error != null &&
                                !_verifyExisting)
                        ? null
                        : _save,
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
                          : _verifyExisting
                          ? context.l10n.verify
                          : context.l10n.saveRecoveryKey,
                    ),
                  ),
                  if (widget.legacyRecovery)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.notNow),
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
  bool legacyRecovery = false,
}) async {
  final result = await showPage(
    context,
    SetupRecoveryKeyPage(isUpdate: isUpdate, legacyRecovery: legacyRecovery),
  );
  return result as bool?;
}
