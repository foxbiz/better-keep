import 'package:better_keep/components/note_display_options_button.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/pages/home/home.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  final sortService = NoteSortService();

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sortService.dispose();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    AppState.selectedNotes = [];
    AppState.currentFolder = null;
    AppState.set('notes_view_mode', NoteViewMode.grid);
    await Note.createTable(database);
    await Label.createTable(database);
    await NoteSortService.createTable(database);
    await sortService.init();
    for (final type in [
      NoteType.archived,
      NoteType.reminder,
      NoteType.trashed,
    ]) {
      await sortService.ensureContext(
        NoteOrderContext.system(type.name),
        visibleNotes: const <Note>[],
      );
    }
  });

  tearDown(() async {
    AppState.selectedNotes = [];
    AppState.showNotes = NoteType.all;
    await sortService.dispose();
    await database.close();
  });

  testWidgets('system tabs end every app bar with their configure button', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cases = [
      (NoteType.archived, 'Archive'),
      (NoteType.reminder, 'Reminders'),
      (NoteType.trashed, 'Trash'),
    ];

    for (final width in [600.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      for (final (type, label) in cases) {
        AppState.showNotes = type;
        await tester.pumpWidget(_app(const Home()));
        await _drainDatabaseWork(tester);

        final appBar = find.byType(AppBar);
        expect(
          find.descendant(of: appBar, matching: find.text(label)),
          findsOneWidget,
          reason: '$label should be visible at width $width',
        );
        expect(
          find.descendant(
            of: appBar,
            matching: find.byKey(const ValueKey('note-display-options-button')),
          ),
          findsOneWidget,
          reason: '$label should configure sorting from the app bar',
        );
        expect(find.byType(SliverPersistentHeader), findsNothing);

        final appBarWidget = tester.widget<AppBar>(appBar);
        expect(appBarWidget.actions, isNotEmpty);
        expect(
          appBarWidget.actions!.last,
          isA<NoteDisplayOptionsButton>(),
          reason: '$label should keep configure at the trailing edge',
        );
        if (type == NoteType.trashed) {
          final deleteAction =
              appBarWidget.actions![appBarWidget.actions!.length - 2]
                  as IconButton;
          expect((deleteAction.icon as Icon).icon, Icons.delete_forever);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await _drainDatabaseWork(tester);
      }
    }
  });

  testWidgets('system configure stays sort-only and hides during selection', (
    tester,
  ) async {
    AppState.showNotes = NoteType.archived;
    await tester.pumpWidget(_app(const Home()));
    await _drainDatabaseWork(tester);

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RadioListTile<NoteViewMode>), findsNothing);
    expect(find.byType(RadioListTile<NoteSortMode>), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsNothing,
    );
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final archiveContext = NoteOrderContext.system('archived');
    final archiveSnapshot = sortService.snapshotFor(archiveContext);
    sortService.snapshots.value = Map.unmodifiable({
      ...sortService.snapshots.value,
      archiveContext.key: archiveSnapshot.copyWith(
        mode: NoteSortMode.createdNewest,
      ),
    });
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsOneWidget,
    );

    AppState.selectedNotes = [Note(id: 1, title: 'Selected')];
    await tester.pump();

    expect(
      find.byKey(const ValueKey('note-display-options-button')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainDatabaseWork(tester);
  });
}

Future<void> _drainDatabaseWork(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 250)),
  );
  await tester.pump();
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: home,
);
