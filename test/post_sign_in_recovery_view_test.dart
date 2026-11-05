import 'package:better_keep/components/post_sign_in_recovery_view.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'deletion support message hides retry without removing local access',
    (tester) async {
      await tester.pumpWidget(
        _host(
          PostSignInRecoveryView(
            message: 'Account deletion has already started. Contact support@betterkeep.app for help.',
            canRetry: false,
            onRetry: () async {},
            onContinueOffline: () async {},
            onSignOut: () async {},
          ),
        ),
      );
      expect(
        find.textContaining('Contact support@betterkeep.app'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Continue Offline'), findsOneWidget);
    },
  );

  testWidgets('authenticated recovery exposes retry and offline actions', (
    tester,
  ) async {
    var retryCount = 0;
    var offlineCount = 0;

    await tester.pumpWidget(
      _host(
        PostSignInRecoveryView(
          onRetry: () async {
            retryCount++;
          },
          onContinueOffline: () async {
            offlineCount++;
          },
          onSignOut: () async {},
        ),
      ),
    );

    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Continue Offline'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.tap(find.text('Continue Offline'));
    await tester.pump();

    expect(retryCount, 1);
    expect(offlineCount, 1);
  });

  testWidgets(
    'sign out delegates to the caller for account-aware confirmation',
    (tester) async {
      var signOutCount = 0;
      await tester.pumpWidget(
        _host(
          PostSignInRecoveryView(
            onRetry: () async {},
            onContinueOffline: () async {},
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
