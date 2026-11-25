import 'dart:async';

import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:better_keep/services/e2ee/device_pairing_channel.dart';
import 'package:flutter/services.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// The public identity shown here must come from the requesting device's local
/// secure storage, never from a server round trip.
class DeviceVerificationCard extends StatelessWidget {
  const DeviceVerificationCard({
    super.key,
    required this.request,
    required this.onRegenerate,
    this.onUseCode,
    this.onShowQr,
    this.codeSession,
  });
  final DeviceVerificationRequest request;
  final VoidCallback? onRegenerate;
  final VoidCallback? onUseCode;
  final VoidCallback? onShowQr;
  final PendingPairingCode? codeSession;

  @override
  Widget build(BuildContext context) {
    final code = codeSession;
    if (code != null) {
      return ListenableBuilder(
        listenable: code,
        builder: (context, _) => _PairingCodeDisplay(
          session: code,
          onRegenerate: onRegenerate,
          onShowQr: onShowQr,
        ),
      );
    }
    final valid = request.isValidAt(DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          !valid
              ? context.l10n.deviceVerificationExpired
              : context.l10n.devicePairingScanInstruction,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (valid) ...[
          LayoutBuilder(
            builder: (context, constraints) => ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: QrImageView(
                data: request.qrData,
                size: constraints.maxWidth.clamp(0, 240),
                padding: const EdgeInsets.all(12),
                backgroundColor: Colors.white,
                semanticsLabel: context.l10n.verifyNewDevice,
              ),
            ),
          ),
          if (onUseCode != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onUseCode,
              child: Text(context.l10n.deviceUsePairingCode),
            ),
          ],
        ] else
          FilledButton.icon(
            onPressed: onRegenerate,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.newVerificationCode),
          ),
      ],
    );
  }
}

class _PairingCodeDisplay extends StatelessWidget {
  const _PairingCodeDisplay({
    required this.session,
    this.onRegenerate,
    this.onShowQr,
  });
  final PendingPairingCode session;
  final VoidCallback? onRegenerate;
  final VoidCallback? onShowQr;
  @override
  Widget build(BuildContext context) {
    final waiting = session.state == PairingCodeState.waiting;
    final unavailable = session.state == PairingCodeState.unavailable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          unavailable
              ? context.l10n.devicePairingCodeExpired
              : waiting
              ? context.l10n.devicePairingCodeInstruction
              : context.l10n.devicePairingConnecting,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        if (waiting)
          Semantics(
            label: context.l10n.devicePairingCodeLabel,
            child: SelectableText(
              '${session.code.substring(0, 4)} ${session.code.substring(4)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          )
        else if (!unavailable)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        const SizedBox(height: 12),
        if (unavailable)
          FilledButton(
            onPressed: onRegenerate,
            child: Text(context.l10n.newVerificationCode),
          ),
        if (!session.handoffInProgress)
          TextButton(onPressed: onShowQr, child: Text(context.l10n.showQrCode)),
      ],
    );
  }
}

typedef PairingCodeVerifier = Future<VerifiedDeviceApproval> Function(
  DeviceVerificationRequest request,
  String code,
  bool Function() isCurrent,
);

/// A focused pairing surface, shared by waiting, verification and revoked states.
class DeviceApprovalPanel extends StatelessWidget {
  const DeviceApprovalPanel({
    super.key,
    required this.title,
    required this.child,
    required this.onMoreOptions,
    required this.onCancel,
    required this.cancelLabel,
    this.icon = Icons.devices_outlined,
  });
  final String title;
  final Widget child;
  final VoidCallback? onMoreOptions;
  final VoidCallback? onCancel;
  final String cancelLabel;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    icon,
                    color: theme.colorScheme.onPrimaryContainer,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            children: [
              TextButton(
                onPressed: onMoreOptions,
                child: Text(context.l10n.moreOptions),
              ),
              TextButton(onPressed: onCancel, child: Text(cancelLabel)),
            ],
          ),
        ],
      ),
    );
  }
}

Future<VerifiedDeviceApproval?> showDeviceVerificationDialog(
  BuildContext context,
  DeviceVerificationRequest request, {
  Stream<DeviceVerificationRequest?>? updates,
  PairingCodeVerifier? verifyCode,
}) async {
  var mismatch = false;
  if (_scannerSupported && request.isValidAt(DateTime.now())) {
    final value = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(
        builder: (_) => _DeviceQrScanner(
          title: context.l10n.scanNewDevice,
          allowCode: verifyCode != null,
        ),
      ),
    );
    if (!context.mounted || value == null) return null;
    if (value.isNotEmpty && value != 'pairing-code') {
      try {
        return request.verifyQr(value);
      } catch (_) {
        mismatch = true;
      }
    }
  }
  if (!context.mounted) return null;
  return showDialog<VerifiedDeviceApproval>(
    context: context,
    builder: (_) => StreamBuilder<DeviceVerificationRequest?>(
      stream: updates,
      initialData: request,
      builder: (context, snapshot) {
        if (!snapshot.hasError &&
            snapshot.connectionState == ConnectionState.active &&
            snapshot.data == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.pop(context);
            }
          });
          return const SizedBox.shrink();
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return AlertDialog(
            title: Text(context.l10n.verifyNewDevice),
            content: Text(context.l10n.deviceVerificationRetry),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
            ],
          );
        }
        final current = snapshot.requireData!;
        final changed = current.canonical != request.canonical;
        if (verifyCode != null) {
          return _PairingCodeEntry(
            key: ValueKey(current.canonical),
            request: current,
            verify: verifyCode,
          );
        }
        return _DeviceVerificationDialog<VerifiedDeviceApproval>(
          key: ValueKey(current.canonical),
          request: current,
          mismatch: !changed && mismatch,
        );
      },
    ),
  );
}

bool get _scannerSupported =>
    kIsWeb ||
    [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

Future<VerifiedDeviceReceipt?> showDeviceReceiptVerificationDialog(
  BuildContext context,
  DeviceApprovalReceipt receipt,
) => showDialog<VerifiedDeviceReceipt>(
  context: context,
  builder: (_) => _DeviceVerificationDialog<VerifiedDeviceReceipt>(
    request: receipt,
    trustedDevice: true,
  ),
);

/// Opens the next pairing step once per handoff, without interrupting another
/// dialog or repeatedly reopening a verification the user has dismissed.
class DeviceReceiptVerificationPrompt extends StatefulWidget {
  const DeviceReceiptVerificationPrompt({
    super.key,
    required this.receipt,
    required this.onVerify,
  });
  final DeviceApprovalReceipt receipt;
  final Future<void> Function() onVerify;

  @override
  State<DeviceReceiptVerificationPrompt> createState() =>
      _DeviceReceiptVerificationPromptState();
}

class _DeviceReceiptVerificationPromptState
    extends State<DeviceReceiptVerificationPrompt> {
  String? _promptedFingerprint;
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    _schedulePrompt();
  }

  @override
  void didUpdateWidget(DeviceReceiptVerificationPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedulePrompt();
  }

  void _schedulePrompt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _prompting ||
          !widget.receipt.requiresReturnVerification ||
          _promptedFingerprint == widget.receipt.fingerprint ||
          ModalRoute.of(context)?.isCurrent != true ||
          !widget.receipt.isValidAt(DateTime.now())) {
        return;
      }
      unawaited(_verify());
    });
  }

  Future<void> _verify() async {
    if (_prompting || !widget.receipt.isValidAt(DateTime.now())) return;
    setState(() {
      _promptedFingerprint = widget.receipt.fingerprint;
      _prompting = true;
    });
    try {
      await widget.onVerify();
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        context.l10n.verifyTrustedDeviceInstructions,
        textAlign: TextAlign.center,
      ),
      if (!_prompting &&
          _promptedFingerprint == widget.receipt.fingerprint) ...[
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _verify,
          icon: const Icon(Icons.verified_user),
          label: Text(context.l10n.verifyTrustedDevice),
        ),
      ],
    ],
  );
}

Future<void> showDeviceApprovalReceipt(
  BuildContext context,
  DeviceApprovalReceipt receipt, {
  Stream<bool>? finished,
}) {
  if (!receipt.requiresReturnVerification) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.deviceApproved)));
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (context) => _ApprovalReceiptLifetime(
      receipt: receipt,
      finished: finished,
      child: AlertDialog(
        title: Text(context.l10n.confirmOnNewDevice),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.confirmOnNewDeviceInstructions),
                const SizedBox(height: 16),
                QrImageView(
                  data: receipt.qrData,
                  size: 240,
                  backgroundColor: Colors.white,
                  semanticsLabel: context.l10n.verifyTrustedDevice,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    ),
  );
}

class _ApprovalReceiptLifetime extends StatefulWidget {
  const _ApprovalReceiptLifetime({
    required this.receipt,
    required this.child,
    this.finished,
  });
  final DeviceApprovalReceipt receipt;
  final Widget child;
  final Stream<bool>? finished;
  @override
  State<_ApprovalReceiptLifetime> createState() =>
      _ApprovalReceiptLifetimeState();
}

class _ApprovalReceiptLifetimeState extends State<_ApprovalReceiptLifetime> {
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  bool _closing = false;
  @override
  void initState() {
    super.initState();
    _subscription = widget.finished?.listen((done) {
      if (done) _close();
    }, onError: (Object _) => _close());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!widget.receipt.isValidAt(DateTime.now())) _close();
    });
  }

  void _close() {
    if (!mounted || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DeviceVerificationDialog<T> extends StatefulWidget {
  const _DeviceVerificationDialog({
    super.key,
    required this.request,
    this.trustedDevice = false,
    this.mismatch = false,
  });
  final DeviceVerificationChallenge<T> request;
  final bool trustedDevice;
  final bool mismatch;
  @override
  State<_DeviceVerificationDialog<T>> createState() =>
      _DeviceVerificationDialogState<T>();
}

class _DeviceVerificationDialogState<T>
    extends State<_DeviceVerificationDialog<T>> {
  bool _scanning = false;
  bool _mismatch = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _mismatch = widget.mismatch;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!widget.request.isValidAt(DateTime.now())) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _mismatch = false;
    });
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _DeviceQrScanner(
          title: widget.trustedDevice
              ? context.l10n.scanTrustedDevice
              : context.l10n.scanNewDevice,
        ),
      ),
    );
    if (!mounted) return;
    if (value != null && value.isNotEmpty) {
      try {
        final verified = widget.request.verifyQr(value);
        Navigator.pop(context, verified);
        return;
      } catch (_) {
        setState(() {
          _scanning = false;
          _mismatch = true;
        });
        return;
      }
    }
    setState(() {
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final valid = widget.request.isValidAt(DateTime.now());
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.trustedDevice
            ? context.l10n.verifyTrustedDevice
            : context.l10n.verifyNewDevice,
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!valid)
                Text(context.l10n.deviceVerificationExpired)
              else ...[
                Text(
                  widget.trustedDevice
                      ? context.l10n.verifyTrustedDeviceInstructions
                      : context.l10n.deviceVerificationInstructions,
                ),
                const SizedBox(height: 16),
                if (_mismatch)
                  Text(
                    context.l10n.deviceVerificationMismatch,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_scannerSupported)
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(
                      widget.trustedDevice
                          ? context.l10n.scanTrustedDevice
                          : context.l10n.scanNewDevice,
                    ),
                  ),
                if (!_scannerSupported)
                  Text(context.l10n.deviceCameraUnavailable),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
      ],
    );
  }
}

class _DeviceQrScanner extends StatefulWidget {
  const _DeviceQrScanner({required this.title, this.allowCode = false});
  final String title;
  final bool allowCode;
  @override
  State<_DeviceQrScanner> createState() => _DeviceQrScannerState();
}

class _DeviceQrScannerState extends State<_DeviceQrScanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _returned = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // Do not load executable code from a third-party CDN in an unlocked app.
      MobileScannerPlatform.instance.setWebBarcodeReader(
        WebBarcodeReader.zxingJs,
      );
      MobileScannerPlatform.instance.setBarcodeLibraryScriptUrl(
        Uri.base.resolve('vendor/zxing-0.23.0.min.js').toString(),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _controller,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  widget.allowCode
                      ? context.l10n.devicePairingCodeEntryInstruction
                      : context.l10n.deviceCameraUnavailable,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            onDetect: (capture) {
              if (_returned || !mounted) return;
              final values = capture.barcodes
                  .map((barcode) => barcode.rawValue)
                  .whereType<String>();
              if (values.isEmpty) return;
              _returned = true;
              Navigator.pop(context, values.first);
            },
          ),
        ),
        SafeArea(
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              if (widget.allowCode)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'pairing-code'),
                  child: Text(context.l10n.deviceEnterPairingCode),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _PairingCodeEntry extends StatefulWidget {
  const _PairingCodeEntry({
    super.key,
    required this.request,
    required this.verify,
  });
  final DeviceVerificationRequest request;
  final PairingCodeVerifier verify;
  @override
  State<_PairingCodeEntry> createState() => _PairingCodeEntryState();
}

class _PairingCodeEntryState extends State<_PairingCodeEntry> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _failed = false;
  bool _cancelled = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!widget.request.isValidAt(DateTime.now())) setState(() {});
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy ||
        _controller.text.length != 8 ||
        !widget.request.isValidAt(DateTime.now())) {
      return;
    }
    final code = _controller.text;
    setState(() {
      _busy = true;
      _failed = false;
    });
    // Let the spinner paint before the browser's SRP calculation.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (!mounted || _cancelled) return;
    try {
      final proof = await widget.verify(
        widget.request,
        code,
        () => mounted && !_cancelled,
      );
      if (mounted && !_cancelled) Navigator.pop(context, proof);
    } catch (_) {
      if (mounted && !_cancelled) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid = widget.request.isValidAt(DateTime.now());
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true;
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(context.l10n.deviceEnterPairingCode),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                valid
                    ? context.l10n.devicePairingCodeEntryInstruction
                    : context.l10n.deviceVerificationExpired,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                enabled: valid && !_busy,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: InputDecoration(
                  labelText: context.l10n.devicePairingCodeLabel,
                  border: const OutlineInputBorder(),
                  errorText: _failed
                      ? context.l10n.devicePairingCodeFailed
                      : null,
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() => _failed = false),
                onSubmitted: (_) => _connect(),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _cancelled = true;
              Navigator.pop(context);
            },
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: !valid || _busy || _controller.text.length != 8
                ? null
                : _connect,
            child: Text(
              _busy
                  ? context.l10n.devicePairingConnecting
                  : context.l10n.approve,
            ),
          ),
        ],
      ),
    );
  }
}
