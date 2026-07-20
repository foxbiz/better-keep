import 'dart:async';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/due_reminder_presenter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Note note;
  late DueReminderPresenter presenter;
  late BuildContext editorContext;

  setUp(() {
    note = Note(
      id: 91,
      title: 'Private note title',
      reminder: Reminder(
        dateTime: DateTime.now().subtract(const Duration(minutes: 1)),
        type: ReminderType.notification,
      ),
    );
    presenter = DueReminderPresenter.forTesting(loadNote: (_) async => note);
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            editorContext = context;
            return const Scaffold(body: Center(child: Text('Editor')));
          },
        ),
      ),
    );
  }

  Future<void> showOverdue(
    WidgetTester tester, {
    required Set<String> shownOccurrences,
    required Future<bool> Function() onMarkDone,
  }) async {
    unawaited(
      presenter.showIfDue(
        note: note,
        shownOccurrences: shownOccurrences,
        onMarkDone: onMarkDone,
        context: editorContext,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows short overdue decision without note title or time', (
    tester,
  ) async {
    await pumpHost(tester);

    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async => true,
    );

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Overdue reminder'), findsOneWidget);
    expect(
      find.text('This reminder is overdue. Mark it as done now?'),
      findsOneWidget,
    );
    expect(find.text(note.title!), findsNothing);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Mark as Done'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
  });

  testWidgets('Not now suppresses the occurrence for this editor session', (
    tester,
  ) async {
    await pumpHost(tester);
    final shown = <String>{};
    var completions = 0;

    await showOverdue(
      tester,
      shownOccurrences: shown,
      onMarkDone: () async {
        completions++;
        return true;
      },
    );
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    await showOverdue(
      tester,
      shownOccurrences: shown,
      onMarkDone: () async {
        completions++;
        return true;
      },
    );

    expect(find.byType(AlertDialog), findsNothing);
    expect(completions, 0);
  });

  testWidgets('barrier dismissal also suppresses the current occurrence', (
    tester,
  ) async {
    await pumpHost(tester);
    final shown = <String>{};

    await showOverdue(
      tester,
      shownOccurrences: shown,
      onMarkDone: () async => true,
    );
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await showOverdue(
      tester,
      shownOccurrences: shown,
      onMarkDone: () async => true,
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Mark as Done disables duplicate actions and closes on success', (
    tester,
  ) async {
    await pumpHost(tester);
    final completion = Completer<bool>();
    var completions = 0;
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () {
        completions++;
        return completion.future;
      },
    );

    await tester.tap(find.text('Mark as Done'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100 && completions == 0; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    final action = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Mark as Done'),
        matching: find.byType(TextButton),
      ),
    );
    expect(action.onPressed, isNull);
    expect(completions, 1);

    completion.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('genuine completion failure stays open and supports retry', (
    tester,
  ) async {
    await pumpHost(tester);
    var shouldSucceed = false;
    var completions = 0;
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async {
        completions++;
        return shouldSucceed;
      },
    );

    await tester.tap(find.text('Mark as Done'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Couldn’t mark this reminder as done. Please try again.'),
      findsOneWidget,
    );

    shouldSucceed = true;
    await tester.tap(find.text('Mark as Done'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(completions, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('revalidates a stale occurrence before completing', (
    tester,
  ) async {
    await pumpHost(tester);
    var completions = 0;
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async {
        completions++;
        return true;
      },
    );

    note.completed = true;
    await tester.tap(find.text('Mark as Done'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(completions, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('external completion dismisses the open dialog', (tester) async {
    await pumpHost(tester);
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async => true,
    );

    note.completed = true;
    note.notify('updated', false);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('action completion event dismisses only the dialog', (
    tester,
  ) async {
    await pumpHost(tester);
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async {
        note.completed = true;
        note.notify('updated', false);
        return true;
      },
    );

    await tester.tap(find.text('Mark as Done'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Editor'), findsOneWidget);
  });

  testWidgets('all-day reminder is overdue only after its day ends', (
    tester,
  ) async {
    await pumpHost(tester);
    final now = DateTime.now();
    note.reminder = Reminder(dateTime: now, isAllDay: true);

    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async => true,
    );
    expect(find.byType(AlertDialog), findsNothing);

    note.reminder = Reminder(
      dateTime: DateTime(now.year, now.month, now.day - 1, 18),
      isAllDay: true,
    );
    await showOverdue(
      tester,
      shownOccurrences: <String>{},
      onMarkDone: () async => true,
    );

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('All day'), findsNothing);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
  });

  testWidgets('does not stack over another active modal', (tester) async {
    await pumpHost(tester);
    unawaited(
      showDialog<void>(
        context: editorContext,
        builder: (_) => const AlertDialog(title: Text('Existing modal')),
      ),
    );
    await tester.pumpAndSettle();
    final shown = <String>{};

    await showOverdue(
      tester,
      shownOccurrences: shown,
      onMarkDone: () async => true,
    );

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Existing modal'), findsOneWidget);
    expect(find.text('Overdue reminder'), findsNothing);
    expect(shown, isEmpty);

    Navigator.of(editorContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();
  });
}
