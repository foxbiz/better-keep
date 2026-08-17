import 'dart:convert';

import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  testWidgets('find, navigate, replace all, and undo stay in one editor', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha beta alpha alpha');
    expect(
      find.byKey(const ValueKey('note_editor_color_action')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pump();
    expect(find.byKey(const ValueKey('note_find_bar')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('note_find_query')),
      'alpha',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    expect(find.text('1/3'), findsOneWidget);
    _expectFindInputFillsToOptions(tester);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('note_find_query')))
          .contains(tester.getCenter(find.text('1/3'))),
      isTrue,
    );

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(
      editor.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );

    await tester.tap(find.byKey(const ValueKey('note_find_next')));
    await tester.pump();
    expect(editor.controller.selection.start, 11);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note_find_query')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('note_find_toggle_replace')));
    await tester.pump();
    _expectFindAndReplaceAligned(tester);
    await tester.enterText(
      find.byKey(const ValueKey('note_find_replacement')),
      'omega',
    );
    await tester.tap(find.byKey(const ValueKey('note_find_replace_all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      editor.controller.document.toPlainText(),
      'omega beta omega omega\n',
    );
    expect(find.text('Replaced 3 occurrences'), findsOneWidget);

    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pump();
    expect(
      editor.controller.document.toPlainText(),
      'alpha beta alpha alpha\n',
    );
  });

  testWidgets('regex errors are inline and smart mode hides replacement', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'meeting tomorrow');
    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note_find_option_regex')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('note_find_query')), '(');
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Invalid regular expression'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note_find_option_smart')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('note_find_query')),
      'mtg tmrw',
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('1/1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note_find_toggle_replace')),
      findsNothing,
    );
  });

  testWidgets('a non-empty body selection seeds find and anchors its match', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha beta alpha');
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.controller.updateSelection(
      const TextSelection(baseOffset: 11, extentOffset: 16),
      ChangeSource.local,
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('note_find_query')))
          .controller
          ?.text,
      'alpha',
    );
    expect(editor.controller.selection.start, 11);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('large counts compact visually and retain their exact label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpEditor(
      tester,
      body: List.filled(1234, 'x').join(' '),
      configureView: false,
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('note_find_query')), 'x');
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('1/1.2K'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('1 of 1234')), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('note_find_result_count')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(tooltip.message, '1 of 1234');
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('localized compact counts stay bounded inside the suffix', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpEditor(
      tester,
      body: 'x' * 10000,
      configureView: false,
      locale: const Locale('ja'),
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('note_find_query')), 'x');
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.textContaining('万'), findsOneWidget);
    final countRect = tester.getRect(
      find.byKey(const ValueKey('note_find_result_count')),
    );
    final inputRect = tester.getRect(
      find.byKey(const ValueKey('note_find_query')),
    );
    expect(inputRect.contains(countRect.center), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact app bar moves Color into overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpEditor(tester, body: 'body', configureView: false);

    expect(
      find.byKey(const ValueKey('note_editor_search_action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('note_editor_color_action')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_overflow_menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('note_editor_overflow_color_action')),
      findsOneWidget,
    );

    await tester.tapAt(const Offset(10, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note_find_query')), findsOneWidget);
    _expectFindControlsOnSameRow(tester);
    _expectFindInputFillsToOptions(tester);
    await tester.tap(find.byKey(const ValueKey('note_find_toggle_replace')));
    await tester.pump();
    _expectFindAndReplaceAligned(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('find and replace inputs align at the start in RTL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpEditor(
      tester,
      body: 'alpha',
      configureView: false,
      textDirection: TextDirection.rtl,
    );

    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();
    _expectFindInputFillsToOptions(tester, textDirection: TextDirection.rtl);
    await tester.tap(find.byKey(const ValueKey('note_find_toggle_replace')));
    await tester.pump();

    _expectFindAndReplaceAligned(tester, textDirection: TextDirection.rtl);
  });

  testWidgets('editor shortcuts open, navigate, wrap, and close find', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha beta alpha');
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note_find_bar')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('note_find_query')),
      'alpha',
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(editor.controller.selection.start, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(editor.controller.selection.start, 11);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(editor.controller.selection.start, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pump();
    expect(editor.controller.selection.start, 11);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(editor.controller.selection.start, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note_find_bar')), findsNothing);
    expect(editor.focusNode.hasFocus, isTrue);
  });

  testWidgets('read-only notes remain searchable without replacement', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha alpha', readOnly: true);
    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('note_find_query')),
      'alpha',
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('1/2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note_find_toggle_replace')),
      findsNothing,
    );
  });

  testWidgets('Ctrl+H opens replace on Windows and Linux platforms', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha', platform: TargetPlatform.windows);
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('note_find_bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('note_find_replacement')), findsOneWidget);
  });

  testWidgets('trashed notes remain searchable without replacement', (
    tester,
  ) async {
    await _pumpEditor(tester, body: 'alpha alpha', trashed: true);
    await tester.tap(find.byKey(const ValueKey('note_editor_search_action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('note_find_query')),
      'alpha',
    );
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('1/2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note_find_toggle_replace')),
      findsNothing,
    );
  });

  testWidgets('Cmd+Option+F opens replace on macOS', (tester) async {
    await _pumpEditor(tester, body: 'alpha');
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('note_find_bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('note_find_replacement')), findsOneWidget);
  });
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String body,
  bool readOnly = false,
  bool trashed = false,
  bool configureView = true,
  TargetPlatform platform = TargetPlatform.macOS,
  TextDirection textDirection = TextDirection.ltr,
  Locale locale = const Locale('en'),
}) async {
  if (configureView) {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  final content = jsonEncode([
    {'insert': 'Search note'},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
    {'insert': '$body\n'},
  ]);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      locale: locale,
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: Directionality(
        textDirection: textDirection,
        child: NoteEditor(
          note: Note(
            title: 'Search note',
            content: content,
            readOnly: readOnly,
            trashed: trashed,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectFindAndReplaceAligned(
  WidgetTester tester, {
  TextDirection textDirection = TextDirection.ltr,
}) {
  final findRect = tester.getRect(
    find.byKey(const ValueKey('note_find_query')),
  );
  final replaceRect = tester.getRect(
    find.byKey(const ValueKey('note_find_replacement')),
  );
  if (textDirection == TextDirection.ltr) {
    expect(replaceRect.left, findRect.left);
  } else {
    expect(replaceRect.right, findRect.right);
  }
}

void _expectFindControlsOnSameRow(WidgetTester tester) {
  final findCenterY = tester
      .getCenter(find.byKey(const ValueKey('note_find_query')))
      .dy;
  for (final key in const [
    'note_find_toggle_replace',
    'note_find_options',
    'note_find_previous',
    'note_find_next',
    'note_find_close',
  ]) {
    expect(
      tester.getCenter(find.byKey(ValueKey(key))).dy,
      closeTo(findCenterY, 0.01),
    );
  }
}

void _expectFindInputFillsToOptions(
  WidgetTester tester, {
  TextDirection textDirection = TextDirection.ltr,
}) {
  final findRect = tester.getRect(
    find.byKey(const ValueKey('note_find_query')),
  );
  final optionsRect = tester.getRect(
    find.byKey(const ValueKey('note_find_options')),
  );
  if (textDirection == TextDirection.ltr) {
    expect(findRect.right, optionsRect.left);
  } else {
    expect(findRect.left, optionsRect.right);
  }
}
