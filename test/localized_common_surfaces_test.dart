import 'package:better_keep/components/app_startup_view.dart';
import 'package:better_keep/components/bubble_menu.dart';
import 'package:better_keep/components/logo.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/help_page.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, Locale locale) => MaterialApp(
    locale: locale,
    localizationsDelegates: betterKeepLocalizationDelegates,
    supportedLocales: betterKeepSupportedLocales,
    home: child,
  );

  testWidgets('help content is translated in a non-English locale', (
    tester,
  ) async {
    final ja = lookupAppLocalizations(const Locale('ja'));
    await tester.pumpWidget(host(const HelpPage(), const Locale('ja')));

    expect(find.text(ja.faqCreateNoteQuestion), findsOneWidget);
    expect(find.text('How do I create a new note?'), findsNothing);
  });

  testWidgets('startup failure and logo accessibility label are localized', (
    tester,
  ) async {
    final ja = lookupAppLocalizations(const Locale('ja'));
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: Column(
            children: [
              LogoImage(),
              Expanded(child: AppStartupErrorView()),
            ],
          ),
        ),
        const Locale('ja'),
      ),
    );

    expect(find.text(ja.unableToStartApp), findsOneWidget);
    expect(find.bySemanticsLabel(ja.appLogoSemantics), findsOneWidget);
    expect(find.textContaining('Firebase'), findsNothing);
  });

  testWidgets('floating create menu localizes Todo in Japanese', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => BubbleMenu(
            items: [
              BubbleMenuItem(
                icon: Icons.check_box_outlined,
                label: context.l10n.todo,
                onTap: () {},
              ),
            ],
          ),
        ),
        const Locale('ja'),
      ),
    );

    expect(find.text('タスク'), findsOneWidget);
    expect(find.text('Todo'), findsNothing);
  });
}
