import 'dart:convert';
import 'dart:math';

import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/components/duo_safe_area.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/home/home_layout.dart';
import 'package:better_keep/pages/home/note_pane.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_app_bar.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Layouts made for iPhone Duo must leave every other device as it was. The
/// last device has the very window of an open iPhone Duo.
const _devices = <(String, Size, EdgeInsets)>[
  ('iPhone SE', Size(375, 667), EdgeInsets.only(top: 20)),
  ('iPhone 17 Pro', Size(402, 874), EdgeInsets.only(top: 62, bottom: 34)),
  ('iPhone 17 Pro Max', Size(440, 956), EdgeInsets.only(top: 62, bottom: 34)),
  ('small Android phone', Size(360, 640), EdgeInsets.only(top: 24)),
  (
    'Android phone on its side',
    Size(915, 412),
    EdgeInsets.only(left: 48, right: 48),
  ),
  ('Android foldable', Size(841, 701), EdgeInsets.only(top: 24)),
  ('Android tablet', Size(1280, 800), EdgeInsets.only(top: 24)),
  ('iPad mini', Size(1133, 744), EdgeInsets.only(top: 24, bottom: 20)),
  ('iPad Pro 13', Size(1376, 1032), EdgeInsets.only(top: 24, bottom: 20)),
  ('desktop', Size(1440, 900), EdgeInsets.zero),
  (
    'a window like an open iPhone Duo',
    Size(951, 669),
    EdgeInsets.only(right: 84, bottom: 34),
  ),
];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  void use(WidgetTester tester, Size size, EdgeInsets insets) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    final padding = FakeViewPadding(
      left: insets.left,
      top: insets.top,
      right: insets.right,
      bottom: insets.bottom,
    );
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );

  test('only the model of iPhone Duo is one', () {
    expect(isIPhoneDuo, isFalse);
    expect(isIPhoneDuoModel('iPhone19,4'), isTrue);
    for (final model in [
      'iPhone19,1',
      'iPhone19,40',
      'iPhone18,4',
      'iPhone14,7',
      'iPad16,6',
      'arm64',
      '',
    ]) {
      expect(isIPhoneDuoModel(model), isFalse, reason: model);
    }
  });

  for (final (name, size, insets) in _devices) {
    test('$name never shows two panes', () {
      final media = MediaQueryData(size: size, viewPadding: insets);
      for (final direction in TextDirection.values) {
        expect(NotePaneLayout.of(media, direction), isNull);
      }
      final height = size.height - insets.vertical;
      final width = size.width - insets.horizontal;
      expect(hasRoomForHomeSidebar(media), width >= 800 && height >= 640);
    });

    testWidgets('$name opens a note and a page as before', (tester) async {
      use(tester, size, insets);
      late BuildContext list;
      await tester.pumpWidget(
        app(
          NotePaneHost(
            child: Builder(
              builder: (context) {
                list = context;
                return const Scaffold(key: Key('list'));
              },
            ),
          ),
        ),
      );
      final home = tester.getSize(find.byKey(const Key('list')));
      final media = MediaQuery.of(list);
      openNote(list, Note(content: '[]'));
      await tester.pumpAndSettle();
      final editor = find.byType(NoteEditor);
      final route = ModalRoute.of(tester.element(editor));

      // The route that the app has always used for this window.
      showPageReference(list);
      await tester.pumpAndSettle();
      final reference = ModalRoute.of(
        tester.element(find.byKey(const Key('reference'))),
      );
      expect(route.runtimeType, reference.runtimeType);
      Navigator.of(list).pop();
      await tester.pumpAndSettle();

      expect(MediaQuery.of(list), media, reason: 'the list keeps its size');
      expect(
        tester.getSize(find.byKey(const Key('list'), skipOffstage: false)),
        home,
      );
      final inEditor = tester.element(editor);
      expect(NotePaneHost.isSideBySide(inEditor), isFalse);
      expect(NotePaneHost.hasPageBeside(inEditor), isFalse);
      expect(NotePaneHost.heroesEnabled(inEditor), isTrue);

      final before = tester.getSize(editor);
      openBesideNote(inEditor, const Scaffold(key: Key('page')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('page')), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byKey(const Key('page'))))
            .runtimeType,
        reference.runtimeType,
      );
      expect(
        tester.getSize(find.byType(NoteEditor, skipOffstage: false)),
        before,
        reason: 'the note does not move aside',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('$name keeps its page insets', (tester) async {
      use(tester, size, insets);
      await tester.pumpWidget(
        app(
          const Scaffold(
            body: DuoSafeArea(child: SizedBox.expand(key: Key('body'))),
          ),
        ),
      );
      final body = tester.getRect(find.byKey(const Key('body')));
      expect(body.left, 0);
      expect(body.right, size.width);
    });

    testWidgets('$name fits a sketch as before', (tester) async {
      use(tester, size, insets);
      await tester.pumpWidget(
        app(SketchPage(note: Note(), sketch: SketchData())),
      );
      await tester.pumpAndSettle();
      final canvas = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is SketchPainter,
      );
      final rect = tester.getRect(canvas);
      final box = tester.renderObject<RenderBox>(canvas).size;
      final scale = min(size.width / box.width, size.height / box.height) * .95;
      expect(rect.width, closeTo(box.width * scale, 0.5));
      expect(rect.center.dx, closeTo(size.width / 2, 0.5));

      // A resize leaves it where it was, as it always has.
      tester.view.physicalSize = Size(size.width + 60, size.height);
      await tester.pumpAndSettle();
      expect(tester.getRect(canvas), rect);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('$name places a menu as before', (tester) async {
      use(tester, size, insets);
      final controller = AdaptivePopupController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: AdaptivePopupMenu(
                controller: controller,
                items: (_) => const [
                  AdaptiveMenuItem(icon: Icons.image, label: 'Image'),
                ],
                child: const SizedBox(width: 48, height: 48),
              ),
            ),
          ),
        ),
      );
      controller.open();
      await tester.pumpAndSettle();
      // Measured before there were any layouts for iPhone Duo. A wide window
      // has always let this menu pass its edge.
      final wide = size.width >= 600;
      final left = size.width < 900 ? 356.0 : 376.0;
      expect(
        tester.getRect(
          find
              .ancestor(
                of: find.text('Image'),
                matching: find.byType(ClipRRect),
              )
              .first,
        ),
        Rect.fromLTRB(
          wide ? size.width - left : 16,
          size.height - 120,
          wide ? size.width - left + 400 : size.width - 16,
          size.height - 56,
        ),
      );
    });
  }

  for (final (size, icon) in [
    (const Size(375, 667), false),
    (const Size(390, 844), false),
    (const Size(393, 852), false),
    (const Size(402, 874), true),
    (const Size(440, 956), true),
  ]) {
    testWidgets('the title bar of a note is unchanged at $size', (
      tester,
    ) async {
      use(tester, size, EdgeInsets.zero);
      await tester.pumpWidget(
        app(
          NoteEditor(
            note: Note(
              content: jsonEncode([
                {'insert': 'A'},
                {
                  'insert': '\n',
                  'attributes': {'list': 'unchecked'},
                },
              ]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final counter = find.byType(NoteCheckboxProgressTitle);
      for (final action in ['search', 'reminder', 'pin', 'labels']) {
        // The test font is twice as wide as a real one, so a 375 point phone
        // may need one action to move. No real text there does.
        if (size.width < 380 && action == 'labels') continue;
        expect(
          find.byKey(ValueKey('note_editor_${action}_action')),
          findsOneWidget,
          reason: action,
        );
      }
      if (size.width > 402) {
        expect(
          find.descendant(of: counter, matching: find.byIcon(Icons.checklist)),
          findsOneWidget,
        );
      } else if (!icon) {
        expect(
          find.descendant(of: counter, matching: find.byIcon(Icons.checklist)),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}

void showPageReference(BuildContext context) => showPage(
  context,
  const Scaffold(key: Key('reference')),
  allowFullScreen: true,
);
