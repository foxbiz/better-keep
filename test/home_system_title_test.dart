import 'dart:async';

import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/pages/home/notes.dart';
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

  testWidgets(
    'incoming notes rebuild only changed cards and keep edits visible',
    (tester) async {
      AppState.showNotes = NoteType.archived;
      await tester.runAsync(() async {
        for (var i = 1; i <= 100; i++) {
          await database.insert(
            Note.model,
            Note(
              id: i,
              title: 'Existing $i',
              archived: true,
              content: '[]',
            ).toJson(),
          );
        }
      });
      await tester.pumpWidget(_app(const Scaffold(body: Notes())));
      await _drainDatabaseWork(tester);
      await _drainDatabaseWork(tester);
      await tester.pump(const Duration(milliseconds: 1250));
      await tester.pumpAndSettle();
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 30));

      final items = tester
          .widgetList<MasonryReorderItem>(find.byType(MasonryReorderItem))
          .toList();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(1);
      await tester.pump();
      final afterScroll = tester
          .widgetList<MasonryReorderItem>(find.byType(MasonryReorderItem))
          .toList();
      expect(afterScroll.length, items.length);
      for (var i = 0; i < items.length; i++) {
        expect(identical(items[i], afterScroll[i]), isTrue);
      }
      scroll.jumpTo(0);
      await tester.pump();

      var cardBuilds = 0;
      final previousObserver = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousObserver?.call(element, builtOnce);
        if (element.widget is NoteCard) cardBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousObserver);
      final incoming = Note(
        id: 101,
        title: 'Incoming',
        updatedAt: DateTime.now(),
        archived: true,
        content: '[]',
      );
      incoming.notify('created', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 30));
      expect(
        cardBuilds,
        lessThanOrEqualTo(2),
        reason: 'one incoming note must not rebuild the existing library',
      );

      // Edits can mutate the same model object, so identity alone is not enough.
      final edited = tester
          .widget<NoteCard>(find.byKey(const ValueKey('note_card_100')))
          .note;
      edited.title = 'Updated in place';
      edited.notify('updated', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      expect(find.text('Updated in place'), findsOneWidget);
      expect(find.text('Existing 100'), findsNothing);
      AppState.selectedNotes = [edited];
      Note(
        id: 100,
        title: 'Older creation event',
        archived: true,
      ).notify('created', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      expect(AppState.selectedNotes.single, same(edited));
      Note(
        id: 100,
        title: 'Updated in place',
        updatedAt: edited.updatedAt,
        archived: true,
        locked: true,
        content: '[]',
      ).notify('updated', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      expect(find.byIcon(Icons.lock), findsOneWidget);

      incoming.notify('deleted', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      expect(find.byKey(const ValueKey('note_card_101')), findsNothing);
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 30));
      await tester.pump(const Duration(milliseconds: 1250));
      await _drainDatabaseWork(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainDatabaseWork(tester);
    },
  );

  testWidgets('covered notes defer bulk updates and reload on return', (
    tester,
  ) async {
    AppState.showNotes = NoteType.archived;
    await tester.pumpWidget(_app(const Scaffold(body: Notes())));
    await _drainDatabaseWork(tester);
    final navigator = Navigator.of(tester.element(find.byType(Notes)));
    navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Account'))),
    );
    await tester.pumpAndSettle();
    AppState.selectedNotes = [Note(id: 999, title: 'Old selection')];

    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        final note = Note(
          id: i + 1,
          title: 'Downloaded $i',
          archived: true,
          content: '[]',
        );
        await database.insert(Note.model, note.toJson());
        note.notify('created', false, ModelChangeOrigin.remoteSync);
      }
    });
    await tester.pump();
    expect(find.byType(NoteCard, skipOffstage: false), findsNothing);
    expect(AppState.selectedNotes.single.id, 999);

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _drainDatabaseWork(tester);
    await _drainDatabaseWork(tester);
    expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 30));
    expect(find.text('Downloaded 99'), findsOneWidget);
    expect(AppState.selectedNotes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1250));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Downloaded 0'), findsOneWidget);
    scroll.jumpTo(0);
    await tester.pump();
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(
        of: find.byType(NoteCard),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades, isNotEmpty);
    expect(fades.map((fade) => fade.opacity.value), everyElement(1.0));
    expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 30));
    await _drainDatabaseWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainDatabaseWork(tester);
  });

  testWidgets('empty notes remain centered and bounded on a wide screen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppState.showNotes = NoteType.archived;
    await tester.pumpWidget(_app(const Scaffold(body: Notes())));
    await _drainDatabaseWork(tester);
    await _drainDatabaseWork(tester);
    await tester.pumpAndSettle();
    final empty = find.byType(SliverFillRemaining);
    expect(empty, findsOneWidget);
    final box = find.descendant(
      of: empty,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox && widget.constraints.maxWidth == 1200,
      ),
    );
    expect(box, findsOneWidget);
    expect(tester.getSize(box).width, lessThanOrEqualTo(1200));
    expect(tester.getCenter(box).dx, closeTo(800, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainDatabaseWork(tester);
  });

  testWidgets('a download has one indicator across the complete home screen', (
    tester,
  ) async {
    final batch = NoteSyncBatch();
    final done = Completer<void>();
    final sync = SyncPresentation.instance;
    final previous = sync.value;
    final transfer = batch.run(
      100,
      (_) => done.future,
      isEmptyLibrary: () async => true,
      onProgress: (notes) =>
          sync.value = SyncProgress(SyncPhase.syncing, notes: notes),
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      for (final width in [390.0, 1100.0]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpWidget(_app(const Home()));
        await _drainDatabaseWork(tester);
        expect(sync.value.isActive, isTrue);
        expect(find.byIcon(Icons.download_rounded), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.byKey(const ValueKey('sync_progress')), findsNothing);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      done.complete();
      await transfer;
      sync.value = previous;
      await _drainDatabaseWork(tester);
    }
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
