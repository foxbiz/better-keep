import 'dart:async';

import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/note_display_options_button.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/pages/home/labels.dart';
import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late SharedPreferences preferences;
  final sort = NoteSortService();

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    await sort.dispose();
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    await AppState.init(prefs: preferences);
    AppState.set('notes_view_mode', NoteViewMode.grid);
    AppState.currentFolder = null;
    AppState.showNotes = NoteType.all;
    AppState.selectedNotes = [];
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await Note.createTable(database);
    await Label.createTable(database);
    NoteSortService.canPushCloudOverride = false;
    NoteSortService.canReceiveCloudOverride = false;
    await sort.init();
  });
  tearDown(() async {
    AppState.db = database;
    await sort.dispose();
    await database.close();
    NoteSortService.canPushCloudOverride = null;
    NoteSortService.canReceiveCloudOverride = null;
    NoteSyncService.refreshOperationOverride = null;
    LabelSyncService.refreshOperationOverride = null;
  });

  test('450 notes match all or any labels with consistent counts', () async {
    var id = 0;
    for (final (labels, count) in [
      ('2024,Работа', 100),
      ('Личное,2024', 100),
      ('Работа,2023', 100),
      ('2023,Личное', 100),
      ('', 50),
    ]) {
      for (var index = 0; index < count; index++) {
        await _insertNote(database, ++id, labels);
      }
    }
    for (final (labels, allCount, anyCount) in [
      (<String>[], 450, 450),
      (['Работа'], 200, 200),
      (['2024', 'Работа'], 100, 300),
      ([' 2024 ', 'Работа', 'Работа', ' '], 100, 300),
      (['2024', 'Unknown'], 0, 200),
      (['работа'], 0, 0),
    ]) {
      for (final strict in [true, false]) {
        final expected = strict ? allCount : anyCount;
        expect(
          await Note.get(NoteType.all, labels, null, strict),
          hasLength(expected),
        );
        expect(await Note.count(NoteType.all, labels, null, strict), expected);
        expect(
          await Note.filterByLabels(labels, matchAllLabels: strict),
          hasLength(expected),
        );
        expect(
          await Note.countByLabels(labels, matchAllLabels: strict),
          expected,
        );
      }
    }
    expect(await Note.get(NoteType.all, ['2024', 'Работа']), hasLength(100));
    expect(await Note.filterByLabels(null), hasLength(50));
    expect(await Note.countByLabels(null), 50);
  });

  test(
    'SQL and live matching agree on whitespace, duplicates and exact names',
    () async {
      final notes = [
        await _insertNote(database, 1, '\t2024\u00a0, Работа ,Работа'),
        await _insertNote(database, 2, '2024,Работа-extra'),
        await _insertNote(database, 3, '2024,работа'),
        await _insertNote(database, 4, '2024'),
      ];
      for (final strict in [true, false]) {
        final selected = [' 2024 ', 'Работа', 'Работа'];
        final matches = await Note.filterByLabels(
          selected,
          matchAllLabels: strict,
        );
        expect(
          matches.map((note) => note.id).toSet(),
          strict ? {1} : {1, 2, 3, 4},
        );
        expect(
          notes
              .where(
                (note) => note.matchesLabels(selected, matchAllLabels: strict),
              )
              .map((note) => note.id)
              .toSet(),
          matches.map((note) => note.id).toSet(),
        );
      }
    },
  );

  test(
    'strict is the default and opting out survives restart and reset',
    () async {
      expect(AppState.matchAllLabels, isTrue);
      AppState.matchAllLabels = false;
      await Future<void>.delayed(Duration.zero);
      expect(preferences.getBool('match_all_labels'), isFalse);
      AppState.filterLabels = ['2024'];
      await AppState.init(prefs: preferences);
      expect(AppState.matchAllLabels, isFalse);
      expect(AppState.filterLabels, isEmpty);
      await AppState.reset();
      expect(AppState.matchAllLabels, isFalse);
    },
  );

  testWidgets('label matching is staged until Save and Cancel discards it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const NoteDisplayOptionsButton(showLabelFilterOptions: true)),
    );
    final toggle = find.byKey(const ValueKey('match-all-labels-switch'));
    await tester.tap(find.byType(NoteDisplayOptionsButton));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.widgetWithText(SwitchListTile, 'Strict'), findsOneWidget);
    expect(
      find.text('Only show notes containing every selected label.'),
      findsOneWidget,
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(AppState.matchAllLabels, isTrue);
    expect(
      find.text('Show notes containing at least one selected label.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(AppState.matchAllLabels, isTrue);
    await tester.tap(find.byType(NoteDisplayOptionsButton));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(AppState.matchAllLabels, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('system and folder display options omit label matching', (
    tester,
  ) async {
    for (final context in [
      NoteOrderContext.system('archived'),
      NoteOrderContext.label('folder'),
    ]) {
      await tester.pumpWidget(
        _app(
          NoteDisplayOptionsButton(
            key: ValueKey(context.key),
            orderContext: context,
          ),
        ),
      );
      await tester.tap(find.byType(NoteDisplayOptionsButton));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('match-all-labels-switch')),
        findsNothing,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  for (final viewMode in [NoteViewMode.grid, NoteViewMode.list]) {
    testWidgets(
      '${viewMode.name} replaces configure with a fixed close button',
      (tester) async {
        AppState.set('notes_view_mode', viewMode);
        await _pumpNotes(tester, database, width: 300);
        final close = find.byKey(const ValueKey('clear-label-filters-button'));
        final configure = find.byType(NoteDisplayOptionsButton);
        expect(configure, findsOneWidget);
        expect(close, findsNothing);

        for (final selected in [
          ['2024'],
          ['2024', 'Работа'],
        ]) {
          for (final label in selected) {
            final chip = find.widgetWithText(FilterChip, label);
            await tester.ensureVisible(chip);
            await tester.tap(chip);
            await tester.pump();
          }
          await _waitFor(
            tester,
            () => _visibleIds(tester).length == (selected.length == 1 ? 2 : 1),
          );
          await tester.pumpAndSettle();
          expect(configure, findsNothing);
          expect(close, findsOneWidget);
          expect(tester.widget<IconButton>(close).tooltip, 'Clear');
          expect(
            find.descendant(of: close, matching: find.byIcon(Icons.close)),
            findsOneWidget,
          );
          expect(find.byType(ActionChip), findsNothing);

          final closeRect = tester.getRect(close);
          final labels = find.byType(Labels);
          final labelScroll = tester.state<ScrollableState>(
            find.descendant(of: labels, matching: find.byType(Scrollable)),
          );
          expect(labelScroll.position.maxScrollExtent, greaterThan(0));
          await tester.drag(labels, const Offset(-200, 0));
          await tester.pumpAndSettle();
          expect(labelScroll.position.pixels, greaterThan(0));
          expect(tester.getRect(close), closeRect);

          await tester.tap(close);
          await _waitFor(tester, () => _visibleIds(tester).length == 4);
          await tester.pumpAndSettle();
          expect(AppState.filterLabels, isEmpty);
          expect(configure, findsOneWidget);
          expect(close, findsNothing);
          expect(
            tester
                .widgetList<FilterChip>(find.byType(FilterChip))
                .every((chip) => !chip.selected),
            isTrue,
          );
        }

        final chip = find.widgetWithText(FilterChip, '2024');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await _waitFor(tester, () => _visibleIds(tester).length == 2);
        await tester.tap(chip);
        await _waitFor(tester, () => _visibleIds(tester).length == 4);
        await tester.pumpAndSettle();
        expect(configure, findsOneWidget);
        expect(close, findsNothing);
        expect(AppState.matchAllLabels, isTrue);
      },
    );
  }

  testWidgets('label selection survives refresh and filters incoming updates', (
    tester,
  ) async {
    final notes = await _pumpNotes(tester, database);
    await tester.tap(find.widgetWithText(FilterChip, '2024'));
    await _waitFor(tester, () => _visibleIds(tester).length == 2);
    await tester.tap(find.widgetWithText(FilterChip, 'Работа'));
    await _waitFor(tester, () => _visibleIds(tester).length == 1);
    expect(_visibleIds(tester), {1});
    expect(AppState.filterLabels.toSet(), {'2024', 'Работа'});
    NoteSyncService.refreshOperationOverride = () async {};
    LabelSyncService.refreshOperationOverride = () async {};
    await tester.runAsync(
      () => tester.state<NotesState>(find.byType(Notes)).refresh(),
    );
    await tester.pumpAndSettle();
    expect(_visibleIds(tester), {1});
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Работа'))
          .selected,
      isTrue,
    );

    Future<void> update(Note note, String labels) async {
      note.labels = labels;
      await tester.runAsync(
        () => database.update(
          Note.model,
          {'labels': labels},
          where: 'id = ?',
          whereArgs: [note.id],
        ),
      );
      note.notify('updated', false, ModelChangeOrigin.remoteSync);
      await tester.pumpAndSettle();
    }

    await update(notes[1], '2024,Работа');
    expect(_visibleIds(tester), {1, 2});
    await update(notes[0], '2024,Личное');
    expect(_visibleIds(tester), {2});
    await update(notes[2], '2023,Работа');
    expect(_visibleIds(tester), {2});

    await tester.tap(find.byKey(const ValueKey('clear-label-filters-button')));
    await _waitFor(tester, () => _visibleIds(tester).length == 4);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NoteDisplayOptionsButton));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('match-all-labels-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '2024'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Работа'));
    await _waitFor(tester, () => _visibleIds(tester).length == 3);
    expect(_visibleIds(tester), {1, 2, 3});
    expect(AppState.filterLabels.toSet(), {'2024', 'Работа'});
    AppState.notesViewMode = NoteViewMode.list;
    await _waitFor(tester, () => _visibleIds(tester).length == 4);
    await tester.pumpAndSettle();
    expect(AppState.filterLabels, isEmpty);
    expect(
      find
          .byType(FilterChip)
          .evaluate()
          .every((element) => !(element.widget as FilterChip).selected),
      isTrue,
    );
  });

  testWidgets('matching mode change cancels a drag before reloading', (
    tester,
  ) async {
    await _pumpNotes(tester, database);
    await tester.runAsync(
      () =>
          sort.setMode(const NoteOrderContext.mainGrid(), NoteSortMode.custom),
    );
    AppState.filterLabels = ['2024', 'Работа'];
    await _waitFor(tester, () => _visibleIds(tester).length == 1);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(NoteCard)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(
      tester
          .widget<AnimatedMasonryReorderLayout>(
            find.byType(AnimatedMasonryReorderLayout),
          )
          .activeId,
      1,
    );
    AppState.matchAllLabels = false;
    await _waitFor(tester, () => _visibleIds(tester).length == 3);
    expect(
      tester
          .widget<AnimatedMasonryReorderLayout>(
            find.byType(AnimatedMasonryReorderLayout),
          )
          .activeId,
      isNull,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('an incoming update wins over a pending note snapshot', (
    tester,
  ) async {
    final notes = await _pumpNotes(tester, database);
    final delayed = _DelayedNoteDatabase(database);
    AppState.db = delayed;
    addTearDown(() {
      if (!delayed.release.isCompleted) delayed.release.complete();
    });
    AppState.filterLabels = ['2024', 'Работа'];
    await _waitFor(tester, () => delayed.started.isCompleted);
    notes[0].labels = '2024,Личное';
    notes[1].labels = '2024,Работа';
    await tester.runAsync(() async {
      for (final note in notes.take(2)) {
        await database.update(
          Note.model,
          {'labels': note.labels},
          where: 'id = ?',
          whereArgs: [note.id],
        );
        note.notify('updated', false, ModelChangeOrigin.remoteSync);
      }
    });
    delayed.release.complete();
    await _waitFor(tester, () => delayed.finished.isCompleted);
    await _waitFor(tester, () => _visibleIds(tester).length == 1);
    await tester.pumpAndSettle();
    expect(_visibleIds(tester), {2});
  });

  for (final changeMode in [false, true]) {
    testWidgets(
      'older load cannot replace a newer ${changeMode ? 'matching mode' : 'label selection'}',
      (tester) async {
        await _pumpNotes(tester, database);
        final delayed = _DelayedNoteDatabase(database);
        AppState.db = delayed;
        addTearDown(() {
          if (!delayed.release.isCompleted) delayed.release.complete();
        });
        AppState.filterLabels = changeMode ? ['2024', 'Работа'] : ['2024'];
        await _waitFor(tester, () => delayed.started.isCompleted);
        if (changeMode) {
          AppState.matchAllLabels = false;
        } else {
          AppState.filterLabels = ['Работа'];
        }
        final expected = changeMode ? {1, 2, 3} : {1, 3};
        await _waitFor(
          tester,
          () => _visibleIds(tester).length == expected.length,
        );
        expect(_visibleIds(tester), expected);
        delayed.release.complete();
        await _waitFor(tester, () => delayed.finished.isCompleted);
        await tester.pumpAndSettle();
        expect(_visibleIds(tester), expected);
      },
    );
  }
}

Future<Note> _insertNote(Database database, int id, String labels) async {
  final note = Note(
    id: id,
    syncId: 'note-$id',
    title: 'Note $id',
    labels: labels,
    content: '[{"insert":"\\n"}]',
    createdAt: DateTime.utc(2024),
    updatedAt: DateTime.utc(2024),
  );
  await database.insert(Note.model, note.toJson());
  return note;
}

Future<List<Note>> _pumpNotes(
  WidgetTester tester,
  Database database, {
  double width = 500,
}) async {
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  final notes = await tester.runAsync(() async {
    for (final name in ['2024', 'Работа', 'Личное']) {
      await database.insert(Label.model, Label(name: name).toJson());
    }
    return [
      await _insertNote(database, 1, '2024,Работа'),
      await _insertNote(database, 2, '2024,Личное'),
      await _insertNote(database, 3, '2023,Работа'),
      await _insertNote(database, 4, '2023,Личное'),
    ];
  });
  await tester.pumpWidget(_app(const Notes(), width: width));
  await _waitFor(
    tester,
    () =>
        _visibleIds(tester).length == 4 &&
        find.byType(FilterChip).evaluate().length == 3,
  );
  await tester.pumpAndSettle();
  return notes!;
}

Set<int?> _visibleIds(WidgetTester tester) => tester
    .widgetList<NoteCard>(find.byType(NoteCard))
    .map((card) => card.note.id)
    .toSet();

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'Label filter did not settle');
}

Widget _app(Widget child, {double width = 500}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

class _DelayedNoteDatabase implements Database {
  _DelayedNoteDatabase(this.delegate);
  final Database delegate;
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  bool _delayed = false;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await delegate.rawQuery(sql, arguments);
    if (!_delayed && sql.contains('WITH RECURSIVE splitter')) {
      _delayed = true;
      started.complete();
      await release.future;
      finished.complete();
    }
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => delegate.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
