import 'package:better_keep/components/app_startup_view.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: betterKeepLocalizationDelegates,
    supportedLocales: betterKeepSupportedLocales,
    home: home,
  );

  testWidgets('startup loading uses selected locale and hides internals', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const AppStartupLoadingView(), locale: const Locale('ja')),
    );

    expect(
      find.text(lookupAppLocalizations(const Locale('ja')).gettingReady),
      findsOneWidget,
    );
    expect(find.textContaining('Firebase'), findsNothing);
  });

  testWidgets('retryable startup failure invokes retry', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      host(
        AppStartupErrorView(
          onRetry: () {
            retryCount++;
          },
        ),
      ),
    );

    expect(find.text('Unable to start Better Keep'), findsOneWidget);
    expect(find.textContaining('Review authorization'), findsNothing);
    expect(find.textContaining('Firebase'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retryCount, 1);
  });

  testWidgets('routing failure requires restart and omits retry', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppStartupErrorView()));

    expect(find.textContaining('Partial emulator'), findsNothing);
    expect(find.textContaining('Close and reopen'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
