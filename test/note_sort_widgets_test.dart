import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:better_keep/components/note_display_options_button.dart';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  final service = NoteSortService();

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    await service.dispose();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    AppState.selectedNotes = [];
    AppState.set('notes_view_mode', NoteViewMode.grid);
    await Note.createTable(database);
    await NoteSortService.createTable(database);
    await service.init();
  });

  tearDown(() async {
    AppState.selectedNotes = [];
    await service.dispose();
    await database.close();
  });

  testWidgets('display options stage and save view and sort together', (
    tester,
  ) async {
    NoteSortMode? persistedMode;
    NoteSortMode? callbackMode;
    NoteViewMode? viewModeDuringPersistence;
    await tester.pumpWidget(
      _app(
        NoteDisplayOptionsButton(
          persistSortMode: (mode) async {
            viewModeDuringPersistence = AppState.notesViewMode;
            persistedMode = mode;
          },
          onSortChanged: (mode) => callbackMode = mode,
        ),
      ),
    );

    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byTooltip('Note display options · Custom'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byIcon(Icons.tune),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('note-order-context-label')),
      findsNothing,
    );
    expect(find.textContaining('Applies to:'), findsNothing);
    expect(find.byType(RadioGroup<NoteViewMode>), findsOneWidget);
    expect(find.byType(RadioListTile<NoteViewMode>), findsNWidgets(4));
    expect(find.byType(RadioGroup<NoteSortMode>), findsOneWidget);
    expect(find.byType(RadioListTile<NoteSortMode>), findsNWidgets(3));
    expect(
      find.text('Press and hold a note, then drag to rearrange it.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.widgetWithText(RadioListTile<NoteViewMode>, 'List'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(RadioListTile<NoteSortMode>, 'Date created'),
    );
    await tester.pump();
    expect(
      find.text(
        'Manual rearranging is unavailable while sorting by date. '
        'Choose Custom to rearrange notes.',
      ),
      findsOneWidget,
    );

    expect(AppState.notesViewMode, NoteViewMode.grid);
    expect(
      service.snapshotFor(const NoteOrderContext.mainGrid()).mode,
      NoteSortMode.custom,
    );
    expect(persistedMode, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(viewModeDuringPersistence, NoteViewMode.grid);
    expect(persistedMode, NoteSortMode.createdNewest);
    expect(AppState.notesViewMode, NoteViewMode.list);
    expect(callbackMode, NoteSortMode.createdNewest);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancelling display options leaves settings unchanged', (
    tester,
  ) async {
    var persisted = false;
    await tester.pumpWidget(
      _app(
        NoteDisplayOptionsButton(
          persistSortMode: (_) async => persisted = true,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(RadioListTile<NoteViewMode>, 'List'));
    await tester.tap(
      find.widgetWithText(RadioListTile<NoteSortMode>, 'Date created'),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(persisted, isFalse);
    expect(AppState.notesViewMode, NoteViewMode.grid);
    expect(
      service.snapshotFor(const NoteOrderContext.mainGrid()).mode,
      NoteSortMode.custom,
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('view changes configure only the destination context', (
    tester,
  ) async {
    NoteSortMode? persistedMode;
    const listContext = NoteOrderContext.mainList();
    service.snapshots.value = Map.unmodifiable({
      ...service.snapshots.value,
      listContext.key: service
          .snapshotFor(listContext)
          .copyWith(mode: NoteSortMode.createdNewest),
    });
    await tester.pumpWidget(
      _app(
        NoteDisplayOptionsButton(
          persistSortMode: (mode) async => persistedMode = mode,
          contextForView: (mode) => switch (mode) {
            NoteViewMode.grid => const NoteOrderContext.mainGrid(),
            NoteViewMode.list => const NoteOrderContext.mainList(),
            _ => null,
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RadioGroup<NoteSortMode>>(
            find.byType(RadioGroup<NoteSortMode>),
          )
          .groupValue,
      NoteSortMode.custom,
    );

    await tester.tap(find.widgetWithText(RadioListTile<NoteViewMode>, 'List'));
    await tester.pump();
    expect(
      tester
          .widget<RadioGroup<NoteSortMode>>(
            find.byType(RadioGroup<NoteSortMode>),
          )
          .groupValue,
      NoteSortMode.createdNewest,
    );
    await tester.tap(
      find.widgetWithText(RadioListTile<NoteSortMode>, 'Custom'),
    );
    await tester.pump();
    expect(
      find.text('Press and hold a note, then drag to rearrange it.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(persistedMode, NoteSortMode.custom);
    expect(
      service.snapshotFor(const NoteOrderContext.mainGrid()).mode,
      NoteSortMode.custom,
    );
    expect(AppState.notesViewMode, NoteViewMode.list);
  });

  testWidgets('sort-only display options omit the view section', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const NoteDisplayOptionsButton(showViewOptions: false)),
    );

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();

    expect(find.text('Select View'), findsNothing);
    expect(find.byType(RadioGroup<NoteViewMode>), findsNothing);
    expect(find.byType(RadioListTile<NoteViewMode>), findsNothing);
    expect(find.byType(RadioGroup<NoteSortMode>), findsOneWidget);
    expect(find.byType(RadioListTile<NoteSortMode>), findsNWidgets(3));
  });

  testWidgets('sort indicator appears only for a non-default Home sort', (
    tester,
  ) async {
    const grid = NoteOrderContext.mainGrid();
    final defaultSnapshot = service.snapshotFor(grid);
    await tester.pumpWidget(
      _app(
        const NoteDisplayOptionsButton(key: ValueKey('default-sort-button')),
      ),
    );

    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsNothing,
    );

    service.snapshots.value = Map.unmodifiable({
      ...service.snapshots.value,
      grid.key: defaultSnapshot.copyWith(mode: NoteSortMode.updatedNewest),
    });
    await tester.pumpWidget(
      _app(const NoteDisplayOptionsButton(key: ValueKey('date-sort-button'))),
    );

    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsOneWidget,
    );

    service.snapshots.value = Map.unmodifiable({
      ...service.snapshots.value,
      grid.key: defaultSnapshot,
    });
    await tester.pumpWidget(
      _app(const NoteDisplayOptionsButton(key: ValueKey('custom-sort-button'))),
    );

    expect(
      find.byKey(const ValueKey('note-sort-non-default-indicator')),
      findsNothing,
    );
  });

  testWidgets('non-reorderable feeds do not expose Custom', (tester) async {
    await tester.pumpWidget(
      _app(
        NoteDisplayOptionsButton(
          showViewOptions: false,
          orderContext: NoteOrderContext.system('archived'),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<NoteSortMode>), findsNWidgets(2));
    expect(find.textContaining('Custom'), findsNothing);
  });

  testWidgets('failed display options save stays open and can retry', (
    tester,
  ) async {
    var attempts = 0;
    var callbackCount = 0;
    await tester.pumpWidget(
      _app(
        NoteDisplayOptionsButton(
          persistSortMode: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('injected save failure');
          },
          onSortChanged: (_) => callbackCount++,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(RadioListTile<NoteViewMode>, 'List'));
    await tester.tap(
      find.widgetWithText(RadioListTile<NoteSortMode>, 'Date created'),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(AppState.notesViewMode, NoteViewMode.grid);
    expect(callbackCount, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Could not save the note display options. Please try again.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(AppState.notesViewMode, NoteViewMode.list);
    expect(callbackCount, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('display options dialog remains scroll-safe on a narrow screen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_app(const NoteDisplayOptionsButton()));
    await tester.tap(find.byKey(const ValueKey('note-display-options-button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom mode exposes no separate drag icon', (tester) async {
    await tester.pumpWidget(
      _app(
        NoteCard(
          note: _note(10, 'Whole card drag'),
          index: 0,
          reorderConfig: _reorderConfig(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });

  testWidgets('hold without movement selects the note', (tester) async {
    final note = _note(11, 'Selectable note');
    var cancelled = 0;
    await tester.pumpWidget(
      _app(
        NoteCard(
          note: note,
          index: 0,
          reorderConfig: _reorderConfig(onCancel: () => cancelled++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Selectable note'));
    await tester.pump();

    expect(cancelled, 1);
    expect(AppState.selectedNotes.map((selected) => selected.id), [11]);
  });

  testWidgets('hold and move drags without selecting', (tester) async {
    final note = _note(12, 'Draggable note');
    var lifted = 0;
    var moved = 0;
    var dropped = 0;
    await tester.pumpWidget(
      _app(
        NoteCard(
          note: note,
          index: 0,
          reorderConfig: _reorderConfig(
            onLift: (_) => lifted++,
            onMove: (_) => moved++,
            onDrop: (_) => dropped++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final start = tester.getCenter(find.text('Draggable note'));
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(lifted, 1);
    expect(moved, greaterThan(0));
    expect(dropped, 1);
    expect(AppState.selectedNotes, isEmpty);
  });

  testWidgets('masonry children animate when their order changes', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    late StateSetter update;
    var ids = [1, 2, 3, 4];
    final heights = {1: 180.0, 2: 60.0, 3: 60.0, 4: 60.0};

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: 300,
              child: AnimatedMasonryReorderLayout(
                controller: controller,
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final id in ids)
                    MasonryReorderItem(
                      key: ValueKey(id),
                      id: id,
                      child: SizedBox(
                        height: heights[id],
                        child: ColoredBox(color: Colors.blue),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = controller.globalRectFor(3)!;

    update(() => ids = [2, 3, 1, 4]);
    await tester.pump();
    final animationStart = controller.globalRectFor(3)!;
    await tester.pump(const Duration(milliseconds: 90));
    final animationMiddle = controller.globalRectFor(3)!;
    await tester.pumpAndSettle();
    final after = controller.globalRectFor(3)!;

    expect(animationStart.topLeft, isNot(after.topLeft));
    expect(animationMiddle.topLeft, isNot(before.topLeft));
    expect(animationMiddle.topLeft, isNot(after.topLeft));
    expect(after.topLeft, isNot(before.topLeft));
  });

  testWidgets('stationary drag target stays stable during masonry reflow', (
    tester,
  ) async {
    final layoutController = MasonryLayoutController();
    final reorderController = NoteReorderController()
      ..begin(ids: [1, 2, 3, 4], draggedId: 1);
    late StateSetter update;
    var ids = [1, 2, 3, 4];
    final heights = {1: 180.0, 2: 60.0, 3: 60.0, 4: 60.0};

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: 300,
              child: AnimatedMasonryReorderLayout(
                controller: layoutController,
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                activeId: 1,
                dragAnchor: const Offset(73, 90),
                children: [
                  for (final id in ids)
                    MasonryReorderItem(
                      key: ValueKey(id),
                      id: id,
                      child: SizedBox(height: heights[id]),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final targetRect = layoutController.targetGlobalRectFor(3)!;
    final stationaryPosition = targetRect.center;
    final firstResolution = layoutController.resolveInsertion(
      globalPosition: stationaryPosition,
      excludingId: 1,
    )!;

    expect(reorderController.accept(firstResolution), isTrue);
    final expectedPreview = reorderController.previewIds;
    update(() => ids = reorderController.previewIds);
    await tester.pump();
    final restartCount = layoutController.debugAnimationRestartCount;

    for (var frame = 0; frame < 8; frame++) {
      final resolution = layoutController.resolveInsertion(
        globalPosition: stationaryPosition,
        excludingId: 1,
        previousResolution: reorderController.dropResolution,
      );
      expect(resolution?.insertionIndex, firstResolution.insertionIndex);
      expect(reorderController.accept(resolution!), isFalse);
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(layoutController.debugAnimationRestartCount, restartCount);
    expect(reorderController.previewIds, expectedPreview);
  });

  testWidgets('nearest slots resolve gaps with distance hysteresis', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    await tester.pumpWidget(_slotListApp(controller));
    await tester.pumpAndSettle();
    final bounds = controller.globalBounds!;

    Offset globalPoint(double localY) =>
        Offset(bounds.left + bounds.width / 2, bounds.top + localY);

    final first = controller.resolveInsertion(
      globalPosition: globalPoint(98),
      excludingId: 1,
    )!;
    expect(first.insertionIndex, 1);
    final second = controller.resolveInsertion(
      globalPosition: globalPoint(180),
      excludingId: 1,
    )!;
    expect(second.insertionIndex, 2);
    final boundaryY =
        (first.slotRect.center.dy + second.slotRect.center.dy) / 2;

    for (final offset in [-2.0, 0.0, 2.0, 5.0]) {
      final jittered = controller.resolveInsertion(
        globalPosition: globalPoint(boundaryY + offset),
        excludingId: 1,
        previousResolution: first,
      );
      expect(jittered?.insertionIndex, first.insertionIndex);
    }

    final clearlyCloser = controller.resolveInsertion(
      globalPosition: globalPoint(boundaryY + 20),
      excludingId: 1,
      previousResolution: first,
    );
    expect(clearlyCloser?.insertionIndex, 2);

    final inGap = controller.resolveInsertion(
      globalPosition: globalPoint(64),
      excludingId: 1,
    );
    expect(inGap, isNotNull);
  });

  testWidgets('the whole tall target resolves to nearby landing slots', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    await tester.pumpWidget(_tallTargetApp(controller));
    await tester.pumpAndSettle();
    final target = controller.targetGlobalRectFor(2)!;

    final upper = controller.resolveInsertion(
      globalPosition: Offset(target.center.dx, target.top + 40),
      excludingId: 1,
    );
    final middle = controller.resolveInsertion(
      globalPosition: target.center,
      excludingId: 1,
    );
    final lower = controller.resolveInsertion(
      globalPosition: Offset(target.center.dx, target.bottom - 40),
      excludingId: 1,
    );

    expect(upper, isNotNull);
    expect(middle, isNotNull);
    expect(lower, isNotNull);
    expect(middle?.insertionIndex, isNot(upper?.insertionIndex));
    expect(lower?.insertionIndex, middle?.insertionIndex);
  });

  testWidgets('finger anchor does not change the visible landing result', (
    tester,
  ) async {
    const visibleTopLeft = Offset(0, 120);
    const centeredAnchor = Offset(150, 30);
    final centeredController = MasonryLayoutController();
    await tester.pumpWidget(
      _slotListApp(centeredController, dragAnchor: centeredAnchor),
    );
    await tester.pumpAndSettle();
    final centeredBounds = centeredController.globalBounds!;
    final centered = centeredController.resolveInsertion(
      globalPosition: centeredBounds.topLeft + visibleTopLeft + centeredAnchor,
      excludingId: 1,
    );

    const edgeAnchor = Offset(40, 10);
    final edgeController = MasonryLayoutController();
    await tester.pumpWidget(
      _slotListApp(edgeController, dragAnchor: edgeAnchor),
    );
    await tester.pumpAndSettle();
    final edgeBounds = edgeController.globalBounds!;
    final edge = edgeController.resolveInsertion(
      globalPosition: edgeBounds.topLeft + visibleTopLeft + edgeAnchor,
      excludingId: 1,
    );

    expect(edge?.insertionIndex, centered?.insertionIndex);
    expect(edge?.slotRect, centered?.slotRect);
  });

  testWidgets('dragging keeps the largest encountered section extent', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    late StateSetter update;
    var ids = [2, 3, 1, 4];
    int? activeId = 1;

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: 300,
              child: AnimatedMasonryReorderLayout(
                controller: controller,
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                activeId: activeId,
                children: [
                  for (final id in ids)
                    MasonryReorderItem(
                      key: ValueKey(id),
                      id: id,
                      child: SizedBox(height: id == 1 ? 180 : 60),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dragStartExtent = controller.globalBounds!.height;

    update(() => ids = [1, 2, 3, 4]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.globalBounds!.height, dragStartExtent);

    update(() => activeId = null);
    await tester.pumpAndSettle();

    expect(controller.globalBounds!.height, lessThan(dragStartExtent));
  });

  testWidgets('drag paint updates do not rebuild masonry children', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    var childBuilds = 0;
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 600,
          child: AnimatedMasonryReorderLayout(
            controller: controller,
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            activeId: 1,
            dragGlobalPosition: const Offset(100, 100),
            children: [
              for (final id in List.generate(120, (index) => index + 1))
                MasonryReorderItem(
                  key: ValueKey(id),
                  id: id,
                  child: Builder(
                    builder: (context) {
                      childBuilds++;
                      return SizedBox(
                        height: 56.0 + (id % 5) * 28,
                        child: const ColoredBox(color: Colors.blue),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buildsBeforeMovement = childBuilds;
    final restartsBeforeMovement = controller.debugAnimationRestartCount;

    for (var index = 0; index < 20; index++) {
      controller.updateDragPosition(Offset(100 + index * 2, 100 + index * 3));
      await tester.pump(const Duration(milliseconds: 8));
    }

    expect(childBuilds, buildsBeforeMovement);
    expect(controller.debugAnimationRestartCount, restartsBeforeMovement);
  });

  testWidgets('reduced motion applies reordered geometry immediately', (
    tester,
  ) async {
    final controller = MasonryLayoutController();
    late StateSetter update;
    var ids = [1, 2, 3];
    await tester.pumpWidget(
      _app(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 300,
                child: AnimatedMasonryReorderLayout(
                  controller: controller,
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final id in ids)
                      MasonryReorderItem(
                        key: ValueKey(id),
                        id: id,
                        child: SizedBox(height: id == 1 ? 160 : 60),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final before = controller.globalRectFor(3)!;

    update(() => ids = [2, 3, 1]);
    await tester.pump();
    final immediatelyAfter = controller.globalRectFor(3)!;
    await tester.pump(const Duration(milliseconds: 90));

    expect(immediatelyAfter.topLeft, isNot(before.topLeft));
    expect(controller.globalRectFor(3)!.topLeft, immediatelyAfter.topLeft);
  });
}

Note _note(int id, String title) {
  return Note(
    id: id,
    title: title,
    content: '[{"insert":"\\n"}]',
    createdAt: DateTime.utc(2026, 7, 24),
    updatedAt: DateTime.utc(2026, 7, 24),
  );
}

NoteCardReorderConfig _reorderConfig({
  ValueChanged<Offset>? onLift,
  ValueChanged<Offset>? onMove,
  ValueChanged<Offset>? onDrop,
  VoidCallback? onCancel,
}) {
  return NoteCardReorderConfig(
    enabled: true,
    dragging: false,
    dragLabel: 'Drag to reorder',
    moveBeforeLabel: 'Move before',
    moveAfterLabel: 'Move after',
    onLift: onLift ?? (_) {},
    onMove: onMove ?? (_) {},
    onDrop: onDrop ?? (_) {},
    onCancel: onCancel ?? () {},
    onMoveBefore: () {},
    onMoveAfter: () {},
  );
}

Widget _app(Widget child) {
  final body = Center(child: SizedBox(width: 360, child: child));
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: body),
  );
}

Widget _tallTargetApp(MasonryLayoutController controller) {
  return _app(
    SizedBox(
      width: 300,
      child: AnimatedMasonryReorderLayout(
        controller: controller,
        crossAxisCount: 1,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        activeId: 1,
        dragAnchor: const Offset(150, 30),
        children: [
          for (final id in [1, 2, 3])
            MasonryReorderItem(
              key: ValueKey(id),
              id: id,
              child: SizedBox(height: id == 2 ? 300 : 60),
            ),
        ],
      ),
    ),
  );
}

Widget _slotListApp(
  MasonryLayoutController controller, {
  Offset dragAnchor = const Offset(150, 30),
}) {
  return _app(
    SizedBox(
      width: 300,
      child: AnimatedMasonryReorderLayout(
        controller: controller,
        crossAxisCount: 1,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        activeId: 1,
        dragAnchor: dragAnchor,
        children: [
          for (final id in [1, 2, 3, 4])
            MasonryReorderItem(
              key: ValueKey(id),
              id: id,
              child: const SizedBox(height: 60),
            ),
        ],
      ),
    ),
  );
}
