import 'package:better_keep/components/firebase_environment_banner.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const live = FirebaseEnvironmentStatus(
    environment: FirebaseEnvironment.live,
    appName: '[DEFAULT]',
    projectId: 'better-keep-notes',
    databaseId: 'better-keep',
    localDataScope: FirebaseLocalDataScope.live,
  );
  const emulator = FirebaseEnvironmentStatus(
    environment: FirebaseEnvironment.emulator,
    appName: 'better-keep-emulator-a1b2c3',
    projectId: 'better-keep-notes',
    databaseId: '(default)',
    localDataScope: FirebaseLocalDataScope.emulator,
    host: '192.168.1.25',
  );

  testWidgets(
    'shows platform-neutral Emulator status',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FirebaseEnvironmentBanner(
              debugModeOverride: true,
              statusOverride: emulator,
            ),
          ),
        ),
      );

      expect(find.textContaining('EMULATOR'), findsOneWidget);
      expect(find.textContaining('192.168.1.25'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('shows Live status and complete read-only routing details', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FirebaseEnvironmentBanner(
            debugModeOverride: true,
            statusOverride: live,
          ),
        ),
      ),
    );

    expect(find.textContaining('LIVE FIREBASE'), findsOneWidget);
    await tester.tap(find.textContaining('LIVE FIREBASE'));
    await tester.pumpAndSettle();

    expect(find.text('Live Firebase'), findsOneWidget);
    expect(find.text('[DEFAULT]'), findsOneWidget);
    expect(find.text('better-keep-notes'), findsOneWidget);
    expect(find.textContaining('better_keep.db'), findsOneWidget);
    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Cloud Firestore'), findsOneWidget);
    expect(find.text('Cloud Functions'), findsOneWidget);
    expect(find.text('Cloud Storage'), findsOneWidget);
  });

  testWidgets('is hidden outside debug builds', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FirebaseEnvironmentBanner(
            debugModeOverride: false,
            statusOverride: emulator,
          ),
        ),
      ),
    );

    expect(find.textContaining('EMULATOR'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('compact banner remains accessible', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: FirebaseEnvironmentBanner(
              debugModeOverride: true,
              statusOverride: emulator,
            ),
          ),
        ),
      ),
    );

    final semanticsWidgets = tester.widgetList<Semantics>(
      find.descendant(
        of: find.byType(FirebaseEnvironmentBanner),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      semanticsWidgets.any(
        (widget) =>
            widget.properties.label ==
            'Firebase environment Emulator at 192.168.1.25. '
                'Tap for routing details.',
      ),
      isTrue,
    );
    expect(find.text('EMULATOR · 192.168.1.25'), findsOneWidget);
    semantics.dispose();
  });
}
