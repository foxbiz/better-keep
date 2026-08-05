import 'dart:async';

import 'package:better_keep/main.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('debug startup always prompts while release startup does not', () {
    expect(shouldPromptForFirebaseEnvironment(isDebugMode: true), isTrue);
    expect(shouldPromptForFirebaseEnvironment(isDebugMode: false), isFalse);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'debug_firebase_emulator_host': '192.168.1.25',
    });
    FirebaseEmulatorConfig.init(await SharedPreferences.getInstance());
  });

  testWidgets('submits physical host and real Google preference', (
    tester,
  ) async {
    FirebaseEnvironment? selectedEnvironment;
    String? selectedHost;
    GoogleEmulatorAuthMode? selectedGoogleMode;

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseSelectionScreen(
          onSelected:
              (
                environment, {
                physicalDeviceHost,
                googleAuthMode = GoogleEmulatorAuthMode.mock,
              }) async {
                selectedEnvironment = environment;
                selectedHost = physicalDeviceHost;
                selectedGoogleMode = googleAuthMode;
              },
        ),
      ),
    );

    expect(find.text('Computer LAN host'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '192.168.1.50');
    await tester.tap(find.text('Use real Google OAuth'));
    await tester.ensureVisible(find.text('Emulator'));
    await tester.tap(find.text('Emulator'));
    await tester.pump();

    expect(selectedEnvironment, FirebaseEnvironment.emulator);
    expect(selectedHost, '192.168.1.50');
    expect(selectedGoogleMode, GoogleEmulatorAuthMode.real);
  });

  testWidgets('Live selection never submits emulator routing details', (
    tester,
  ) async {
    FirebaseEnvironment? selectedEnvironment;
    String? selectedHost;

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseSelectionScreen(
          onSelected:
              (
                environment, {
                physicalDeviceHost,
                googleAuthMode = GoogleEmulatorAuthMode.mock,
              }) async {
                selectedEnvironment = environment;
                selectedHost = physicalDeviceHost;
              },
        ),
      ),
    );

    await tester.ensureVisible(find.text('Live'));
    await tester.tap(find.text('Live'));
    await tester.pump();

    expect(selectedEnvironment, FirebaseEnvironment.live);
    expect(selectedHost, isNull);
  });

  testWidgets('rapid environment taps submit only one selection', (
    tester,
  ) async {
    final completion = Completer<void>();
    var selections = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseSelectionScreen(
          onSelected:
              (
                environment, {
                physicalDeviceHost,
                googleAuthMode = GoogleEmulatorAuthMode.mock,
              }) {
                selections++;
                return completion.future;
              },
        ),
      ),
    );

    await tester.ensureVisible(find.text('Live'));
    await tester.tap(find.text('Live'));
    await tester.tap(find.text('Emulator'), warnIfMissed: false);
    await tester.pump();

    expect(selections, 1);
    completion.complete();
    await tester.pump();
  });

  testWidgets('shows actionable selection errors without choosing live', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseSelectionScreen(
          onSelected:
              (
                environment, {
                physicalDeviceHost,
                googleAuthMode = GoogleEmulatorAuthMode.mock,
              }) async {
                throw FirebaseEmulatorUnavailableException(
                  host: physicalDeviceHost ?? 'unknown',
                  failures: {'Authentication (9099)': 'connection refused'},
                );
              },
        ),
      ),
    );

    await tester.ensureVisible(find.text('Emulator'));
    await tester.tap(find.text('Emulator'));
    await tester.pump();

    expect(find.textContaining('never falls back'), findsOneWidget);
    expect(find.textContaining('Authentication (9099)'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('prefills emulator details and explains every-launch selection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'debug_firebase_environment': 'live',
      'debug_firebase_emulator_host': 'dev-mac.local',
      'debug_firebase_google_auth_mode': 'real',
    });
    FirebaseEmulatorConfig.init(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseSelectionScreen(
          onSelected:
              (
                environment, {
                physicalDeviceHost,
                googleAuthMode = GoogleEmulatorAuthMode.mock,
              }) async {},
        ),
      ),
    );

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'dev-mac.local',
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      find.textContaining('Choose an environment on every debug launch'),
      findsOneWidget,
    );
  });
}
