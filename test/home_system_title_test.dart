import 'dart:async';

import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/components/animated_icon.dart';

import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/components/note_display_options_button.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/pages/home/home.dart';
import 'package:better_keep/pages/home/sidebar.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_firebase.dart';

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
    AppState.showNotes = NoteType.all;
    AppState.filterLabels = [];
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
    AppState.currentFolder = null;
    AppState.filterLabels = [];
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

  testWidgets(
    'empty sync switches to the floating pill when the first note arrives',
    (tester) async {
      final backend = OfflineFirebase()..configure();
      addTearDown(() async {
        FirebaseBackend.resetForTesting();
        await backend.auth.changes.close();
        await backend.firestore.events.close();
      });
      final sync = SyncPresentation.instance;
      final previous = sync.value;
      final previousVisibility = AppState.showSyncProgress;
      AppState.set('show_sync_progress', true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        const checking = SyncProgress(
          SyncPhase.syncing,
          notes: (
            stage: NoteTransferStage.checking,
            done: 1,
            total: 4,
            minutesLeft: null,
          ),
        );
        final glyph = find.descendant(
          of: find.byType(SyncContentProgress),
          matching: find.byIcon(Icons.sync),
        );
        final pill = find.byKey(const ValueKey('sync_progress'));
        for (final width in [390.0, 1100.0]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpWidget(_app(const Home()));
          await _drainDatabaseWork(tester);
          sync.value = const SyncProgress(SyncPhase.checkingForUpdates);
          await tester.pump(const Duration(milliseconds: 250));
          expect(
            find.text('Large libraries can take a few minutes.'),
            findsNothing,
          );
          expect(find.text('Syncing...'), findsOneWidget);
          sync.value = checking;
          await tester.pump(const Duration(milliseconds: 250));
          expect(glyph, findsOneWidget);
          expect(find.text('Checking Notes'), findsOneWidget);
          expect(
            find.text('Large libraries can take a few minutes.'),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('download_activity')), findsNothing);
          expect(pill, findsNothing);
          AppState.filterLabels = ['QA'];
          await _drainDatabaseWork(tester);
          expect(glyph, findsNothing);
          expect(pill, findsOneWidget);
          AppState.filterLabels = [];
          await _drainDatabaseWork(tester);
          expect(glyph, findsOneWidget);
          expect(pill, findsNothing);
          AppState.set('show_sync_progress', false);
          await tester.pump();
          expect(find.text('Checking Notes'), findsNothing);
          expect(find.text('Create your first note'), findsNothing);
          expect(glyph, findsOneWidget);
          expect(find.byIcon(Icons.add).hitTestable(), findsOneWidget);
          AppState.set('show_sync_progress', true);
          await tester.pump();
          expect(find.text('Checking Notes'), findsOneWidget);

          expect(find.text('No notes yet'), findsNothing);
          final area = tester.getRect(find.byType(Notes));
          expect(tester.getCenter(glyph).dx, closeTo(area.center.dx, 1));
          expect(tester.getCenter(glyph).dy, closeTo(area.center.dy, 30));
        }
        final note = Note(
          id: 8001,
          title: 'Arrived during sync',
          content: '[]',
        );
        await tester.runAsync(() => database.insert(Note.model, note.toJson()));
        note.notify('created', false, ModelChangeOrigin.remoteSync);
        await _drainDatabaseWork(tester);
        expect(find.text('Arrived during sync'), findsOneWidget);
        expect(glyph, findsNothing);
        expect(pill, findsOneWidget);
        expect(
          find.descendant(of: pill, matching: find.text('Checking Notes')),
          findsOneWidget,
        );
        AppState.showNotes = NoteType.archived;
        await _drainDatabaseWork(tester);
        expect(find.text('Arrived during sync'), findsNothing);
        expect(pill, findsOneWidget);
        expect(glyph, findsNothing);
        sync.value = SyncProgress.idle;
        await tester.pump();
        expect(glyph, findsNothing);
        expect(pill, findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.value = previous;
        AppState.set('show_sync_progress', previousVisibility);
        UserAvatar.invalidateCache();
        await _drainDatabaseWork(tester);
      }
    },
  );

  testWidgets('titlebar buttons have uniform targets and safe-area gutters', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final note in [
        Note(id: 1, title: 'Selected', content: '[]'),
        Note(id: 2, title: 'Archived', content: '[]', archived: true),
        Note(id: 3, title: 'Trashed', content: '[]', trashed: true),
      ]) {
        await database.insert(Note.model, note.toJson());
      }
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    for (final (size, padding, direction, platform) in [
      (
        const Size(320, 640),
        const FakeViewPadding(),
        TextDirection.ltr,
        TargetPlatform.android,
      ),
      (
        const Size(390, 800),
        const FakeViewPadding(top: 24),
        TextDirection.ltr,
        TargetPlatform.iOS,
      ),
      (
        const Size(852, 393),
        const FakeViewPadding(left: 59, right: 20),
        TextDirection.ltr,
        TargetPlatform.macOS,
      ),
      (
        const Size(852, 393),
        const FakeViewPadding(left: 20, right: 59),
        TextDirection.rtl,
        TargetPlatform.macOS,
      ),
      (
        const Size(1100, 800),
        const FakeViewPadding(),
        TextDirection.ltr,
        TargetPlatform.macOS,
      ),
      (
        const Size(1100, 800),
        const FakeViewPadding(),
        TextDirection.rtl,
        TargetPlatform.macOS,
      ),
      (
        const Size(1100, 800),
        const FakeViewPadding(),
        TextDirection.ltr,
        TargetPlatform.android,
      ),
    ]) {
      tester.view.physicalSize = size;
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      for (final (type, selected) in [
        (NoteType.all, false),
        (NoteType.archived, false),
        (NoteType.trashed, false),
        (NoteType.all, true),
      ]) {
        AppState.showNotes = type;
        AppState.selectedNotes = selected
            ? [Note(id: 1, title: 'Selected')]
            : [];
        await tester.pumpWidget(
          _app(
            Directionality(textDirection: direction, child: const Home()),
            platform: platform,
          ),
        );
        await _drainDatabaseWork(tester);
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();
        final buttons = find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(IconButton),
        );
        final rects =
            buttons
                .evaluate()
                .map((element) => tester.getRect(find.byWidget(element.widget)))
                .toList()
              ..sort((a, b) => a.left.compareTo(b.left));
        expect(rects.length, greaterThanOrEqualTo(2));
        for (final rect in rects) {
          expect(rect.size, const Size.square(48));
          expect(rect.top, padding.top + 6);
        }
        // Each end uses only its own safe inset; never mirror extra whitespace.
        expect(rects.first.left, padding.left + 6);
        expect(size.width - rects.last.right, padding.right + 6);
        final actions = direction == TextDirection.ltr
            ? rects.skip(1).toList()
            : rects.take(rects.length - 1).toList();
        for (var i = 1; i < actions.length; i++) {
          expect(actions[i].left - actions[i - 1].right, 8);
        }
        if (selected) {
          await tester.tap(find.byTooltip('Close'));
          await tester.pump(const Duration(seconds: 4));
          await tester.pump();
          expect(AppState.selectedNotes, isEmpty);
        } else if (type == NoteType.all) {
          expect(find.byTooltip('User').hitTestable(), findsOneWidget);
          final avatar = find.descendant(
            of: find.byType(UserAvatar),
            matching: find.byType(CircleAvatar),
          );
          expect(tester.getSize(avatar), const Size.square(40));
          final desktopRefresh =
              platform == TargetPlatform.macOS && size.shortestSide > 600;
          expect(
            find.byType(SyncRefreshButton),
            desktopRefresh ? findsOneWidget : findsNothing,
          );
          if (size.width < 800 || size.height < 640) {
            expect(
              tester.getCenter(find.byType(TextField)).dx,
              (size.width + padding.left - padding.right) / 2,
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _drainDatabaseWork(tester);
      }
    }
  });

  testWidgets('selection count is not clipped at 320 dp with large text', (
    tester,
  ) async {
    final note = Note(id: 1, title: 'Selected', content: '[]');
    await tester.runAsync(() => database.insert(Note.model, note.toJson()));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
        AppState.selectedNotes = [note];
        await tester.pumpWidget(
          _app(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: Directionality(
                textDirection: direction,
                child: const Home(),
              ),
            ),
            platform: TargetPlatform.android,
          ),
        );
        await _drainDatabaseWork(tester);
        final count = find.descendant(
          of: find.byType(AppBar),
          matching: find.text('1'),
        );
        final paragraph = tester.renderObject<RenderParagraph>(count);
        final glyph = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 1),
            )
            .single;
        expect(glyph.left, greaterThanOrEqualTo(0));
        expect(glyph.right, lessThanOrEqualTo(paragraph.size.width));
        final bar = tester.widget<AppBar>(find.byType(AppBar));
        final titleBounds = tester.getRect(find.byWidget(bar.title!));
        final countBounds = tester.getRect(count);
        expect(countBounds.left, greaterThanOrEqualTo(titleBounds.left));
        expect(countBounds.right, lessThanOrEqualTo(titleBounds.right));
        expect(countBounds.width, greaterThan(0));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _drainDatabaseWork(tester);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainDatabaseWork(tester);
    }
  });

  testWidgets('phone search stays usable at 320 dp with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
          await tester.pumpWidget(
            _app(
              MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 640),
                  textScaler: TextScaler.linear(2),
                ),
                child: Directionality(
                  textDirection: direction,
                  child: const Home(),
                ),
              ),
              platform: platform,
            ),
          );
          await _drainDatabaseWork(tester);
          await tester.tap(find.byType(TextField));
          await tester.enterText(find.byType(TextField), 'Search notes');
          await tester.pump(const Duration(milliseconds: 300));
          await _drainDatabaseWork(tester);
          final bar = tester.widget<AppBar>(find.byType(AppBar));
          expect(bar.leading, isNull);
          expect(bar.actions, isEmpty);
          final field = tester.getRect(find.byType(TextField));
          expect(field.left, 6);
          expect(field.right, 314);
          final clear = find.ancestor(
            of: find.byIcon(Icons.clear),
            matching: find.byType(IconButton),
          );
          expect(tester.getSize(clear), const Size.square(48));
          await tester.tap(clear);
          await tester.pump(const Duration(milliseconds: 300));
          await _drainDatabaseWork(tester);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            isEmpty,
          );
          expect(find.byTooltip('User').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await _drainDatabaseWork(tester);
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _drainDatabaseWork(tester);
    }
  });

  testWidgets('home changes to a usable drawer when a wide window gets short', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    AppState.showNotes = NoteType.all;
    await tester.pumpWidget(_app(const Home()));
    await _drainDatabaseWork(tester);
    final notesState = tester.state(find.byType(Notes));
    expect(tester.widget<Sidebar>(find.byType(Sidebar)).persistent, isTrue);
    final homeScaffold = find.descendant(
      of: find.byType(Home),
      matching: find.byType(Scaffold),
    );
    final scaffold = tester.state<ScaffoldState>(homeScaffold);
    expect(tester.widget<Scaffold>(homeScaffold).drawer, isNull);

    for (final size in [const Size(852, 393), const Size(1440, 450)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.widget<Scaffold>(homeScaffold).drawer, isNotNull);
      expect(find.byType(Sidebar), findsNothing);
      expect(tester.state(find.byType(Notes)), same(notesState));
      expect(tester.getSize(find.byType(Notes)).width, size.width);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.add).hitTestable(), findsOneWidget);
      scaffold.openDrawer();
      await tester.pumpAndSettle();
      expect(tester.widget<Sidebar>(find.byType(Sidebar)).persistent, isFalse);
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      await _drainDatabaseWork(tester);
      expect(scaffold.isDrawerOpen, isFalse);
      expect(AppState.showNotes, NoteType.archived);
      expect(find.byType(Home), findsOneWidget);
      expect(tester.takeException(), isNull);
      AppState.showNotes = NoteType.all;
      await _drainDatabaseWork(tester);
    }

    scaffold.openDrawer();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1100, 800);
    await tester.pumpAndSettle();
    expect(tester.widget<Sidebar>(find.byType(Sidebar)).persistent, isTrue);
    expect(tester.state(find.byType(Notes)), same(notesState));
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    final toggle = find.ancestor(
      of: find.byType(AnimatedMenuIcon),
      matching: find.byType(IconButton),
    );
    for (final collapsed in [true, false]) {
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.widget<Sidebar>(find.byType(Sidebar)).shrink, collapsed);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainDatabaseWork(tester);
  });

  testWidgets('opening the create menu preserves a dismissed sync failure', (
    tester,
  ) async {
    final sync = SyncPresentation.instance;
    final previous = sync.value;
    final pill = find.byKey(const ValueKey('sync_progress'));
    try {
      await tester.pumpWidget(_app(const Home()));
      await _drainDatabaseWork(tester);
      sync.value = const SyncProgress(SyncPhase.failed);
      await tester.pumpAndSettle();
      await tester.drag(pill, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(pill, findsNothing);

      final fab = find.byIcon(Icons.add);
      final gesture = await tester.startGesture(tester.getCenter(fab));
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 250));
      final rotation = find.ancestor(
        of: fab,
        matching: find.byType(AnimatedRotation),
      );
      expect(tester.widget<AnimatedRotation>(rotation).turns, isNot(0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedRotation>(rotation).turns, 0);
      expect(pill, findsNothing);

      sync.value = const SyncProgress(SyncPhase.storageFull);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Retry'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      sync.value = previous;
      UserAvatar.invalidateCache();
      await _drainDatabaseWork(tester);
    }
  });

  testWidgets('bulk restore shows the floating pill as soon as a note exists', (
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
        expect(find.byKey(const ValueKey('download_activity')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byKey(const ValueKey('sync_progress')), findsNothing);
      }
      await tester.drag(
        find.descendant(
          of: find.byType(Notes),
          matching: find.byType(CustomScrollView),
        ),
        const Offset(0, 500),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Downloading Notes'),
        ),
        findsOneWidget,
      );
      expect(sync.isManualRefresh, isFalse);
      // show() returns the pending future for the gesture already in progress.
      var refreshCompleted = false;
      final indicator = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      unawaited(indicator.show().then((_) => refreshCompleted = true));
      final first = Note(id: 9876, title: 'First restored note', content: '[]');
      await tester.runAsync(() => database.insert(Note.model, first.toJson()));
      first.notify('created', false, ModelChangeOrigin.remoteSync);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(NoteSyncBatch.active.value, isTrue);
      expect(find.text('First restored note'), findsOneWidget);
      final pill = find.byKey(const ValueKey('sync_progress'));
      expect(pill, findsOneWidget);
      final glyph = find.byKey(const ValueKey('download_activity'));
      expect(glyph, findsOneWidget);
      expect(find.descendant(of: pill, matching: glyph), findsOneWidget);
      final restored = List.generate(
        5000,
        (i) => Note(id: 20000 + i, title: 'Bulk $i', content: '[]'),
      );
      await tester.runAsync(() async {
        final writes = database.batch();
        for (final note in restored) {
          writes.insert(Note.model, note.toJson());
        }
        await writes.commit(noResult: true);
      });
      var gridBuilds = 0;
      final observer = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        observer?.call(element, builtOnce);
        if (element.widget is Notes) gridBuilds++;
      };
      try {
        for (final (index, note) in restored.indexed) {
          note.notify('created', false, ModelChangeOrigin.remoteSync);
          if (index % 100 == 99) await tester.pump();
        }
        expect(gridBuilds, lessThanOrEqualTo(2));
      } finally {
        debugOnRebuildDirtyWidget = observer;
      }
      expect(find.text('First restored note'), findsOneWidget);
      expect(find.text('Bulk 1999'), findsNothing);
      await tester.pump(const Duration(milliseconds: 450));
      await _drainDatabaseWork(tester);
      final bulkCards = find.byWidgetPredicate(
        (widget) =>
            widget is NoteCard &&
            widget.note.title?.startsWith('Bulk ') == true,
      );
      for (var i = 0; i < 15 && bulkCards.evaluate().isEmpty; i++) {
        await _drainDatabaseWork(tester);
      }
      expect(bulkCards, findsWidgets);
      expect(find.byType(NoteCard).evaluate().length, lessThan(40));
      expect(refreshCompleted, isFalse, reason: 'The restore is still running');
      done.complete();
      await transfer;
      await tester.pump();
      expect(refreshCompleted, isTrue, reason: 'The restore has finished');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!done.isCompleted) done.complete();
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
          final deleteAction = appBarWidget.actions!
              .whereType<IconButton>()
              .last;
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
  // Queries cross between the real SQLite isolate and the test's fake clock.
  // Flush both queues so chained reads can finish before assertions run.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

Widget _app(Widget home, {TargetPlatform? platform}) => MaterialApp(
  theme: ThemeData(platform: platform),
  scaffoldMessengerKey: AppState.scaffoldMessengerKey,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: home,
);
