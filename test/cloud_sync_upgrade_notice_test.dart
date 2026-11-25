import 'dart:async';

import 'package:better_keep/components/cloud_sync_upgrade_notice.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const message = 'Your changes are saved here. Sync them with Pro.';
  late ValueNotifier<int> changes;
  late String? eligibleAccount;
  late bool pending;
  late int reads;
  late int upgrades;
  late Future<bool> Function() read;

  setUp(() {
    CloudSyncUpgradeNotice.resetSessionDismissals();
    changes = ValueNotifier(0);
    eligibleAccount = 'owner';
    pending = true;
    reads = upgrades = 0;
    read = () async {
      reads++;
      return pending;
    };
  });
  tearDown(() => changes.dispose());

  Future<void> mount(
    WidgetTester tester, {
    bool visible = true,
    Locale locale = const Locale('en'),
    double textScale = 1,
    TargetPlatform platform = TargetPlatform.android,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: platform,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            CloudSyncUpgradeNotice(
              visible: visible,
              changes: changes,
              eligibleAccount: () => eligibleAccount,
              hasPendingChanges: () => read(),
              onUpgrade: () => upgrades++,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> check(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  testWidgets('pending changes show one quiet action, with no polling', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text(message), findsNothing);
    await check(tester);
    expect(find.text(message), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 1);
    await tester.tap(find.text('Upgrade'));
    expect(upgrades, 1);
    await check(tester);
    pending = false;
    changes.value++;
    await check(tester);
    expect(find.text(message), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ineligible or signed-out accounts never read or show pending work',
    (tester) async {
      eligibleAccount = null;
      await mount(tester);
      await check(tester);
      expect(reads, 0);
      expect(find.text(message), findsNothing);
      eligibleAccount = 'owner';
      changes.value++;
      await check(tester);
      expect(find.text(message), findsOneWidget);
      // Upgrade, provider switch, or sign-out hides immediately.
      eligibleAccount = null;
      changes.value++;
      await tester.pump();
      expect(find.text(message), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late results cannot leak across accounts or replace newer state',
    (tester) async {
      final first = Completer<bool>();
      final second = Completer<bool>();
      read = () => first.future;
      await mount(tester);
      await check(tester);
      eligibleAccount = 'other';
      read = () => second.future;
      changes.value++;
      await check(tester);
      second.complete(false);
      await tester.pump();
      first.complete(true);
      await tester.pump();
      expect(find.text(message), findsNothing);
      read = () => Future.error(StateError('local data not ready'));
      changes.value++;
      await check(tester);
      expect(find.text(message), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('hidden while searching or selecting, without a new prompt', (
    tester,
  ) async {
    await mount(tester);
    await check(tester);
    expect(find.text(message), findsOneWidget);
    await mount(tester, visible: false);
    expect(find.text(message), findsNothing);
    await mount(tester);
    expect(find.text(message), findsOneWidget);
    expect(reads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('dismissal lasts across navigation and edits on $platform', (
      tester,
    ) async {
      await mount(tester, platform: platform);
      await check(tester);
      final mobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      if (mobile) {
        expect(find.byTooltip('Dismiss'), findsNothing);
        await tester.drag(
          find.byType(Dismissible),
          Offset(platform == TargetPlatform.iOS ? -700 : 700, 0),
        );
      } else {
        expect(find.byType(Dismissible), findsNothing);
        await tester.tap(find.byTooltip('Dismiss'));
      }
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      // Leaving the page and returning must not reset this session preference.
      await tester.pumpWidget(const SizedBox());
      await mount(tester, platform: platform);
      changes.value++;
      await check(tester);
      expect(find.text(message), findsNothing);
      expect(reads, 1);
      // A different account has its own dismissal state.
      eligibleAccount = 'other';
      changes.value++;
      await check(tester);
      expect(find.text(message), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      // A new app session makes the reminder eligible again.
      CloudSyncUpgradeNotice.resetSessionDismissals();
      eligibleAccount = 'owner';
      await mount(tester, platform: platform);
      await check(tester);
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('fits narrow layout with large ${locale.languageCode} text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await mount(
        tester,
        locale: locale,
        textScale: 2,
        platform: TargetPlatform.macOS,
      );
      await check(tester);
      expect(tester.takeException(), isNull);
      final action = tester.getRect(find.byType(TextButton));
      expect(action.left, greaterThanOrEqualTo(12));
      expect(action.right, lessThanOrEqualTo(308));
      // Desktop uses Flutter’s compact 40px target; mobile keeps padded targets.
      expect(action.height, greaterThanOrEqualTo(40));
      expect(
        find.byTooltip(lookupAppLocalizations(locale).dismiss),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
