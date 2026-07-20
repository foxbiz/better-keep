import 'dart:async';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/reminder_navigation_service.dart';
import 'package:better_keep/services/reminder_session_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const noteId = 71;
  final host = Object();
  Note? loadedNote;
  var openedRoutes = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ReminderSessionService.resetCacheForTesting();
    await ReminderSessionService.setSignedIn(true);
    await ReminderNavigationService.instance.resetForTesting();
    AppState.navigatorKey = GlobalKey<NavigatorState>();
    loadedNote = null;
    openedRoutes = 0;
    ReminderNavigationService.instance.noteLoaderOverride = (_) async {
      return loadedNote;
    };
    ReminderNavigationService.instance.routeOpenerOverride =
        (context, note) async {
          openedRoutes++;
          unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(body: Text('Opened ${note.id}')),
              ),
            ),
          );
        };
    ReminderNavigationService.instance.diagnosticsOverride = (_) async {};
  });

  tearDown(() async {
    ReminderNavigationService.instance.unregisterReadyHost(host);
    await ReminderNavigationService.instance.resetForTesting();
  });

  void provideNote({bool trashed = false}) {
    loadedNote = Note(
      id: noteId,
      title: 'Notification target',
      content: '',
      trashed: trashed,
    );
  }

  Future<void> mountNavigator(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppState.navigatorKey,
        home: const Scaffold(body: Text('Home ready')),
      ),
    );
  }

  testWidgets('tap waits for Home readiness then opens the exact note', (
    tester,
  ) async {
    provideNote();
    await ReminderNavigationService.instance.open(noteId);

    await mountNavigator(tester);
    expect(find.text('Opened $noteId'), findsNothing);

    ReminderNavigationService.instance.registerReadyHost(host);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Opened $noteId'), findsOneWidget);

    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('cold-start request survives until navigator is ready', (
    tester,
  ) async {
    provideNote();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pending_reminder_navigation_note_id', noteId);
    await prefs.setString(
      'pending_reminder_navigation_created_at',
      DateTime.now().toIso8601String(),
    );
    await ReminderNavigationService.instance.restorePending();

    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Opened $noteId'), findsOneWidget);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('signed-out request is discarded without opening content', (
    tester,
  ) async {
    provideNote();
    await ReminderSessionService.setSignedIn(false);
    await ReminderNavigationService.instance.open(noteId);

    await ReminderSessionService.setSignedIn(true);
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);
    await tester.pumpAndSettle();

    expect(find.text('Opened $noteId'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pending_reminder_navigation_note_id'), isNull);
  });

  testWidgets('missing and trashed targets are discarded', (tester) async {
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);

    await ReminderNavigationService.instance.open(noteId);
    await tester.pumpAndSettle();
    expect(find.text('Opened $noteId'), findsNothing);

    provideNote(trashed: true);
    await ReminderNavigationService.instance.open(noteId);
    await tester.pumpAndSettle();
    expect(find.text('Opened $noteId'), findsNothing);
  });

  testWidgets('expired cold-start request is discarded', (tester) async {
    provideNote();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pending_reminder_navigation_note_id', noteId);
    await prefs.setString(
      'pending_reminder_navigation_created_at',
      DateTime.now().subtract(const Duration(minutes: 11)).toIso8601String(),
    );

    await ReminderNavigationService.instance.restorePending();
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);
    await tester.pumpAndSettle();

    expect(find.text('Opened $noteId'), findsNothing);
    expect(prefs.getInt('pending_reminder_navigation_note_id'), isNull);
  });

  testWidgets('ready navigation returns without awaiting the editor route', (
    tester,
  ) async {
    provideNote();
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);

    await ReminderNavigationService.instance
        .open(noteId)
        .timeout(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(openedRoutes, 1);
    expect(find.text('Opened $noteId'), findsOneWidget);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('replayed Android launch intent is ignored per occurrence', (
    tester,
  ) async {
    provideNote();
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);

    await ReminderNavigationService.instance.openFromNotification(
      notificationId: 55,
      noteId: noteId,
      occurrenceToken: 'occurrence-one',
    );
    await tester.pumpAndSettle();
    expect(openedRoutes, 1);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    await ReminderNavigationService.instance.openFromNotification(
      notificationId: 55,
      noteId: noteId,
      occurrenceToken: 'occurrence-one',
    );
    await tester.pumpAndSettle();
    expect(openedRoutes, 1);

    await ReminderNavigationService.instance.openFromNotification(
      notificationId: 55,
      noteId: noteId,
      occurrenceToken: 'occurrence-two',
    );
    await tester.pumpAndSettle();
    expect(openedRoutes, 2);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('same recurring activation is accepted after replay window', (
    tester,
  ) async {
    provideNote();
    var now = DateTime(2026, 3, 7, 9);
    ReminderNavigationService.instance.nowOverride = () => now;
    await mountNavigator(tester);
    ReminderNavigationService.instance.registerReadyHost(host);

    Future<void> tap() async {
      await ReminderNavigationService.instance.openFromNotification(
        notificationId: 55,
        noteId: noteId,
        occurrenceToken: 'native-recurring-payload',
      );
      await tester.pumpAndSettle();
    }

    await tap();
    expect(openedRoutes, 1);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    now = now.add(const Duration(seconds: 10));
    await tap();
    expect(openedRoutes, 1);

    now = now.add(const Duration(milliseconds: 1));
    await tap();
    expect(openedRoutes, 2);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    now = now.add(const Duration(hours: 23));
    await tap();
    expect(openedRoutes, 3);
    AppState.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });
}
