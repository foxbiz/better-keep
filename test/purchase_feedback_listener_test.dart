import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/monetization/purchase_feedback.dart';
import 'package:better_keep/ui/paywall/purchase_feedback_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ignores stale events and presents a new failure only once', (
    tester,
  ) async {
    final events = ValueNotifier<PurchaseEvent?>(
      const PurchaseEvent(id: 1, attemptId: 1, outcome: PurchaseOutcome.failed),
    );
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_TestApp(events: events));

    expect(find.text(l10n.somethingWentWrongTryAgain), findsNothing);

    events.value = null;
    await tester.pump();
    events.value = const PurchaseEvent(
      id: 2,
      attemptId: 2,
      outcome: PurchaseOutcome.failed,
    );
    await tester.pump();

    expect(find.text(l10n.somethingWentWrongTryAgain), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    events.value = const PurchaseEvent(
      id: 2,
      attemptId: 2,
      outcome: PurchaseOutcome.failed,
    );
    await tester.pump();

    expect(find.text(l10n.somethingWentWrongTryAgain), findsNothing);
  });

  testWidgets('presents cancellation as neutral feedback', (tester) async {
    final events = ValueNotifier<PurchaseEvent?>(null);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_TestApp(events: events));
    events.value = const PurchaseEvent(
      id: 1,
      attemptId: 1,
      outcome: PurchaseOutcome.cancelled,
    );
    await tester.pump();

    expect(find.text(l10n.purchaseCancelled), findsOneWidget);
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, isNull);
  });

  testWidgets('presents one non-dismissible activation success dialog', (
    tester,
  ) async {
    final events = ValueNotifier<PurchaseEvent?>(null);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_TestApp(events: events));
    events.value = const PurchaseEvent(
      id: 1,
      attemptId: 1,
      outcome: PurchaseOutcome.activated,
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.welcomeToProMessage), findsOneWidget);
    expect(find.text(l10n.subscriptionActivated), findsOneWidget);
    expect(find.text(l10n.continue_), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text(l10n.welcomeToProMessage), findsOneWidget);

    events.value = const PurchaseEvent(
      id: 1,
      attemptId: 1,
      outcome: PurchaseOutcome.activated,
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('activation pending warns against another purchase', (
    tester,
  ) async {
    final events = ValueNotifier<PurchaseEvent?>(null);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_TestApp(events: events));
    events.value = const PurchaseEvent(
      id: 1,
      attemptId: 1,
      outcome: PurchaseOutcome.activationPending,
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.paymentConfirmedTitle), findsOneWidget);
    expect(find.text(l10n.paymentConfirmedActivationPending), findsOneWidget);
    expect(find.text(l10n.recheckStatus), findsOneWidget);
    expect(find.text(l10n.manageSubscription), findsOneWidget);
  });

  testWidgets('ownership conflict never presents success feedback', (
    tester,
  ) async {
    final events = ValueNotifier<PurchaseEvent?>(null);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await tester.pumpWidget(_TestApp(events: events));
    events.value = const PurchaseEvent(
      id: 1,
      attemptId: 1,
      outcome: PurchaseOutcome.ownershipConflict,
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.subscriptionAccountMismatchTitle), findsOneWidget);
    expect(find.text(l10n.subscriptionAccountMismatchMessage), findsOneWidget);
    expect(find.text(l10n.welcomeToProMessage), findsNothing);
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.events});

  final ValueNotifier<PurchaseEvent?> events;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: Scaffold(
        body: PurchaseFeedbackListener(
          events: events,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
