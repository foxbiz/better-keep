import 'package:better_keep/components/firebase_environment_banner.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:web/web.dart' as web;

const _testFirebaseOptions = FirebaseOptions(
  apiKey: 'web-integration-test-api-key',
  appId: '1:123456789:web:better-keep-integration-test',
  messagingSenderId: '123456789',
  projectId: 'better-keep-notes',
  authDomain: 'betterkeep.app',
  storageBucket: 'better-keep-notes.appspot.com',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  FirebaseApp? emulatorApp;

  setUpAll(() async {
    if (Firebase.apps.every((app) => app.name != defaultFirebaseAppName)) {
      await Firebase.initializeApp(options: _testFirebaseOptions);
    }
  });

  tearDownAll(() async {
    FirebaseBackend.resetForTesting();
    await emulatorApp?.delete();
  });

  testWidgets('main web shell exposes one trustworthy environment ribbon', (
    tester,
  ) async {
    FirebaseBackend.resetForTesting();
    final emulator = await FirebaseBackend.configureEmulator(
      endpoints: const FirebaseEmulatorEndpoints(firebaseEmulatorLoopbackHost),
      googleAuthMode: GoogleEmulatorAuthMode.mock,
    );
    emulatorApp = emulator.app;

    await tester.pumpWidget(const _EnvironmentTestShell());
    await tester.pumpAndSettle();

    final warning = await _waitForFirebaseAuthWarning(tester);
    expect(
      web.window.getComputedStyle(warning).display,
      'none',
      reason: 'The SDK warning is replaced by FirebaseEnvironmentBanner.',
    );
    expect(warning.getClientRects().length, 0);
    _expectNoDocumentOverflow();

    expect(find.textContaining('EMULATOR'), findsOneWidget);
    expect(find.textContaining('LIVE FIREBASE'), findsNothing);
    await tester.tap(find.textContaining('EMULATOR'));
    await tester.pumpAndSettle();
    expect(find.text('Firebase Emulator'), findsOneWidget);
    expect(find.text(emulator.app.name), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    FirebaseBackend.resetForTesting();
    FirebaseBackend.configureLive();
    await tester.pumpWidget(const _EnvironmentTestShell());
    await tester.pumpAndSettle();

    expect(find.textContaining('LIVE FIREBASE'), findsOneWidget);
    expect(find.textContaining('EMULATOR'), findsNothing);
    await tester.tap(find.textContaining('LIVE FIREBASE'));
    await tester.pumpAndSettle();
    expect(find.text('Live Firebase'), findsOneWidget);
    _expectNoDocumentOverflow();
  });
}

class _EnvironmentTestShell extends StatelessWidget {
  const _EnvironmentTestShell();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            FirebaseEnvironmentBanner(debugModeOverride: true),
            Expanded(child: Center(child: Text('Firebase environment test'))),
          ],
        ),
      ),
    );
  }
}

Future<web.Element> _waitForFirebaseAuthWarning(WidgetTester tester) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final warning = web.document.querySelector('.firebase-emulator-warning');
    if (warning != null) return warning;
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw TestFailure(
    'Firebase Auth did not inject .firebase-emulator-warning within 5 seconds.',
  );
}

void _expectNoDocumentOverflow() {
  final documentElement = web.document.documentElement;
  expect(documentElement, isNotNull);
  expect(
    documentElement!.scrollWidth,
    lessThanOrEqualTo(documentElement.clientWidth + 1),
    reason: 'The hidden SDK warning must not create horizontal overflow.',
  );
  expect(
    documentElement.scrollHeight,
    lessThanOrEqualTo(documentElement.clientHeight + 1),
    reason: 'The hidden SDK warning must not leave bottom whitespace.',
  );
}
