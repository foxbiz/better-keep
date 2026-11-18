import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/otp_input_field.dart';
import '../../services/external_sync/library_sync_session.dart';
import '../../utils/l10n_helper.dart';

/// No deletion runs until the backend consumes a provider/account-bound OTP.
class StorageClearDialog extends StatefulWidget {
  const StorageClearDialog({
    super.key,
    required this.session,
    required this.provider,
  });
  final LibrarySyncSession session;
  final String provider;
  @override
  State<StorageClearDialog> createState() => _StorageClearDialogState();
}

class _StorageClearDialogState extends State<StorageClearDialog> {
  final _code = TextEditingController();
  String? _requestId, _error;
  bool _busy = false;
  Timer? _resendTimer;
  int _resendSeconds = 0;
  @override
  void dispose() {
    _resendTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || (_requestId != null && _resendSeconds > 0)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.session.connections.requestClearOtp(
        widget.provider,
      );
      if (!mounted) return;
      setState(() {
        _requestId = result['requestId'] as String;
        _code.clear();
        _resendSeconds = 60;
      });
      _resendTimer?.cancel();
      _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _resendSeconds--);
        if (_resendSeconds == 0) timer.cancel();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.externalSyncClearSendError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy || _requestId == null || _code.text.length != 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.connections.clearSyncedData(
        widget.provider,
        _requestId!,
        _code.text,
        () async {
          await widget.session.scheduler.waitForIdle();
          await widget.session.engine.waitForIdle();
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = context.l10n.externalSyncClearCodeError;
          if (widget.session.connections.connections[widget.provider]?.state ==
              'clearing') {
            _requestId = null;
          }
          _code.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final verifying = _requestId != null;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
        title: Text(
          verifying
              ? l10n.externalSyncClearVerifyTitle
              : l10n.externalSyncClear,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                verifying
                    ? l10n.externalSyncClearCodeSent
                    : l10n.externalSyncClearMessage,
              ),
              if (verifying) ...[
                const SizedBox(height: 16),
                OtpInputField(
                  controller: _code,
                  compact: true,
                  enabled: !_busy,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _clear,
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: _busy || _resendSeconds > 0 ? null : _send,
                    child: Text(
                      _resendSeconds > 0
                          ? l10n.resendCodeIn(_resendSeconds)
                          : l10n.resendCode,
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        // One footer row prevents AlertDialog's OverflowBar stacking three
        // long actions and squeezing the code field behind the keyboard.
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                  ),
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: Text(l10n.cancel, textAlign: TextAlign.center),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    backgroundColor: verifying
                        ? Theme.of(context).colorScheme.error
                        : null,
                    foregroundColor: verifying
                        ? Theme.of(context).colorScheme.onError
                        : null,
                  ),
                  onPressed: _busy
                      ? null
                      : !verifying
                      ? _send
                      : _code.text.length == 6
                      ? _clear
                      : null,
                  child: _busy
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: verifying
                                ? l10n.externalSyncClearing
                                : l10n.externalSyncClearSendCode,
                          ),
                        )
                      : Text(
                          verifying
                              ? l10n.clear
                              : l10n.externalSyncClearSendCode,
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
