import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/login_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Better Keep',
      packageName: 'io.foxbiz.better_keep',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('optically scales Apple icon within its 24px slot', (
    tester,
  ) async {
    await _pumpLoginPage(tester);

    final iconScale = find.byKey(const ValueKey('appleSignInIconOpticalScale'));
    expect(iconScale, findsOneWidget);
    expect(tester.getSize(iconScale), const Size.square(24));

    final transform = tester.widget<Transform>(iconScale);
    expect(transform.transform.getMaxScaleOnAxis(), closeTo(1.4, 0.001));
  });

  if (kIsWeb) {
    testWidgets('shows Apple sign-in on web', (tester) async {
      await _pumpLoginPage(tester);
      expect(find.text('Continue with Apple'), findsOneWidget);
    });
  } else {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      testWidgets('shows Apple sign-in on ${platform.name}', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await _pumpLoginPage(tester);

          expect(find.text('Continue with Apple'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    for (final platform in [TargetPlatform.linux, TargetPlatform.fuchsia]) {
      testWidgets('hides Apple sign-in on ${platform.name}', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await _pumpLoginPage(tester);

          expect(find.text('Continue with Apple'), findsNothing);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
}

Future<void> _pumpLoginPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: LoginPage(),
      ),
    ),
  );
  await tester.pump();
}
