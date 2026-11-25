import 'dart:convert';

import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/utils/utils.dart' show showPage;
import 'package:better_keep/components/note_attachments_carousel.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/checklist_editor/rich_checklist_editor.dart';
import 'package:better_keep/pages/home/home_layout.dart';
import 'package:better_keep/pages/home/note_pane.dart';
import 'package:better_keep/pages/home/sidebar.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _folded = Size(466, 678);
const _open = Size(951, 669);
const _openPortrait = Size(669, 951);
const _duoInsets = EdgeInsets.only(right: 84, bottom: 34);

void main() {
  setUp(() => debugIsIPhoneDuoOverride = true);
  tearDown(() => debugIsIPhoneDuoOverride = null);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  test('two panes need width and height', () {
    NotePaneLayout? at(Size size, [double scale = 1]) => NotePaneLayout.of(
      MediaQueryData(
        size: size,
        viewPadding: _duoInsets,
        textScaler: TextScaler.linear(scale),
      ),
      TextDirection.ltr,
    );
    expect(at(_folded), isNull);
    expect(at(_openPortrait), isNull);
    expect(at(const Size(960, 420)), isNull);
    expect(at(_open, 1.5), isNull);
    final open = at(_open)!;
    expect(open.listWidth, closeTo(364, 1));
    expect(open.listWidth + open.paneWidth, _open.width);
  });

  void resize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    const padding = FakeViewPadding(right: 84, bottom: 34);
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
  }

  final editor = find.byType(NoteEditor);
  final list = find.byKey(const Key('list'));

  // Unsaved empty notes close without touching the database.
  final notes = {'first': Note(content: '[]'), 'second': Note(content: '[]')};

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    TextDirection direction = TextDirection.ltr,
  }) async {
    resize(tester, size);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            Directionality(textDirection: direction, child: child!),
        home: NotePaneHost(
          child: Builder(
            builder: (context) => Scaffold(
              key: const Key('list'),
              drawer: const Drawer(child: Sidebar()),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('side by side ${NotePaneHost.isSideBySide(context)}'),
                  Text('width ${MediaQuery.sizeOf(context).width}'),
                  const TextField(key: Key('search')),
                  for (final MapEntry(:key, :value) in notes.entries)
                    SizedBox(
                      height: 48,
                      child: TextButton(
                        onPressed: () => openNote(context, value),
                        child: Text(key),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('folding keeps the same editor ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await pump(tester, _folded);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      expect(tester.getSize(editor).width, _folded.width);
      expect(list, findsNothing, reason: 'covered by the note');
      final state = tester.state(editor);
      final quill = tester.state(find.byType(QuillEditor).first);

      resize(tester, _open);
      await tester.pumpAndSettle();
      expect(tester.state(editor), same(state));
      expect(tester.state(find.byType(QuillEditor).first), same(quill));
      expect(tester.getRect(editor).right, _open.width);
      expect(tester.getRect(list).right, tester.getRect(editor).left);
      expect(find.text('side by side true'), findsOneWidget);

      resize(tester, _openPortrait);
      await tester.pumpAndSettle();
      expect(tester.state(editor), same(state));
      expect(tester.getSize(editor).width, _openPortrait.width);
      expect(list, findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(list, findsOneWidget);
      await close(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the list stays usable beside a note ($platform)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await pump(tester, _open);
      expect(find.text('side by side false'), findsOneWidget);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      final first = tester.widget<NoteEditor>(editor);
      expect(first.note, same(notes['first']));

      // The same note again changes nothing.
      final state = tester.state(editor);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      expect(tester.state(editor), same(state));

      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(tester.widget<NoteEditor>(editor).note, same(notes['second']));

      // Typing in the list does not need the note to close.
      await tester.enterText(find.byKey(const Key('search')), 'query');
      await tester.pumpAndSettle();
      expect(find.text('query'), findsOneWidget);
      expect(editor, findsOneWidget);

      // The drawer closes itself, not the note.
      tester.state<ScaffoldState>(list).openDrawer();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      expect(tester.state<ScaffoldState>(list).isDrawerOpen, isFalse);
      expect(editor, findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(find.text('width ${_open.width}'), findsOneWidget);
      AppState.showNotes = NoteType.all;
      await close(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('the list keeps its place while a note leaves', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(tester, _open);
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    final split = tester.getRect(list);
    await tester.tap(find.byType(BackButton));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(editor, findsOneWidget);
      expect(tester.getRect(list), split);
    }
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(tester.getRect(list).width, _open.width);

    // The note can open again before it has quite gone.
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    expect(tester.getRect(list), split);
    await close(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('nothing unpainted shows beside the list', (tester) async {
    await pump(tester, _open);
    final background = tester.widget<ColoredBox>(
      find.ancestor(of: list, matching: find.byType(ColoredBox)).first,
    );
    expect(background.color.a, 1);
    await close(tester);
  });

  testWidgets('a note can be asked for before the last one is built', (
    tester,
  ) async {
    await pump(tester, _open);
    final context = tester.element(find.text('first'));
    openNote(context, notes['first']!);
    // Pushed, but there has been no frame to build it.
    for (var i = 0; i < 20; i++) {
      await Future<void>.value();
    }
    expect(editor, findsNothing);
    openNote(context, notes['second']!);
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    expect(tester.widget<NoteEditor>(editor).note, same(notes['second']));
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(tester.widget<NoteEditor>(editor).note, same(notes['first']));
    await close(tester);
  });

  testWidgets('a note that closes before it is built leaves home alone', (
    tester,
  ) async {
    await pump(tester, _open);
    final context = tester.element(find.text('first'));
    openNote(context, notes['first']!);
    for (var i = 0; i < 20; i++) {
      await Future<void>.value();
    }
    openNote(context, notes['second']!);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    expect(tester.widget<NoteEditor>(editor).note, same(notes['second']));
    await close(tester);
  });

  for (final saves in [true, false]) {
    testWidgets(
      'a page of the list ${saves ? 'closes the note first' : 'waits for a note '
                'that cannot be saved'}',
      (tester) async {
        final note = _RecordingNote(saves: saves);
        notes['first'] = note;
        addTearDown(() => notes['first'] = Note(content: '[]'));
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(of: editor, matching: find.byType(TextField)).first,
          'Edited title',
        );
        final context = tester.element(find.text('first'));
        final settings = find.byKey(const Key('settings'));
        Object? result = 'open';
        showPage(
          context,
          const Scaffold(key: Key('settings')),
        ).then((value) => result = value);
        await tester.pumpAndSettle();
        expect(note.savedTitle, 'Edited title');
        expect(editor, saves ? findsNothing : findsOneWidget);
        expect(settings, saves ? findsOneWidget : findsNothing);
        expect(result, saves ? 'open' : isNull);
        if (saves) {
          tester.state<NavigatorState>(find.byType(Navigator)).pop('done');
          await tester.pumpAndSettle();
          expect(result, 'done');
          expect(list, findsOneWidget);
        }
        await close(tester);
      },
    );
  }

  for (final beside in [false, true]) {
    testWidgets('a sign-out that is never drawn takes the note'
        '${beside ? ' and the page beside it' : ''}', (tester) async {
      addTearDown(() => AuthService.signOutStage.value = null);
      final note = _RecordingNote(saves: true);
      notes['first'] = note;
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: editor, matching: find.byType(TextField)).first,
        'Old account',
      );
      if (beside) {
        openBesideNote(
          tester.element(find.byType(QuillEditor).first),
          const Scaffold(key: Key('page')),
        );
        await tester.pumpAndSettle();
      }
      final autosaved = note.savedTitle;
      // No frame is drawn in the background.
      AuthService.signOutStage.value = SignOutStage.working;
      AuthService.signOutStage.value = null;
      await tester.pump();
      expect(editor, findsNothing);
      expect(find.byKey(const Key('page')), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.getRect(list).width, _open.width);
      await tester.pump(const Duration(seconds: 5));
      expect(note.savedTitle, autosaved, reason: 'saves to the next library');
      // Notes still open as usual.
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('labels cannot change under an open note', (tester) async {
    await pump(tester, _open);
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    tester.state<ScaffoldState>(list).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Labels'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(editor, findsNothing);
    expect(find.byType(Labels), findsOneWidget);
    await close(tester);
  });

  testWidgets('a page from an open note leaves it open', (tester) async {
    await pump(tester, _open);
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    showPage(
      tester.element(find.byType(QuillEditor).first),
      const Scaffold(key: Key('settings')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings')), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    await close(tester);
  });

  testWidgets('a home screen built anew takes over the open note', (
    tester,
  ) async {
    resize(tester, _open);
    addTearDown(tester.view.reset);
    final generation = ValueNotifier(0);
    addTearDown(generation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder(
          valueListenable: generation,
          builder: (_, value, _) => NotePaneHost(
            key: ValueKey(value),
            child: Builder(
              builder: (context) => Scaffold(
                key: const Key('list'),
                body: Column(
                  children: [
                    for (final MapEntry(:key, :value) in notes.entries)
                      TextButton(
                        onPressed: () => openNote(context, value),
                        child: Text(key),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    final split = tester.getRect(list);
    final state = tester.state(editor);
    generation.value++;
    await tester.pumpAndSettle();
    expect(tester.state(editor), same(state));
    expect(tester.getRect(list), split);
    // The note is not opened twice.
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(tester.state(editor), same(state));
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(tester.widget<NoteEditor>(editor).note, same(notes['second']));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(tester.getRect(list).width, _open.width);
    await close(tester);
  });

  testWidgets('quick taps end on the last note', (tester) async {
    await pump(tester, _open);
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('second'));
    await tester.tap(find.text('first'));
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(editor, findsOneWidget);
    expect(tester.widget<NoteEditor>(editor).note, same(notes['second']));
    await close(tester);
  });

  for (final saves in [true, false]) {
    testWidgets(
      'switching notes ${saves ? 'saves' : 'stops if saving fails'}',
      (tester) async {
        final note = _RecordingNote(saves: saves);
        notes['first'] = note;
        addTearDown(() => notes['first'] = Note(content: '[]'));
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(of: editor, matching: find.byType(TextField)).first,
          'Edited title',
        );
        await tester.tap(find.text('second'));
        await tester.pumpAndSettle();
        expect(note.savedTitle, 'Edited title');
        expect(editor, findsOneWidget);
        expect(
          tester.widget<NoteEditor>(editor).note,
          same(saves ? notes['second'] : note),
        );
        if (!saves) {
          // The dropped request must not open later.
          note.saves = true;
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(editor, findsNothing);
        }
        await close(tester);
      },
    );
  }

  group('a page opened from a note', () {
    final page = find.byKey(const Key('page'));
    final checklist = find.byType(RichChecklistEditor);
    late final layout = NotePaneLayout.of(
      const MediaQueryData(size: _open, viewPadding: _duoInsets),
      TextDirection.ltr,
    )!;

    Future<dynamic> openPage(WidgetTester tester, {bool editable = false}) {
      final result = openBesideNote(
        tester.element(find.byType(QuillEditor).first),
        Scaffold(
          key: const Key('page'),
          body: Builder(
            builder: (context) => Column(
              children: [
                Text('page ${MediaQuery.sizeOf(context).width}'),
                const TextField(key: Key('field')),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'result'),
                  child: const Text('done'),
                ),
              ],
            ),
          ),
        ),
        noteStaysEditable: editable,
      );
      return result;
    }

    Note checklistNote({int items = 2}) => _RecordingNote(
      saves: true,
      content: jsonEncode([
        for (var i = 0; i < items; i++) ...[
          {'insert': 'Item $i'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
        ],
      ]),
    );

    QuillController shown(WidgetTester tester) => tester
        .widget<QuillEditor>(
          find.descendant(of: editor, matching: find.byType(QuillEditor)).first,
        )
        .controller;

    int checkedIn(QuillController controller) => controller.document
        .toDelta()
        .toList()
        .where((op) => op.attributes?['list'] == 'checked')
        .length;

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('moves the note aside and back ($platform)', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        final state = tester.state(editor);
        final before = tester.getRect(editor);

        final result = openPage(tester);
        // No gap opens between the panes while they move.
        await tester.pump();
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        expect(tester.state(editor), same(state));
        expect(
          tester.getRect(editor),
          Rect.fromLTWH(0, 0, layout.listWidth, _open.height),
        );
        expect(
          tester.getRect(page),
          Rect.fromLTRB(layout.listWidth, 0, _open.width, _open.height),
        );
        expect(find.text('page ${layout.paneWidth}'), findsOneWidget);

        await tester.tap(find.text('done'));
        await tester.pumpAndSettle();
        expect(await result, 'result');
        expect(page, findsNothing);
        expect(tester.state(editor), same(state));
        expect(tester.getRect(editor), before);
        expect(find.byType(BackButton), findsOneWidget);
        await close(tester);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('follows a fold and unfold with the note', (tester) async {
      await pump(tester, _folded);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      final state = tester.state(editor);
      openPage(tester);
      await tester.pumpAndSettle();
      expect(tester.getSize(page), _folded);
      expect(editor, findsNothing, reason: 'covered by the page');
      await tester.enterText(find.byKey(const Key('field')), 'typed');

      resize(tester, _open);
      await tester.pumpAndSettle();
      expect(tester.state(editor), same(state));
      expect(tester.getRect(editor).left, 0);
      expect(tester.getSize(editor).width, layout.listWidth);
      expect(tester.getRect(page).left, layout.listWidth);
      expect(find.text('typed'), findsOneWidget);

      resize(tester, _openPortrait);
      await tester.pumpAndSettle();
      expect(tester.getSize(page), _openPortrait);
      expect(editor, findsNothing);
      expect(find.text('typed'), findsOneWidget);

      resize(tester, _open);
      await tester.pumpAndSettle();
      resize(tester, _folded);
      await tester.pumpAndSettle();
      await tester.tap(find.text('done'));
      await tester.pumpAndSettle();
      expect(tester.state(editor), same(state));
      expect(tester.getSize(editor), _folded);
      await close(tester);
    });

    testWidgets('mirrors right to left', (tester) async {
      await pump(tester, _open, direction: TextDirection.rtl);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      openPage(tester);
      await tester.pumpAndSettle();
      expect(tester.getRect(page).left, 0);
      expect(tester.getRect(editor).right, _open.width);
      expect(tester.getRect(editor).left, tester.getRect(page).right);
      await close(tester);
    });

    testWidgets('a back swipe returns the note', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      openPage(tester);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        Offset(layout.listWidth + 4, 300),
      );
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // The note follows the finger, right up against the page.
      expect(tester.getRect(editor).left, greaterThan(0));
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(tester.getRect(editor).left, layout.listWidth);
      await close(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the note is for reading but still scrolls', (tester) async {
      notes['first'] = checklistNote(items: 60);
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      openPage(tester);
      await tester.pumpAndSettle();

      expect(find.byType(BackButton), findsNothing);
      expect(
        find.byKey(const ValueKey('note_editor_overflow_menu')),
        findsNothing,
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: editor, matching: find.byType(Scrollable)).first,
      );
      final positions = find
          .descendant(of: editor, matching: find.byType(Scrollable))
          .evaluate()
          .map((e) => (e as StatefulElement).state as ScrollableState)
          .where((state) => state.position.axis == Axis.vertical);
      final before = positions.map((s) => s.position.pixels).toList();
      await tester.dragFrom(const Offset(180, 400), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(positions.map((s) => s.position.pixels).toList(), isNot(before));
      expect(scroll.mounted, isTrue);
      expect(page, findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);

      // The note can be edited again afterwards.
      await tester.tap(find.text('done'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('note_editor_overflow_menu')),
        findsOneWidget,
      );
      await close(tester);
    });

    for (final pencil in [true, false]) {
      testWidgets(
        'a ${pencil ? 'pencil' : 'tap on the note'} leaves a checklist to edit',
        (tester) async {
          notes['first'] = checklistNote(items: 6);
          addTearDown(() => notes['first'] = Note(content: '[]'));
          await pump(tester, _open);
          await tester.tap(find.text('first'));
          await tester.pumpAndSettle();
          final controller = shown(tester);
          await tester.tap(
            find.byKey(const ValueKey('note_checkbox_progress_title')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .descendant(
                  of: checklist,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Semantics &&
                        widget.properties.checked == false,
                  ),
                )
                .first,
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump();
          final text = find.descendant(
            of: editor,
            matching: find.textContaining('Item 3', findRichText: true),
          );
          await tester.tapAt(
            pencil
                ? tester.getCenter(
                    find.byKey(const ValueKey('note_editor_edit_again')),
                  )
                : tester.getCenter(text.last),
          );
          await tester.pumpAndSettle();
          expect(checklist, findsNothing);
          expect(shown(tester), same(controller));
          expect(checkedIn(controller), 1, reason: 'a tap ticks nothing else');
          expect(
            tester
                .widget<QuillEditor>(
                  find
                      .descendant(
                        of: editor,
                        matching: find.byType(QuillEditor),
                      )
                      .first,
                )
                .focusNode
                .hasFocus,
            isTrue,
          );
          if (!pencil) {
            final body = controller.document.toPlainText();
            final start = body.indexOf('Item 3');
            expect(
              controller.selection.baseOffset,
              inInclusiveRange(start, start + 6),
            );
          }
          await tester.pump(const Duration(seconds: 2));
          await close(tester);
        },
      );
    }

    // Only a page that does not write the text of the note may leave it
    // editable, so check every way that a page opens from a note.
    final openers = <String, (bool, Future<void> Function(WidgetTester))>{
      'sketch from the attach button': (
        true,
        (tester) async {
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.draw));
        },
      ),
      'sketch from the toolbar': (
        true,
        (tester) async {
          await tester.tap(
            find.textContaining('Item 1', findRichText: true).last,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.draw).last);
        },
      ),
      'sketch from its thumbnail': (
        true,
        (tester) async {
          final thumbnail = find.descendant(
            of: find.byType(NoteAttachmentsCarousel),
            matching: find.byType(GestureDetector),
          );
          await tester.tapAt(
            tester.getTopLeft(thumbnail.first) + const Offset(20, 20),
          );
        },
      ),
      'checklist from the counter': (
        false,
        (tester) async {
          await tester.tap(
            find.byKey(const ValueKey('note_checkbox_progress_title')),
          );
        },
      ),
      'checklist from the list at the caret': (
        false,
        (tester) async {
          await tester.tap(
            find.textContaining('Item 1', findRichText: true).last,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('open_focused_checklist')),
          );
        },
      ),
    };
    for (final MapEntry(key: name, value: (editable, open))
        in openers.entries) {
      testWidgets('$name ${editable ? 'allows' : 'stops'} editing the note', (
        tester,
      ) async {
        final note = checklistNote(items: 3);
        if (name.contains('thumbnail')) {
          note.attachments.add(NoteAttachment.sketch(SketchData()));
        }
        notes['first'] = note;
        addTearDown(() => notes['first'] = Note(content: '[]'));
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        await open(tester);
        await tester.pumpAndSettle();

        final opened = name.startsWith('sketch')
            ? find.byType(SketchPage)
            : checklist;
        expect(tester.getRect(opened).left, layout.listWidth);
        expect(tester.getRect(editor).left, 0);
        final pencil = find.byKey(const ValueKey('note_editor_edit_again'));
        expect(pencil, editable ? findsNothing : findsOneWidget);
        if (editable) {
          // A second sketch of the same note cannot open.
          expect(find.byIcon(Icons.draw), findsNothing);
          await tester.tap(
            find
                .descendant(
                  of: editor,
                  matching: find.textContaining('Item 1', findRichText: true),
                )
                .last,
          );
          await tester.pumpAndSettle();
          expect(opened, findsOneWidget);
          expect(
            find.byKey(const ValueKey('open_focused_checklist')),
            findsNothing,
          );
        }
        await tester.pump(const Duration(seconds: 4));
        await close(tester);
      });
    }

    group('that leaves the note editable', () {
      Finder quill() =>
          find.descendant(of: editor, matching: find.byType(QuillEditor)).first;
      bool focused(WidgetTester tester) =>
          tester.widget<QuillEditor>(quill()).focusNode.hasFocus;

      Future<void> start(WidgetTester tester) async {
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        openPage(tester, editable: true);
        await tester.pumpAndSettle();
      }

      testWidgets('takes typing and keeps the page', (tester) async {
        await start(tester);
        await tester.tap(quill());
        await tester.pumpAndSettle();
        expect(focused(tester), isTrue);
        shown(
          tester,
        ).replaceText(0, 0, 'typed', const TextSelection.collapsed(offset: 5));
        await tester.pumpAndSettle();
        expect(shown(tester).document.toPlainText(), contains('typed'));
        expect(page, findsOneWidget);
        expect(tester.getRect(page).left, layout.listWidth);

        // Nothing that could close the note or take it away.
        expect(find.byType(BackButton), findsNothing);
        expect(
          find.byKey(const ValueKey('note_editor_overflow_menu')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('note_editor_search_action')),
          findsOneWidget,
        );
        await close(tester);
      });

      testWidgets('keeps its size above the keyboard of the note', (
        tester,
      ) async {
        await start(tester);
        MediaQueryData media() => MediaQuery.of(tester.element(page));
        final before = media();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        tester.view.padding = const FakeViewPadding(right: 84);
        await tester.pumpAndSettle();
        expect(media().viewInsets.bottom, 0);
        expect(media().padding.bottom, before.padding.bottom);
        expect(MediaQuery.of(tester.element(editor)).viewInsets.bottom, 300);
        await close(tester);
      });

      testWidgets('takes the keyboard when it is touched', (tester) async {
        await start(tester);
        await tester.tap(quill());
        await tester.pumpAndSettle();
        expect(focused(tester), isTrue);
        await tester.tapAt(Offset(_open.width - 200, 500));
        await tester.pumpAndSettle();
        expect(focused(tester), isFalse);
        await close(tester);
      });

      testWidgets('ignores a hand on the note while in use', (tester) async {
        await start(tester);
        final drawing = await tester.startGesture(
          Offset(_open.width - 200, 500),
        );
        await tester.tap(quill(), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 400));
        expect(focused(tester), isFalse);
        await drawing.up();
        await tester.pump();

        // A hand that was already resting on the note.
        final hand = await tester.startGesture(tester.getCenter(quill()));
        await tester.pump();
        final again = await tester.startGesture(
          Offset(_open.width - 200, 500),
          pointer: 7,
        );
        await hand.up();
        await tester.pump();
        await again.up();
        await tester.pumpAndSettle();
        expect(focused(tester), isFalse);

        await tester.tap(quill());
        await tester.pumpAndSettle();
        expect(focused(tester), isTrue);
        await close(tester);
      });

      testWidgets('takes the keyboard when it covers the note', (tester) async {
        await start(tester);
        await tester.tap(quill());
        await tester.pumpAndSettle();
        final focus = tester.widget<QuillEditor>(quill()).focusNode;
        expect(focus.hasFocus, isTrue);
        resize(tester, _folded);
        await tester.pumpAndSettle();
        expect(tester.getSize(page), _folded);
        expect(focus.hasFocus, isFalse);
        expect(
          FocusScope.of(tester.element(find.byKey(const Key('field'))))
              .hasFocus,
          isTrue,
        );
        await close(tester);
      });
    });

    testWidgets('a checklist shows its edits in the note', (tester) async {
      notes['first'] = checklistNote();
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      final original = shown(tester);
      await tester.tap(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
      );
      await tester.pumpAndSettle();
      expect(checklist, findsOneWidget);
      expect(tester.getRect(checklist).left, layout.listWidth);
      expect(checkedIn(shown(tester)), 0);

      await tester.tap(
        find
            .descendant(
              of: checklist,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.checked == false,
              ),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(checkedIn(shown(tester)), 1, reason: 'before the checklist saves');
      expect(shown(tester), isNot(same(original)));
      expect(checkedIn(original), 0, reason: 'changes when it closes');

      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(checklist, findsNothing);
      expect(shown(tester), same(original));
      expect(checkedIn(original), 1);
      expect(original.hasUndo, isTrue, reason: 'keeps the undo history');
      await close(tester);
    });

    testWidgets('edits made folded show after unfolding', (tester) async {
      notes['first'] = checklistNote();
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _folded);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: checklist,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.checked == false,
              ),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 100));
      resize(tester, _open);
      await tester.pumpAndSettle();
      expect(checkedIn(shown(tester)), 1);
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
    });

    testWidgets('opens once however quickly it is asked for', (tester) async {
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      openPage(tester);
      openPage(tester);
      await tester.pumpAndSettle();
      expect(page, findsOneWidget);
      await tester.tap(find.text('done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page'), skipOffstage: false), findsNothing);
      await close(tester);
    });

    Future<void> tickFirst(WidgetTester tester) => tester.tap(
      find
          .descendant(
            of: checklist,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.checked == false,
            ),
          )
          .first,
    );

    for (final back in [true, false]) {
      testWidgets('a tick does not outlive a checklist that '
          '${back ? 'closes' : 'is popped'} at once', (tester) async {
        notes['first'] = checklistNote();
        addTearDown(() => notes['first'] = Note(content: '[]'));
        await pump(tester, _open);
        await tester.tap(find.text('first'));
        await tester.pumpAndSettle();
        final original = shown(tester);
        await tester.tap(
          find.byKey(const ValueKey('note_checkbox_progress_title')),
        );
        await tester.pumpAndSettle();
        await tickFirst(tester);
        await tester.pump(const Duration(milliseconds: 10));
        if (back) {
          await tester.tap(find.byType(BackButton));
        } else {
          tester.state<NavigatorState>(find.byType(Navigator)).pop();
        }
        await tester.idle();
        // The delayed preview comes due before the next frame.
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(checklist, findsNothing);
        expect(shown(tester), same(original));
        await tester.pump(const Duration(seconds: 2));
        await close(tester);
      });
    }

    testWidgets('a double tap opens one checklist that shows its edits', (
      tester,
    ) async {
      notes['first'] = checklistNote();
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      final counter = find.byKey(
        const ValueKey('note_checkbox_progress_title'),
      );
      await tester.tap(counter);
      await tester.tap(counter);
      await tester.pumpAndSettle();
      expect(checklist, findsOneWidget);
      expect(find.byTooltip('Edit note'), findsOneWidget);
      await tickFirst(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(checkedIn(shown(tester)), 1);
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
    });

    testWidgets('edits stay in the note through a fold', (tester) async {
      notes['first'] = checklistNote();
      addTearDown(() => notes['first'] = Note(content: '[]'));
      await pump(tester, _open);
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
      );
      await tester.pumpAndSettle();
      await tickFirst(tester);
      await tester.pump(const Duration(milliseconds: 300));
      for (final size in [_folded, _open]) {
        resize(tester, size);
        await tester.pumpAndSettle();
      }
      expect(checkedIn(shown(tester)), 1);
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
    });

    testWidgets('a checklist prepares nothing for a note it covers', (
      tester,
    ) async {
      var previews = 0;
      final wanted = ValueNotifier(false);
      final note = checklistNote();
      await pump(tester, _folded);
      final session = ChecklistDeltaCodec().createCollectionEditSession(
        title: '',
        document: Document.fromJson(jsonDecode(note.content!) as List),
        selectionStart: 0,
        selectionEnd: 0,
      )!;
      Navigator.of(tester.element(list)).push(
        MaterialPageRoute<void>(
          builder: (_) => RichChecklistCollectionEditor(
            note: note,
            session: session,
            onPreview: (_) => previews++,
            previewWanted: wanted,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tick() async {
        await tester.tap(
          find
              .descendant(
                of: checklist,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics && widget.properties.checked == false,
                ),
              )
              .first,
        );
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tick();
      expect(previews, 0);
      // The edits made meanwhile arrive as soon as the note can be seen.
      wanted.value = true;
      await tester.pump(const Duration(milliseconds: 300));
      expect(previews, 1);
      await tick();
      expect(previews, 2);
      await tester.pump(const Duration(seconds: 2));
      await close(tester);
    });

    testWidgets('keeps its place when the note is not in a pane', (
      tester,
    ) async {
      resize(tester, _open);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NoteEditor(note: Note(content: '[]')),
        ),
      );
      await tester.pumpAndSettle();
      openPage(tester);
      await tester.pumpAndSettle();
      expect(page, findsOneWidget);
      expect(tester.getSize(editor), _open);
      await close(tester);
    });
  });

  for (final attached in [false, true]) {
    testWidgets(
      attached
          ? 'an unchanged new list is kept for its attachment'
          : 'an unchanged new list is deleted',
      (tester) async {
        final note = _RecordingNote(saves: true)..id = 7;
        if (attached) {
          note.attachments.add(NoteAttachment.sketch(SketchData()));
        }
        resize(tester, _folded);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(),
          ),
        );
        openNote(
          tester.element(find.byType(Scaffold)),
          note,
          deleteIfUnchanged: true,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(editor, findsNothing);
        expect(note.deleted, !attached);
        await close(tester);
      },
    );
  }
}

class _RecordingNote extends Note {
  _RecordingNote({required this.saves, super.content = '[]'});

  bool saves;
  String? savedTitle;
  bool deleted = false;

  @override
  Future<int> delete({
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  }) async {
    deleted = true;
    return 1;
  }

  @override
  Future<int> saveEditorSnapshot({
    required String title,
    required String content,
    required String plainText,
    bool trackSync = true,
  }) async {
    savedTitle = title;
    return saves ? 1 : -1;
  }
}
