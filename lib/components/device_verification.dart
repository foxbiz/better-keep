import 'dart:async';

import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// The public identity shown here must come from the requesting device's local
/// secure storage, never from a server round trip.
class DeviceVerificationCard extends StatefulWidget {
  const DeviceVerificationCard({
    super.key,
    required this.request,
    required this.onRegenerate,
  });
  final DeviceVerificationRequest request;
  final VoidCallback? onRegenerate;

  @override
  State<DeviceVerificationCard> createState() => _DeviceVerificationCardState();
}

class _DeviceVerificationCardState extends State<DeviceVerificationCard> {
  bool _showCode = false;

  @override
  Widget build(BuildContext context) {
    final valid = widget.request.isValidAt(DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          !valid
              ? context.l10n.deviceVerificationExpired
              : _showCode
              ? context.l10n.devicePairingCodeInstruction
              : context.l10n.devicePairingScanInstruction,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (valid) ...[
          if (_showCode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                widget.request.securityCode,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 20,
                  height: 1.6,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) => ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: QrImageView(
                  data: widget.request.qrData,
                  size: constraints.maxWidth.clamp(0, 240),
                  padding: const EdgeInsets.all(12),
                  backgroundColor: Colors.white,
                  semanticsLabel: context.l10n.verifyNewDevice,
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => setState(() => _showCode = !_showCode),
            icon: Icon(
              _showCode ? Icons.qr_code_2 : Icons.pin_outlined,
              size: 18,
            ),
            label: Text(
              _showCode
                  ? context.l10n.showQrCode
                  : context.l10n.compareSecurityCode,
            ),
          ),
        ] else
          FilledButton.icon(
            onPressed: widget.onRegenerate,
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.newVerificationCode),
          ),
      ],
    );
  }
}

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
  DeviceVerificationRequest request,
) async {
  var mismatch = false;
  if (_scannerSupported && request.isValidAt(DateTime.now())) {
    final value = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(
        builder: (_) => _DeviceQrScanner(title: context.l10n.scanNewDevice),
      ),
    );
    if (!context.mounted || value == null) return null;
    if (value.isNotEmpty) {
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
    builder: (_) => _DeviceVerificationDialog<VerifiedDeviceApproval>(
      request: request,
      comparing: !mismatch,
      mismatch: mismatch,
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
          widget.receipt.hasPairingProof ||
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
  if (receipt.hasPairingProof) {
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
                const SizedBox(height: 12),
                SelectableText(
                  receipt.securityCode,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
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
    required this.request,
    this.trustedDevice = false,
    this.comparing = false,
    this.mismatch = false,
  });
  final DeviceVerificationChallenge<T> request;
  final bool trustedDevice;
  final bool comparing;
  final bool mismatch;
  @override
  State<_DeviceVerificationDialog<T>> createState() =>
      _DeviceVerificationDialogState<T>();
}

class _DeviceVerificationDialogState<T>
    extends State<_DeviceVerificationDialog<T>> {
  bool _comparing = false;
  bool _matches = false;
  bool _scanning = false;
  bool _mismatch = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _comparing = widget.comparing;
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
      _matches = false;
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
      _comparing = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final valid = widget.request.isValidAt(DateTime.now());
    return AlertDialog(
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
                TextButton(
                  onPressed: () => setState(() => _comparing = true),
                  child: Text(context.l10n.compareSecurityCode),
                ),
                if (_comparing) ...[
                  SelectableText(
                    widget.request.securityCode,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 18,
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _matches,
                    onChanged: (value) =>
                        setState(() => _matches = value ?? false),
                    title: Text(context.l10n.completeSecurityCodeMatches),
                  ),
                ],
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
        FilledButton(
          onPressed: valid && _comparing && _matches
              ? () {
                  if (!widget.request.isValidAt(DateTime.now())) {
                    setState(() {});
                    return;
                  }
                  Navigator.pop(
                    context,
                    widget.request.confirmCode(widget.request.securityCode),
                  );
                }
              : null,
          child: Text(
            widget.trustedDevice
                ? context.l10n.acceptVerifiedKey
                : context.l10n.approveVerifiedDevice,
          ),
        ),
      ],
    );
  }
}

class _DeviceQrScanner extends StatefulWidget {
  const _DeviceQrScanner({required this.title});
  final String title;
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
            errorBuilder: (context, error) =>
                Center(child: Text(context.l10n.deviceCameraUnavailable)),
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
          child: TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: Text(context.l10n.compareSecurityCode),
          ),
        ),
      ],
    ),
  );
}
