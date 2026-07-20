import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Finder fieldWithLabel(String label) {
    return find.byWidgetPredicate(
      (widget) =>
          widget is InputDecorator && widget.decoration.labelText == label,
    );
  }

  DropdownButton<ReminderType> reminderTypeDropdown(WidgetTester tester) {
    return tester.widget<DropdownButton<ReminderType>>(
      find.byType(DropdownButton<ReminderType>),
    );
  }

  Future<void> selectReminderType(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButton<ReminderType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    Reminder? initialReminder,
    Locale? locale,
    TextScaler textScaler = TextScaler.noScaling,
    bool? alwaysUse24HourFormat,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: textScaler,
            alwaysUse24HourFormat: alwaysUse24HourFormat,
          ),
          child: child!,
        ),
        home: Scaffold(body: DatetimePicker(initialReminder: initialReminder)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('new reminders use labeled outlined fields and default values', (
    tester,
  ) async {
    await pumpDialog(tester);

    expect(reminderTypeDropdown(tester).value, ReminderType.notification);
    final fields = [
      fieldWithLabel('Reminder type'),
      fieldWithLabel('Date'),
      fieldWithLabel('Time'),
    ];
    for (final field in fields) {
      expect(field, findsOneWidget);
      final decorator = tester.widget<InputDecorator>(field);
      expect(
        decorator.decoration.floatingLabelBehavior,
        FloatingLabelBehavior.always,
      );
      expect(decorator.decoration.border, isA<OutlineInputBorder>());
    }
    expect(
      fields.map((field) => tester.getSize(field).width).toSet(),
      hasLength(1),
    );

    final context = tester.element(find.byType(DatetimePicker));
    final today = MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.now());
    expect(find.text('Notification'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text(today), findsOneWidget);
    expect(
      tester.getCenter(find.text(today)).dy,
      greaterThan(tester.getCenter(find.text('Today')).dy),
    );
    expect(find.text('Select time'), findsOneWidget);
  });

  testWidgets('editing an alarm preserves alarm selection', (tester) async {
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime.now().add(const Duration(days: 1)),
        type: ReminderType.alarm,
      ),
    );

    expect(reminderTypeDropdown(tester).value, ReminderType.alarm);
  });

  testWidgets('alarm can be converted to notification without a device check', (
    tester,
  ) async {
    Reminder? selected;
    final initial = Reminder(
      dateTime: DateTime.now().add(const Duration(days: 1)),
      type: ReminderType.alarm,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selected = await reminder(context, initialReminder: initial);
              },
              child: const Text('Open reminder'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open reminder'));
    await tester.pumpAndSettle();
    await selectReminderType(tester, 'Notification');
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();

    expect(selected?.type, ReminderType.notification);
  });

  testWidgets('notification can be converted to alarm', (tester) async {
    Reminder? selected;
    final initial = Reminder(
      dateTime: DateTime.now().add(const Duration(days: 1)),
      type: ReminderType.notification,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selected = await reminder(context, initialReminder: initial);
              },
              child: const Text('Open reminder'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open reminder'));
    await tester.pumpAndSettle();
    await selectReminderType(tester, 'Alarm');
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();

    expect(selected?.type, ReminderType.alarm);
  });

  testWidgets('alarm selection removes All day and requires a time', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime.now().add(const Duration(days: 1)),
        type: ReminderType.notification,
        isAllDay: true,
      ),
    );

    await selectReminderType(tester, 'Alarm');

    final dropdowns = tester.widgetList<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    final timeDropdown = dropdowns.last;
    expect(
      timeDropdown.items!.map((item) => item.value),
      isNot(contains('All Day')),
    );

    final ok = tester.widget<TextButton>(find.widgetWithText(TextButton, 'OK'));
    expect(ok.onPressed, isNull);
  });

  testWidgets('custom date displays its localized option and value', (
    tester,
  ) async {
    final customDate = DateTime.now().add(const Duration(days: 10));
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime(
          customDate.year,
          customDate.month,
          customDate.day,
          9,
          30,
        ),
      ),
    );

    final context = tester.element(find.byType(DatetimePicker));
    final formattedDate = MaterialLocalizations.of(
      context,
    ).formatMediumDate(customDate);
    expect(find.text('Custom'), findsWidgets);
    expect(find.text(formattedDate), findsOneWidget);
  });

  testWidgets('preset time displays its localized option and value', (
    tester,
  ) async {
    final now = DateTime.now();
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime(
          now.year,
          now.month,
          now.day,
          AppState.morningTime.hour,
          AppState.morningTime.minute,
        ),
      ),
    );

    final context = tester.element(find.byType(DatetimePicker));
    expect(find.text('Morning'), findsOneWidget);
    expect(find.text(AppState.morningTime.format(context)), findsOneWidget);
  });

  testWidgets('All day displays only its localized option', (tester) async {
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime.now().add(const Duration(days: 1)),
        type: ReminderType.notification,
        isAllDay: true,
      ),
    );

    expect(find.text('All day'), findsOneWidget);
    expect(find.text('All Day'), findsNothing);
    final context = tester.element(find.byType(DatetimePicker));
    expect(find.text(AppState.morningTime.format(context)), findsNothing);
  });

  testWidgets('Custom time never leaks into All day and is discarded', (
    tester,
  ) async {
    Reminder? selected;
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final initial = Reminder(
      dateTime: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 11, 42),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selected = await reminder(context, initialReminder: initial);
              },
              child: const Text('Open reminder'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open reminder'));
    await tester.pumpAndSettle();

    final pickerContext = tester.element(find.byType(DatetimePicker));
    final customTime = const TimeOfDay(
      hour: 11,
      minute: 42,
    ).format(pickerContext);
    expect(find.text(customTime), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    // One copy is the selected field and one belongs to the Custom menu item.
    // All day must not acquire a third copy as its secondary value.
    expect(find.text(customTime), findsNWidgets(2));

    await tester.tap(find.text('All day').last);
    await tester.pumpAndSettle();
    expect(find.text('All day'), findsOneWidget);
    expect(find.text(customTime), findsNothing);

    final ok = tester.widget<TextButton>(find.widgetWithText(TextButton, 'OK'));
    expect(ok.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();

    expect(selected?.isAllDay, isTrue);
    expect(selected?.dateTime.hour, 0);
    expect(selected?.dateTime.minute, 0);
    expect(selected?.type, ReminderType.notification);
  });

  testWidgets('repeat mode replaces Date with a labeled Frequency field', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime.now().add(const Duration(days: 1)),
        repeat: Reminder.repeatDaily,
      ),
    );

    expect(fieldWithLabel('Frequency'), findsOneWidget);
    expect(fieldWithLabel('Date'), findsNothing);
    expect(find.text('Daily'), findsOneWidget);
  });

  testWidgets('custom time respects the device 24-hour format', (tester) async {
    final now = DateTime.now();
    await pumpDialog(
      tester,
      alwaysUse24HourFormat: true,
      initialReminder: Reminder(
        dateTime: DateTime(now.year, now.month, now.day, 21, 5),
      ),
    );

    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('21:05'), findsOneWidget);
  });

  testWidgets('cancelling custom pickers preserves date and time selections', (
    tester,
  ) async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    await pumpDialog(
      tester,
      initialReminder: Reminder(
        dateTime: DateTime(
          tomorrow.year,
          tomorrow.month,
          tomorrow.day,
          AppState.morningTime.hour,
          AppState.morningTime.minute,
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom').last);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>).first,
          )
          .value,
      Reminder.tomorrow,
    );

    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom').last);
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byType(DropdownButton<String>).last,
          )
          .value,
      Reminder.morning,
    );
  });

  testWidgets('date and time menu options are localized', (tester) async {
    await pumpDialog(tester, locale: const Locale('pt'));

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Próximo mês'), findsOneWidget);
    await tester.tap(find.text('Próximo mês'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Dia inteiro'), findsOneWidget);
  });

  testWidgets(
    'outlined dropdowns keep full localized labels on narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpDialog(
        tester,
        locale: const Locale('pt'),
        textScaler: const TextScaler.linear(1.2),
      );

      expect(find.byType(SegmentedButton<ReminderType>), findsNothing);
      final fields = [
        fieldWithLabel('Tipo de lembrete'),
        fieldWithLabel('Data'),
        fieldWithLabel('Hora'),
      ];
      for (final field in fields) {
        expect(field, findsOneWidget);
        expect(
          tester.widget<InputDecorator>(field).decoration.border,
          isA<OutlineInputBorder>(),
        );
      }
      expect(find.text('Notificação'), findsOneWidget);
      expect(tester.widget<Text>(find.text('Notificação')).overflow, isNull);

      await tester.ensureVisible(find.byType(DropdownButton<ReminderType>));
      await tester.tap(find.byType(DropdownButton<ReminderType>));
      await tester.pumpAndSettle();

      expect(find.text('Notificação'), findsWidgets);
      expect(find.text('Alarme'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dialog stays compact on wide displays', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => reminder(context),
              child: const Text('Open reminder'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open reminder'));
    await tester.pumpAndSettle();

    final dialogSurface = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.type == MaterialType.card,
      ),
    );
    expect(dialogSurface, findsOneWidget);
    expect(tester.getSize(dialogSurface).width, lessThanOrEqualTo(440));
    expect(tester.takeException(), isNull);
  });
}
