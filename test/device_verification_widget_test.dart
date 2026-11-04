import 'dart:async';
import 'dart:convert';

import 'package:better_keep/components/device_verification.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/e2ee/device_verification.dart';
import 'package:better_keep/services/e2ee/device_pairing_channel.dart';

import 'device_pairing_code_test.dart' show MemoryPairingMailbox;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  DeviceVerificationRequest request({bool codeApproval = false}) =>
      DeviceVerificationRequest.create(
        codeApproval: codeApproval,
        account: 'user',
        environment: 'test',
        deviceId: 'new',
        publicKey: Uint8List(32),
      );
  Widget app(Future<void> Function(BuildContext) open) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => open(context),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  DeviceApprovalReceipt receipt() => DeviceApprovalReceipt(
    request: request(),
    approverPublicKey: base64Encode(Uint8List(32)),
    ciphertext: base64Encode(Uint8List(100)),
    nonce: base64Encode(Uint8List(24)),
  );

  testWidgets('method switch is hidden while code approval is in flight', (
    tester,
  ) async {
    final local = request();
    final mailbox = MemoryPairingMailbox();
    late PendingPairingCode host;
    await tester.runAsync(() async {
      host = await PendingPairingCode.start(
        local,
        mailbox,
        isCurrent: () => true,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DeviceVerificationCard(
            request: local,
            codeSession: host,
            onRegenerate: () {},
            onShowQr: () {},
          ),
        ),
      ),
    );
    expect(find.text('Show QR code'), findsOneWidget);
    await tester.runAsync(() async {
      await verifyPairingCode(
        DeviceVerificationRequest.fromJson(local.toJson()),
        host.code,
        mailbox,
        isCurrent: () => true,
      );
    });
    await tester.pump();
    expect(host.handoffInProgress, true);
    expect(find.text('Show QR code'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
    await mailbox.close();
  });

  testWidgets('camera-free approval accepts eight digits with one tap', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(390, 600));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final local = request();
    VerifiedDeviceApproval? verified;
    String? entered;
    await tester.pumpWidget(
      app((context) async {
        verified = await showDeviceVerificationDialog(
          context,
          DeviceVerificationRequest.fromJson(local.toJson()),
          verifyCode: (pending, code, current) async {
            expect(current(), true);
            entered = code;
            return pending.verifyQr(local.qrData);
          },
        );
      }),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '0123 4567');
    await tester.pump();
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(entered, '01234567');
    expect(verified, isNotNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancelling a code exchange cannot return an approval', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final local = request();
    final exchange = Completer<VerifiedDeviceApproval>();
    bool Function()? current;
    VerifiedDeviceApproval? verified;
    await tester.pumpWidget(
      app((context) async {
        verified = await showDeviceVerificationDialog(
          context,
          local,
          verifyCode: (_, _, isCurrent) {
            current = isCurrent;
            return exchange.future;
          },
        );
      }),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '01234567');
    await tester.pump();
    await tester.tap(find.text('Approve'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(current!(), true);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(current!(), false);
    exchange.complete(local.verifyQr(local.qrData));
    await tester.pumpAndSettle();
    expect(verified, isNull);
    debugDefaultTargetPlatformOverride = null;
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'scanner offers a code fallback when camera permission is denied',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = _DeniedCamera();
      addTearDown(() => MobileScannerPlatform.instance = previous);
      await tester.pumpWidget(
        app((context) async {
          await showDeviceVerificationDialog(
            context,
            request(),
            verifyCode: (pending, _, _) async =>
                pending.verifyQr(pending.qrData),
          );
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter pairing code'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'terminal request update closes comparison without a retry error',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final updates = StreamController<DeviceVerificationRequest?>();
      addTearDown(updates.close);
      await tester.pumpWidget(
        app((context) async {
          await showDeviceVerificationDialog(
            context,
            request(codeApproval: true),
            updates: updates.stream,
          );
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      updates.add(null);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Open').hitTestable(), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'one-scan approval returns to the app without a return-verification dialog',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = _WorkingCamera();
      addTearDown(() => MobileScannerPlatform.instance = previous);
      final local = request();
      final public = DeviceVerificationRequest.fromJson(local.toJson());
      DeviceApprovalReceipt? approved;
      await tester.pumpWidget(
        app((context) async {
          final proof = await showDeviceVerificationDialog(context, public);
          if (proof == null || !context.mounted) return;
          approved = proof.authenticateReceipt(
            DeviceApprovalReceipt(
              request: public,
              approverPublicKey: base64Encode(Uint8List(32)),
              ciphertext: base64Encode(Uint8List(100)),
              nonce: base64Encode(Uint8List(24)),
            ),
          );
          await showDeviceApprovalReceipt(context, approved!);
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
        BarcodeCapture(
          barcodes: [
            Barcode(rawValue: local.qrData, format: BarcodeFormat.qrCode),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(approved!.hasPairingProof, true);
      expect(
        local.verifyPairingReceipt(approved!),
        isA<VerifiedDeviceReceipt>(),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.text('Open').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('invalidated request removes approval from an open dialog', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final updates = StreamController<DeviceVerificationRequest>();
    addTearDown(updates.close);
    VerifiedDeviceApproval? verified;
    await tester.pumpWidget(
      app((context) async {
        verified = await showDeviceVerificationDialog(
          context,
          request(codeApproval: true),
          updates: updates.stream,
        );
      }),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    updates.addError(StateError('Request cancelled or no longer valid'));
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(verified, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(updates.hasListener, false);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'trusted device renders the return QR dialog without a stranded barrier',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = receipt();
      await tester.pumpWidget(
        app((context) => showDeviceApprovalReceipt(context, value)),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Open').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('manual receipt closes when recipient confirms', (tester) async {
    final done = StreamController<bool>();
    addTearDown(done.close);
    await tester.pumpWidget(
      app(
        (context) => showDeviceApprovalReceipt(
          context,
          receipt(),
          finished: done.stream,
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    done.add(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Open').hitTestable(), findsOneWidget);
  });

  for (final trusted in [false, true]) {
    testWidgets(
      'matching QR completes ${trusted ? 'recipient' : 'approver'} verification without an extra tap',
      (tester) async {
        final previous = MobileScannerPlatform.instance;
        MobileScannerPlatform.instance = _WorkingCamera();
        addTearDown(() => MobileScannerPlatform.instance = previous);
        final challenge = trusted ? receipt() : request();
        Object? verified;
        await tester.pumpWidget(
          app((context) async {
            verified = trusted
                ? await showDeviceReceiptVerificationDialog(
                    context,
                    challenge as DeviceApprovalReceipt,
                  )
                : await showDeviceVerificationDialog(
                    context,
                    challenge as DeviceVerificationRequest,
                  );
          }),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        if (trusted) {
          await tester.tap(find.text('Scan trusted device'));
          await tester.pumpAndSettle();
        }
        final scanner = tester.widget<MobileScanner>(
          find.byType(MobileScanner),
        );
        final qr = trusted
            ? (challenge as DeviceApprovalReceipt).qrData
            : (challenge as DeviceVerificationRequest).qrData;
        scanner.onDetect!(
          BarcodeCapture(
            barcodes: [Barcode(rawValue: qr, format: BarcodeFormat.qrCode)],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          verified,
          trusted
              ? isA<VerifiedDeviceReceipt>()
              : isA<VerifiedDeviceApproval>(),
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(MobileScanner), findsNothing);
        expect(find.text('Open').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'back from direct scanner cancels approval without a leftover dialog',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = _WorkingCamera();
      addTearDown(() => MobileScannerPlatform.instance = previous);
      VerifiedDeviceApproval? verified;
      var completed = false;
      await tester.pumpWidget(
        app((context) async {
          verified = await showDeviceVerificationDialog(context, request());
          completed = true;
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileScanner), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(completed, true);
      expect(verified, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Open').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('mismatched scanned QR never completes verification', (
    tester,
  ) async {
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = _WorkingCamera();
    addTearDown(() => MobileScannerPlatform.instance = previous);
    VerifiedDeviceApproval? verified;
    final value = request();
    await tester.pumpWidget(
      app((context) async {
        verified = await showDeviceVerificationDialog(context, value);
      }),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [
          Barcode(rawValue: request().qrData, format: BarcodeFormat.qrCode),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(verified, isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  for (final language in ['en', 'id', 'ja', 'ko', 'pt', 'tr', 'zh']) {
    testWidgets(
      'pairing shows one method at a time and fits large text: $language',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final value = request();
        final locale = Locale(language);
        final l10n = lookupAppLocalizations(locale);
        var moreOptions = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: DeviceApprovalPanel(
                  title: l10n.verifyNewDevice,
                  onMoreOptions: () => moreOptions++,
                  onCancel: () {},
                  cancelLabel: l10n.cancel,
                  child: StatefulBuilder(
                    builder: (context, setState) => DeviceVerificationCard(
                      request: value,
                      onRegenerate: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(QrImageView), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                widget.data?.replaceAll('\n', ' ') == value.securityCode,
          ),
          findsNothing,
        );
        expect(find.text(l10n.newVerificationCode), findsNothing);
        expect(find.text(l10n.startFresh), findsNothing);
        expect(find.text(l10n.verifyNewDevice), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.text(l10n.compareSecurityCode), findsNothing);
        expect(
          tester
              .widget<DeviceVerificationCard>(
                find.byType(DeviceVerificationCard),
              )
              .request
              .qrData,
          value.qrData,
        );
        await tester.ensureVisible(find.text(l10n.moreOptions));
        await tester.tap(find.text(l10n.moreOptions));
        expect(moreOptions, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'receipt prompts automatically once and can be resumed after dismissal',
    (tester) async {
      var value = receipt();
      var prompts = 0;
      VerifiedDeviceReceipt? verified;
      late StateSetter refresh;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return Scaffold(
                body: DeviceReceiptVerificationPrompt(
                  receipt: value,
                  onVerify: () async {
                    prompts++;
                    verified = await showDeviceReceiptVerificationDialog(
                      context,
                      value,
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(prompts, 1);
      expect(verified, isNull);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      refresh(() {}); // Polling the same handoff must not reopen the dialog.
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(prompts, 1);
      await tester.tap(find.text('Verify trusted device'));
      await tester.pumpAndSettle();
      expect(prompts, 2);
      expect(find.text('Compare security code'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'receipt waits until the pending page is visible before prompting',
    (tester) async {
      final value = receipt();
      var available = false;
      var prompts = 0;
      late StateSetter refresh;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Other dialog'),
                    ),
                    if (available)
                      DeviceReceiptVerificationPrompt(
                        receipt: value,
                        onVerify: () async {
                          prompts++;
                          await showDeviceReceiptVerificationDialog(
                            context,
                            value,
                          );
                        },
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Other dialog'));
      await tester.pumpAndSettle();
      refresh(() => available = true);
      await tester.pumpAndSettle();
      expect(prompts, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      refresh(() {}); // The next status refresh finds the page visible again.
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('unsupported camera never offers unverified code approval', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    VerifiedDeviceApproval? verified;
    await tester.pumpWidget(
      app((context) async {
        verified = await showDeviceVerificationDialog(context, request());
      }),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Compare security code'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(verified, isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'new device can cancel return verification without accepting a handoff',
    (tester) async {
      final value = DeviceApprovalReceipt(
        request: request(),
        approverPublicKey: base64Encode(Uint8List(32)),
        ciphertext: base64Encode(Uint8List(100)),
        nonce: base64Encode(Uint8List(24)),
      );
      VerifiedDeviceReceipt? verified;
      await tester.pumpWidget(
        app((context) async {
          verified = await showDeviceReceiptVerificationDialog(context, value);
        }),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Verify trusted device'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(verified, isNull);
    },
  );
  testWidgets(
    'Approve opens the camera directly and denial never offers code approval',
    (tester) async {
      final previous = MobileScannerPlatform.instance;
      final camera = _DeniedCamera();
      MobileScannerPlatform.instance = camera;
      addTearDown(() => MobileScannerPlatform.instance = previous);
      final value = request();
      await tester.pumpWidget(
        app((context) async {
          await showDeviceVerificationDialog(context, value);
        }),
      );
      expect(camera.starts, 0);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(camera.starts, 1);
      expect(
        find.text(
          'Camera unavailable. Enable camera access or recover with your passphrase.',
        ),
        findsOneWidget,
      );
      expect(find.text('Compare security code'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}

class _DeniedCamera extends MobileScannerPlatform {
  int starts = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    throw const MobileScannerException(
      errorCode: MobileScannerErrorCode.permissionDenied,
    );
  }

  @override
  Widget buildCameraView() => const SizedBox();
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _WorkingCamera extends _DeniedCamera {
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(640, 480),
      );
}
