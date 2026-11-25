import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/ui/paywall/paywall_sheet.dart';
import 'package:better_keep/ui/paywall/subscription_purchase_options.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final textScale in [1.0, 1.6]) {
    testWidgets(
      'compares all plans and groups plan/pricing choices at text scale $textScale',
      (tester) async {
        // Desktop pricing is local, so this exercises real tier/period pricing
        // without contacting an app store or starting a purchase.
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final service = SubscriptionService.instance;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          service.dispose();
        });
        final l10n = lookupAppLocalizations(const Locale('en'));
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: betterKeepLocalizationDelegates,
            supportedLocales: betterKeepSupportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPaywall(context),
                  child: Text(l10n.upgrade),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text(l10n.upgrade));
        await tester.pumpAndSettle();
        final selector = find.byType(SegmentedButton<UserPlan>);
        expect(selector, findsOneWidget);
        expect(find.text(l10n.choosePlan), findsOneWidget);
        expect(find.text(l10n.planFree), findsOneWidget);
        expect(find.text(l10n.lite), findsNWidgets(2));
        expect(find.text(l10n.pro), findsNWidgets(2));

        void expectComparison() {
          final cloudRow = find
              .ancestor(
                of: find.text(l10n.builtInCloudSync),
                matching: find.byType(Row),
              )
              .first;
          expect(
            find.descendant(
              of: cloudRow,
              matching: find.byIcon(Icons.check_circle),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: cloudRow,
              matching: find.byIcon(Icons.remove_circle_outline),
            ),
            findsNWidgets(2),
          );
          expect(find.text('5'), findsNWidgets(2));
          expect(find.text(l10n.lockedNotesFreeLimit), findsNothing);
        }

        expectComparison();
        expect(
          tester.getBottomLeft(find.text(l10n.lockedNotes)).dy,
          lessThan(tester.getTopLeft(selector).dy),
        );
        expect(
          tester.getBottomLeft(selector).dy,
          lessThan(tester.getTopLeft(find.text(l10n.monthly)).dy),
        );

        for (final plan in [UserPlan.lite, UserPlan.pro]) {
          await tester.ensureVisible(selector);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: selector,
              matching: find.text(plan.localizedDisplayName(l10n)),
            ),
          );
          await tester.pumpAndSettle();
          expectComparison();
          final options = tester.widget<SubscriptionPurchaseOptions>(
            find.byType(SubscriptionPurchaseOptions),
          );
          expect(
            options.monthlyPrice,
            service.getDisplayPrice(yearly: false, plan: plan),
          );
          expect(
            options.yearlyPrice,
            service.getDisplayPrice(yearly: true, plan: plan),
          );
          expect(
            options.savePercentage,
            service.calculateSavePercentage(plan: plan),
          );
        }
        expect(find.text(l10n.unlimited), findsNothing);
        expect(find.byIcon(Icons.all_inclusive), findsNWidgets(4));
        expect(find.byTooltip(l10n.unlimited), findsNWidgets(4));
        expect(find.text(l10n.noAdsDescription), findsNothing);
        expect(find.byIcon(Icons.rocket_launch), findsNothing);
        expect(
          find.widgetWithText(FilledButton, l10n.subscribe),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets(
    'period selection only purchases on Subscribe and locks during checkout',
    (tester) async {
      final periods = <bool>[];
      var busy = false;
      final l10n = lookupAppLocalizations(const Locale('en'));
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Center(
                  child: SizedBox(
                    width: 342,
                    child: SubscriptionPurchaseOptions(
                      monthlyPrice: r'$2.99',
                      yearlyPrice: r'$19.99',
                      savePercentage: 44,
                      isBusy: busy,
                      progressLabel: l10n.processingSubscription,
                      onSubscribe: (yearly) {
                        periods.add(yearly);
                        setState(() => busy = true);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final selector = find.byType(SegmentedButton<bool>);
      final subscribe = find.byType(FilledButton);
      expect(find.text(r'$19.99'), findsOneWidget);
      expect(find.text(l10n.savePercent(44)), findsOneWidget);
      expect(
        tester.getBottomLeft(selector).dy,
        lessThan(tester.getTopLeft(subscribe).dy),
      );

      await tester.tap(find.text(l10n.monthly));
      await tester.pumpAndSettle();
      expect(periods, isEmpty);
      expect(find.text(r'$2.99'), findsOneWidget);
      expect(find.text(r'$19.99'), findsNothing);
      expect(find.text(l10n.savePercent(44)), findsNothing);
      await tester.tap(find.text(l10n.subscribe));
      await tester.pump();
      expect(periods, [false]);
      expect(tester.widget<FilledButton>(subscribe).onPressed, isNull);
      expect(
        tester.widget<SegmentedButton<bool>>(selector).onSelectionChanged,
        isNull,
      );
      expect(find.text(l10n.processingSubscription), findsOneWidget);
      await tester.tap(subscribe);
      expect(periods, [false]);

      update(() => busy = false);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.yearly));
      await tester.pumpAndSettle();
      expect(periods, [false]);
      expect(find.text(r'$19.99'), findsOneWidget);
      await tester.tap(find.text(l10n.subscribe));
      await tester.pump();
      expect(periods, [false, true]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
