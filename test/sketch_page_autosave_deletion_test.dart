import 'dart:async';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    SketchPage.beforeCapturedSaveOverride = null;
  });

  tearDown(() {
    SketchPage.beforeCapturedSaveOverride = null;
  });

  testWidgets('deleting a pending sketch cancels its captured autosave', (
    tester,
  ) async {
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    SketchPage.beforeCapturedSaveOverride = (_) async {
      if (!saveStarted.isCompleted) saveStarted.complete();
      await releaseSave.future;
    };
    final note = Note(title: 'Drawing');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SketchPage(note: note, sketch: SketchData()),
      ),
    );
    await tester.pump();

    final canvas = find.byType(InteractiveViewer);
    expect(canvas, findsOneWidget);
    await tester.drag(canvas, const Offset(80, 60));
    await tester.pump(const Duration(seconds: 4));
    expect(saveStarted.isCompleted, isTrue);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Sketch?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();

    releaseSave.complete();
    await tester.pumpAndSettle();

    expect(note.attachments, isEmpty);
    expect(find.byType(SketchPage), findsNothing);
  });
}
