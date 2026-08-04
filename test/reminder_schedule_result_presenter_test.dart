import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_schedule_result_presenter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BuildContext hostContext;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  ReminderUpdateResult result(
    ReminderDeliveryState state, {
    ReminderType type = ReminderType.notification,
    int rowId = 1,
    ReminderDeliveryReason? reason,
  }) => ReminderUpdateResult(
    rowId: rowId,
    savedReminder: rowId < 0
        ? null
        : Reminder(dateTime: DateTime(2026, 7, 20, 10), type: type),
    delivery: ReminderScheduleResult(state, reason: reason),
  );

  testWidgets('shows localized scheduled feedback', (tester) async {
    await pumpHost(tester);
    final presenter = ReminderScheduleResultPresenter.forTesting(
      openSystemSettings: () async => true,
    );

    presenter.show(hostContext, result(ReminderDeliveryState.scheduled));
    await tester.pump();

    expect(find.text('Reminder set'), findsOneWidget);
  });

  testWidgets('uses the saved reminder type for unsupported feedback', (
    tester,
  ) async {
    await pumpHost(tester);
    final presenter = ReminderScheduleResultPresenter.forTesting(
      openSystemSettings: () async => true,
    );

    presenter.show(
      hostContext,
      result(ReminderDeliveryState.unsupported, type: ReminderType.alarm),
    );
    await tester.pump();
    expect(
      find.textContaining('Alarms are not supported on this platform'),
      findsOneWidget,
    );

    presenter.show(hostContext, result(ReminderDeliveryState.unsupported));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Scheduled notifications are not available'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Alarms are not supported on this platform'),
      findsNothing,
    );
  });

  testWidgets('permission feedback exposes one safe Settings action', (
    tester,
  ) async {
    await pumpHost(tester);
    var settingsCalls = 0;
    final presenter = ReminderScheduleResultPresenter.forTesting(
      openSystemSettings: () async {
        settingsCalls++;
        throw StateError('platform rejected settings launch');
      },
    );

    presenter.show(hostContext, result(ReminderDeliveryState.permissionDenied));
    await tester.pump();
    expect(
      find.text(
        'Reminder saved, but permission is required to schedule it on this device.',
      ),
      findsOneWidget,
    );

    tester.widget<SnackBar>(find.byType(SnackBar)).action!.onPressed();
    await tester.pump();
    expect(settingsCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed feedback maps a stable reason to localized guidance', (
    tester,
  ) async {
    await pumpHost(tester);
    final presenter = ReminderScheduleResultPresenter.forTesting(
      openSystemSettings: () async => true,
    );

    presenter.show(
      hostContext,
      result(
        ReminderDeliveryState.failed,
        reason: ReminderDeliveryReason.timeZoneUnavailable,
      ),
    );
    await tester.pump();

    expect(
      find.text(
        "Reminder saved, but this device's timezone could not be resolved. Check the device time settings and try again.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not show stale or unpersisted feedback', (tester) async {
    await pumpHost(tester);
    final presenter = ReminderScheduleResultPresenter.forTesting(
      openSystemSettings: () async => true,
    );

    presenter.show(hostContext, result(ReminderDeliveryState.superseded));
    presenter.show(
      hostContext,
      result(ReminderDeliveryState.scheduled, rowId: -1),
    );
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });
}
