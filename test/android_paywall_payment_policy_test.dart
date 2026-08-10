import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/services/monetization/purchase_provider.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/ui/paywall/paywall_sheet.dart';
import 'package:better_keep/ui/paywall/purchase_feedback_listener.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SubscriptionService.instance.storeReadiness.value =
        StoreReadiness.unavailable;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      SubscriptionService.instance.dispose();
    });
  });

  testWidgets('Android paywall never renders Razorpay pricing controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        home: Scaffold(body: PaywallSheet()),
      ),
    );
    await tester.pump();

    expect(SubscriptionService.instance.usesRazorpay, isFalse);
    expect(find.byType(PurchaseFeedbackListener), findsOneWidget);
    expect(
      find.byKey(const ValueKey('razorpay-currency-selector')),
      findsNothing,
    );
    expect(find.textContaining('USD'), findsNothing);
    expect(find.textContaining('INR'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final paywall in <String, Widget>{
    'sheet': const PaywallSheet(),
    'page': const PaywallPage(),
  }.entries) {
    testWidgets(
      'Android ${paywall.key} loading transitions do not present purchase errors',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: betterKeepLocalizationDelegates,
            supportedLocales: betterKeepSupportedLocales,
            home: Scaffold(body: paywall.value),
          ),
        );
        await tester.pump();

        SubscriptionService.instance.isLoading.value = true;
        await tester.pump();
        SubscriptionService.instance.isLoading.value = false;
        await tester.pump();

        expect(find.byType(PurchaseFeedbackListener), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
