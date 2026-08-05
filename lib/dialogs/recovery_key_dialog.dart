import 'dart:async';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:better_keep/services/e2ee/secure_storage.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:flutter/material.dart';

/// Dialog for setting up or updating a recovery passphrase.
class SetupRecoveryKeyDialog extends StatefulWidget {
  final bool isUpdate;

  const SetupRecoveryKeyDialog({super.key, this.isUpdate = false});

  @override
  State<SetupRecoveryKeyDialog> createState() => _SetupRecoveryKeyDialogState();
}

class _SetupRecoveryKeyDialogState extends State<SetupRecoveryKeyDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
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
    } catch (e, stack) {
      AppLogger.error('Create recovery key failed', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.somethingWentWrongTryAgain)),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isUpdate
            ? context.l10n.updateRecoveryKey
            : context.l10n.setupRecoveryKey,
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.recoveryPassphraseDescription,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.recoveryPassphraseWarning,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _passphraseController,
                obscureText: _obscurePassphrase,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.recoveryPassphrase,
                  hintText: context.l10n.enterAStrongPassphrase,
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  labelText: context.l10n.confirmPassphrase,
                  hintText: context.l10n.reenterPassphrase,
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
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (!widget.isUpdate)
          TextButton(
            onPressed: _isLoading
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(context.l10n.skip),
          )
        else
          TextButton(
            onPressed: _isLoading
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
        ElevatedButton(
          onPressed: _isLoading ? null : _save,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.save),
        ),
      ],
    );
  }
}

/// Dialog for recovering with a passphrase.
class RecoverWithPassphraseDialog extends StatefulWidget {
  const RecoverWithPassphraseDialog({super.key});

  @override
  State<RecoverWithPassphraseDialog> createState() =>
      _RecoverWithPassphraseDialogState();
}

class _RecoverWithPassphraseDialogState
    extends State<RecoverWithPassphraseDialog> {
  final _passphraseController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassphrase = true;
  bool _setAsPrimaryDevice = false;
  String? _hint;
  String? _error;
  RecoveryProgress? _statusProgress;

  @override
  void initState() {
    super.initState();
    _loadHint();
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _loadHint() async {
    final hint = await RecoveryKeyService.instance.getRecoveryKeyHint();
    if (mounted) {
      setState(() => _hint = hint);
    }
  }

  void _updateStatus(RecoveryProgress progress) {
    if (mounted) {
      setState(() => _statusProgress = progress);
    }
  }

  Future<void> _recover() async {
    if (_passphraseController.text.isEmpty) {
      setState(() => _error = context.l10n.pleaseEnterRecoveryPassphrase);
      return;
    }

    final l10n = context.l10n;
    setState(() {
      _isLoading = true;
      _error = null;
      _statusProgress = RecoveryProgress.verifying;
    });

    try {
      // Add a timeout to prevent indefinite waiting
      final success = await RecoveryKeyService.instance
          .recoverWithPassphrase(
            _passphraseController.text,
            onStatusChange: _updateStatus,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              throw TimeoutException(
                'Recovery timed out. Please check your connection and try again.',
              );
            },
          );

      if (success) {
        // If user wants to set this device as primary, revoke other devices
        if (_setAsPrimaryDevice) {
          _updateStatus(RecoveryProgress.almostThere);
          try {
            await DeviceManager.instance.setCurrentDeviceAsPrimary();
          } catch (e, stack) {
            AppLogger.error(
              'Recovery dialog: Failed to set device as primary',
              e,
              stack,
            );
            // Don't fail the recovery, just log the error
          }
        }

        _updateStatus(RecoveryProgress.almostThere);
        // Cache the device status as approved
        await E2EESecureStorage.instance.cacheDeviceStatus('approved');

        // Update E2EE status to ready and start listening for changes
        E2EEService.instance.status.value = E2EEStatus.ready;
        E2EEService.instance.listenForStatusChanges();

        if (mounted) {
          Navigator.of(context).pop(true);
        }
      } else {
        if (mounted) {
          setState(() => _error = l10n.incorrectPassphrase);
        }
      }
    } on TimeoutException catch (e) {
      AppLogger.error('Recovery dialog: Recovery timed out', e);
      if (mounted) {
        setState(() => _error = l10n.recoveryTimedOut);
      }
    } on UnsupportedError catch (e) {
      // Argon2id recovery attempted on web
      AppLogger.error('Recovery dialog: Unsupported on this platform', e);
      if (mounted) {
        setState(() => _error = context.l10n.recoveryKeyMobileOnly);
      }
    } catch (e, stack) {
      AppLogger.error('Recovery dialog: Recovery failed', e, stack);
      if (mounted) {
        setState(() => _error = context.l10n.somethingWentWrongCheckConnection);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Text(context.l10n.recover),
          const SizedBox(width: 6),
          MenuAnchor(
            builder: (context, controller, child) {
              return IconButton(
                icon: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              );
            },
            menuChildren: [
              Container(
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(maxWidth: 250),
                child: Text(
                  context.l10n.recoverInfoTooltip,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                Container(
                  constraints: const BoxConstraints(maxHeight: 100),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: colorScheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              // Show status message during recovery
              if (_isLoading && _statusProgress != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _statusProgress!.localized(context.l10n),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        color: colorScheme.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.hintLabel(_hint!),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _passphraseController,
                obscureText: _obscurePassphrase,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.recoveryPassphrase,
                  hintText: context.l10n.enterYourPassphrase,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassphrase
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                    onPressed: () => setState(
                      () => _obscurePassphrase = !_obscurePassphrase,
                    ),
                  ),
                ),
                onSubmitted: (_) => _recover(),
              ),
              const SizedBox(height: 12),
              // Toggle to set this device as primary
              InkWell(
                onTap: () =>
                    setState(() => _setAsPrimaryDevice = !_setAsPrimaryDevice),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        height: 24,
                        width: 40,
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: Switch(
                            value: _setAsPrimaryDevice,
                            onChanged: (value) =>
                                setState(() => _setAsPrimaryDevice = value),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.setAsPrimaryDevice,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: _setAsPrimaryDevice
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _recover,
          child: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(context.l10n.recover),
        ),
      ],
    );
  }
}

/// Shows the setup recovery key dialog.
/// Returns true if recovery key was set up, false if skipped, null if dismissed.
Future<bool?> showSetupRecoveryKeyDialog(
  BuildContext context, {
  bool isUpdate = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => SetupRecoveryKeyDialog(isUpdate: isUpdate),
  );
}

/// Shows the recover with passphrase dialog.
/// Returns true if recovery was successful.
Future<bool?> showRecoverWithPassphraseDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => const RecoverWithPassphraseDialog(),
  );
}

/// Dialog for updating recovery key (requires current passphrase).
class UpdateRecoveryKeyDialog extends StatefulWidget {
  const UpdateRecoveryKeyDialog({super.key});

  @override
  State<UpdateRecoveryKeyDialog> createState() =>
      _UpdateRecoveryKeyDialogState();
}

class _UpdateRecoveryKeyDialogState extends State<UpdateRecoveryKeyDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentPassphraseController = TextEditingController();
  final _newPassphraseController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  bool _isLoading = false;
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _currentPassphraseController.dispose();
    _newPassphraseController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await E2EEService.instance.recoveryKeyService.updateRecoveryKey(
        _currentPassphraseController.text,
        _newPassphraseController.text,
        hint: _hintController.text.isNotEmpty ? _hintController.text : null,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, stack) {
      AppLogger.error('Update recovery key failed', e, stack);
      if (mounted) {
        setState(() {
          if (e is RecoveryKeyException &&
              e.kind == RecoveryKeyFailureKind.incorrectPassphrase) {
            _error = context.l10n.currentPassphraseIncorrect;
          } else {
            _error = context.l10n.somethingWentWrongTryAgain;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.updateRecoveryKey),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _currentPassphraseController,
                obscureText: _obscureCurrent,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.currentPassphrase,
                  hintText: context.l10n.enterCurrentPassphrase,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureCurrent ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return context.l10n.pleaseEnterCurrentPassphrase;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newPassphraseController,
                obscureText: _obscureNew,
                decoration: InputDecoration(
                  labelText: context.l10n.newPassphrase,
                  hintText: context.l10n.enterStrongPassphrase,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureNew ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return context.l10n.pleaseEnterNewPassphrase;
                  }
                  if (value.length < 6) {
                    return context.l10n.passphraseMinLength;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  labelText: context.l10n.confirmNewPassphrase,
                  hintText: context.l10n.reenterNewPassphrase,
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
                  if (value != _newPassphraseController.text) {
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
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _save,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.update),
        ),
      ],
    );
  }
}

/// Shows the update recovery key dialog.
/// Returns true if recovery key was updated.
Future<bool?> showUpdateRecoveryKeyDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => const UpdateRecoveryKeyDialog(),
  );
}

/// Dialog for removing recovery key (requires current passphrase).
class RemoveRecoveryKeyDialog extends StatefulWidget {
  const RemoveRecoveryKeyDialog({super.key});

  @override
  State<RemoveRecoveryKeyDialog> createState() =>
      _RemoveRecoveryKeyDialogState();
}

class _RemoveRecoveryKeyDialogState extends State<RemoveRecoveryKeyDialog> {
  final _passphraseController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassphrase = true;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    if (_passphraseController.text.isEmpty) {
      setState(() => _error = context.l10n.pleaseEnterPassphrase);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await E2EEService.instance.recoveryKeyService.removeRecoveryKey(
        _passphraseController.text,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, stack) {
      AppLogger.error('Remove recovery key failed', e, stack);
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (e is RecoveryKeyException &&
              e.kind == RecoveryKeyFailureKind.incorrectPassphrase) {
            _error = context.l10n.passphraseIncorrect;
          } else {
            _error = context.l10n.somethingWentWrongTryAgain;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.removeRecoveryKey),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Theme.of(context).colorScheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.l10n.removeRecoveryKeyWarning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              context.l10n.enterPassphraseToConfirmRemoval,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Container(
                constraints: const BoxConstraints(maxHeight: 100),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _passphraseController,
              obscureText: _obscurePassphrase,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.l10n.currentPassphrase,
                hintText: context.l10n.enterYourPassphrase,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassphrase
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassphrase = !_obscurePassphrase),
                ),
              ),
              onSubmitted: (_) => _remove(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _remove,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.remove),
        ),
      ],
    );
  }
}

/// Shows the remove recovery key dialog.
/// Returns true if recovery key was removed.
Future<bool?> showRemoveRecoveryKeyDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => const RemoveRecoveryKeyDialog(),
  );
}
