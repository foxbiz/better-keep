import 'dart:async';

import 'package:better_keep/components/post_sign_in_recovery_view.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('connection retry stays busy until the attempt completes', (
    tester,
  ) async {
    final retry = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(
      _host(
        PostSignInRecoveryView(
          connectionUnavailable: true,
          onRetry: () {
            attempts++;
            return retry.future;
          },
          onSignOut: () async {},
        ),
      ),
    );
    expect(find.text('Connection needed'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Retry'));
    expect(attempts, 1);
    retry.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('deletion support message hides retry', (tester) async {
    await tester.pumpWidget(
      _host(
        PostSignInRecoveryView(
          message: 'Account deletion has already started. Contact support@betterkeep.app for help.',
          canRetry: false,
          onRetry: () async {},
          onSignOut: () async {},
        ),
      ),
    );
    expect(
      find.textContaining('Contact support@betterkeep.app'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Continue Offline'), findsNothing);
  });

  testWidgets(
    'authenticated recovery exposes retry without a redundant offline action',
    (tester) async {
      var retryCount = 0;

      await tester.pumpWidget(
        _host(
          PostSignInRecoveryView(
            onRetry: () async {
              retryCount++;
            },
            onSignOut: () async {},
          ),
        ),
      );

      expect(find.byType(LoginPage), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Continue Offline'), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retryCount, 1);
    },
  );

  testWidgets(
    'sign out delegates to the caller for account-aware confirmation',
    (tester) async {
      var signOutCount = 0;
      await tester.pumpWidget(
        _host(
          PostSignInRecoveryView(
            onRetry: () async {},
            onSignOut: () async {
              signOutCount++;
            },
          ),
        ),
      );

      await tester.tap(find.text('Sign Out'));
      await tester.pumpAndSettle();
      expect(signOutCount, 1);
    },
  );
}

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);
