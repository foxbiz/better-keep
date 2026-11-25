import 'dart:convert';

import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugIsIPhoneDuoOverride = true);
  tearDown(() => debugIsIPhoneDuoOverride = null);

  Future<void> pumpBar(
    WidgetTester tester, {
    required Size size,
    EdgeInsets inset = EdgeInsets.zero,
    int checked = 1,
    int total = 3,
    double textScale = 1,
    Color background = Colors.white,
    Color foreground = Colors.black,
    TextDirection direction = TextDirection.ltr,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        builder: (context, child) => Directionality(
          textDirection: direction,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: inset,
              viewPadding: inset,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
        ),
        home: Scaffold(
          appBar: NoteEditorAppBar(
            backgroundColor: background,
            foregroundColor: foreground,
            leading: const BackButton(),
            title: NoteCheckboxProgressTitle(
              checked: checked,
              total: total,
              backgroundColor: background,
              foregroundColor: foreground,
              onTap: () {},
            ),
            actions: [
              for (var i = 0; i < 5; i++)
                IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const foldedDuo = Size(466, 678);
  const foldedInset = EdgeInsets.only(right: 84, bottom: 34);

  testWidgets('the checked count fits beside the folded iPhone Duo clock', (
    tester,
  ) async {
    await pumpBar(tester, size: foldedDuo, inset: foldedInset);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.checklist), findsNothing);
    expect(find.text('1/3'), findsOneWidget);
    final target = find.byKey(const ValueKey('note_checkbox_progress_title'));
    expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
    expect(
      tester
          .getRect(target)
          .overlaps(tester.getRect(find.byIcon(Icons.search).first)),
      isFalse,
    );
  });

  for (final (name, checked, total, scale, direction) in [
    ('long counts', 128, 256, 1.0, TextDirection.ltr),
    ('large text', 10, 12, 2.0, TextDirection.ltr),
    ('right to left', 10, 12, 1.0, TextDirection.rtl),
  ]) {
    for (final size in [
      foldedDuo,
      const Size(375, 667),
      const Size(402, 874),
    ]) {
      testWidgets('the checked count never overflows: $name at $size', (
        tester,
      ) async {
        await pumpBar(
          tester,
          size: size,
          inset: size == foldedDuo ? foldedInset : EdgeInsets.zero,
          checked: checked,
          total: total,
          textScale: scale,
          direction: direction,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the checked count keeps its icon when there is room', (
    tester,
  ) async {
    await pumpBar(tester, size: const Size(524, 669));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.checklist), findsOneWidget);
  });

  for (final (name, background, foreground, green) in [
    ('white', Colors.white, Colors.black, false),
    ('light green', const Color(0xFFE0EFE7), Colors.black, false),
    ('green', Colors.green, Colors.black, false),
    ('black', Colors.black, Colors.white, true),
  ]) {
    testWidgets('a completed count stands out on a $name note', (tester) async {
      await pumpBar(
        tester,
        size: const Size(524, 669),
        checked: 3,
        background: background,
        foreground: foreground,
      );
      final expected = green ? Colors.green : foreground;
      expect(tester.widget<Text>(find.text('3/3')).style?.color, expected);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
        expected,
      );
    });
  }

  group('editor actions', () {
    final movable = NoteEditorMenuAction.values.map((action) => action.name);

    Future<void> pumpEditor(
      WidgetTester tester, {
      required Size size,
      EdgeInsets inset = EdgeInsets.zero,
      int items = 3,
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: inset,
              viewPadding: inset,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          home: NoteEditor(
            note: Note(
              title: 'Trip',
              content: jsonEncode([
                if (items == 0) {'insert': 'Text\n'},
                for (var i = 0; i < items; i++) ...[
                  {'insert': 'Item $i'},
                  {
                    'insert': '\n',
                    'attributes': {'list': i == 0 ? 'checked' : 'unchecked'},
                  },
                ],
              ]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Set<String> inBar(WidgetTester tester) => {
      for (final name in movable)
        if (find
            .byKey(ValueKey('note_editor_${name}_action'))
            .evaluate()
            .isNotEmpty)
          name,
    };

    Set<String> inMenu(WidgetTester tester) => {
      for (final name in movable)
        if (find
            .byKey(ValueKey('note_editor_overflow_${name}_action'))
            .evaluate()
            .isNotEmpty)
          name,
    };

    for (final (name, size, inset, items, scale) in [
      ('folded iPhone Duo', foldedDuo, foldedInset, 3, 1.0),
      ('folded iPhone Duo, long list', foldedDuo, foldedInset, 120, 1.0),
      ('folded iPhone Duo, large text', foldedDuo, foldedInset, 12, 2.0),
      ('small phone', const Size(320, 568), EdgeInsets.zero, 3, 1.0),
      ('wide window', const Size(1000, 900), EdgeInsets.zero, 3, 1.0),
    ]) {
      testWidgets('each action is in the bar or the menu: $name', (
        tester,
      ) async {
        await pumpEditor(
          tester,
          size: size,
          inset: inset,
          items: items,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        final bar = inBar(tester);

        await tester.tap(
          find.byKey(const ValueKey('note_editor_overflow_menu')),
        );
        await tester.pumpAndSettle();
        final menu = inMenu(tester);

        expect(bar.intersection(menu), isEmpty);
        expect(bar.union(menu), movable.toSet());
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a folded iPhone Duo keeps the whole count', (tester) async {
      await pumpEditor(tester, size: foldedDuo, inset: foldedInset);
      expect(find.byIcon(Icons.checklist), findsOneWidget);
      expect(inBar(tester), isNot(contains('labels')));
    });

    testWidgets('actions stay in the bar without a count', (tester) async {
      await pumpEditor(tester, size: foldedDuo, inset: foldedInset, items: 0);
      expect(inBar(tester), {'labels', 'pin', 'reminder'});
    });

    testWidgets('pin works from the menu', (tester) async {
      await pumpEditor(tester, size: const Size(320, 568));
      final pin = find.byKey(const ValueKey('note_editor_overflow_pin_action'));
      await tester.tap(find.byKey(const ValueKey('note_editor_overflow_menu')));
      await tester.pumpAndSettle();
      final note = tester.widget<NoteEditor>(find.byType(NoteEditor)).note!;
      expect(note.pinned, isFalse);
      await tester.tap(
        find.descendant(of: pin, matching: find.byType(CheckboxListTile)),
      );
      await tester.pumpAndSettle();
      expect(pin, findsNothing);
      expect(note.pinned, isTrue);
    });
  });
}
