import 'dart:convert';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/note_editor/table/note_table_button.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/pages/note_editor/table/note_table_embed.dart';
import 'package:better_keep/services/note_table_codec.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editable note toolbar exposes table insertion sheet', (
    tester,
  ) async {
    final quill = QuillController(
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final parentFocus = FocusNode();
    final coordinator = NoteTableController(
      controller: quill,
      parentFocusNode: parentFocus,
    );
    addTearDown(() {
      coordinator.dispose();
      quill.dispose();
      parentFocus.dispose();
    });

    await tester.pumpWidget(
      _testApp(
        NoteEditorToolbar(
          controller: quill,
          focusNode: parentFocus,
          readOnly: false,
          parentColor: Colors.white,
          showHistory: false,
          showAttachments: false,
          showChecklist: false,
          tableController: coordinator,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('insert_table_button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('insert_table_button')));
    await tester.pumpAndSettle();

    expect(find.text('2 × 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('insert_table_confirm')), findsOneWidget);
  });

  testWidgets('only the focused table cell becomes a multiline TextField', (
    tester,
  ) async {
    final table = NoteTable(
      id: 'table',
      rows: const [
        ['one', 'two'],
        ['three', 'four'],
      ],
    );
    final document = Document.fromDelta(
      Delta()
        ..insert(NoteTableCodec.encodeInsert(table))
        ..insert('\n'),
    );
    final quill = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    final parentFocus = FocusNode();
    final coordinator = NoteTableController(
      controller: quill,
      parentFocusNode: parentFocus,
    );
    addTearDown(() {
      coordinator.dispose();
      quill.dispose();
      parentFocus.dispose();
    });

    await tester.pumpWidget(
      _testApp(
        NoteTableEmbed(
          table: table,
          readOnly: false,
          parentColor: Colors.white,
          presentation: NoteTablePresentation.editor,
          tableController: coordinator,
        ),
      ),
    );

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('one'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('note_table_active_cell')),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('note_table_active_cell')),
      'line one\nline two',
    );
    coordinator.flushActive();
    expect(coordinator.activeTable?.cellAt(0, 0), 'line one\nline two');
  });

  testWidgets(
    'cell draft does not mutate Quill or reset selection while typing',
    (tester) async {
      final table = NoteTable(
        id: 'draft-table',
        rows: const [
          ['original'],
        ],
      );
      final document = Document.fromDelta(
        Delta()
          ..insert(NoteTableCodec.encodeInsert(table))
          ..insert('\n'),
      );
      final quill = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );
      final parentFocus = FocusNode();
      var draftNotifications = 0;
      final coordinator = NoteTableController(
        controller: quill,
        parentFocusNode: parentFocus,
        onDraftChanged: () => draftNotifications += 1,
      );
      final changes = <DocChange>[];
      final subscription = quill.changes.listen(changes.add);
      addTearDown(subscription.cancel);
      addTearDown(() {
        coordinator.dispose();
        quill.dispose();
        parentFocus.dispose();
      });

      await tester.pumpWidget(
        _testApp(
          NoteTableEmbed(
            table: table,
            readOnly: false,
            parentColor: Colors.white,
            presentation: NoteTablePresentation.editor,
            tableController: coordinator,
          ),
        ),
      );
      await tester.tap(find.text('original'));
      await tester.pump();

      const draft = TextEditingValue(
        text: 'edited value',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 5),
      );
      tester.testTextInput.updateEditingValue(draft);
      await tester.pump(const Duration(milliseconds: 350));

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('note_table_active_cell')),
      );
      expect(field.controller?.value, draft);
      expect(coordinator.activeTable?.cellAt(0, 0), 'original');
      expect(changes, isEmpty);
      expect(draftNotifications, 1);

      coordinator.flushActive();
      await tester.pump();

      expect(coordinator.activeTable?.cellAt(0, 0), 'edited value');
      expect(changes, isNotEmpty);
      expect(field.controller?.selection, draft.selection);
      quill.undo();
      expect(coordinator.activeTable?.cellAt(0, 0), 'original');
    },
  );

  testWidgets('table history reconciles the visible focused cell', (
    tester,
  ) async {
    final table = NoteTable(
      id: 'history-table',
      rows: const [
        ['before'],
      ],
    );
    final quill = QuillController(
      document: Document.fromDelta(
        Delta()
          ..insert(NoteTableCodec.encodeInsert(table))
          ..insert('\n'),
      ),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final parentFocus = FocusNode();
    final coordinator = NoteTableController(
      controller: quill,
      parentFocusNode: parentFocus,
    );
    addTearDown(() {
      coordinator.dispose();
      quill.dispose();
      parentFocus.dispose();
    });

    await tester.pumpWidget(
      _testApp(
        AnimatedBuilder(
          animation: quill,
          builder: (context, _) {
            final current = coordinator.findTable(table.id)?.table ?? table;
            return NoteTableEmbed(
              table: current,
              readOnly: false,
              parentColor: Colors.white,
              presentation: NoteTablePresentation.editor,
              tableController: coordinator,
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('before'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('note_table_active_cell')),
      'after',
    );

    coordinator.undo();
    await tester.pump();
    expect(coordinator.activeTable?.cellAt(0, 0), 'before');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('note_table_active_cell')),
          )
          .controller
          ?.text,
      'before',
    );
    expect(coordinator.isCellInputFocused, isTrue);

    coordinator.redo();
    await tester.pump();
    expect(coordinator.activeTable?.cellAt(0, 0), 'after');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('note_table_active_cell')),
          )
          .controller
          ?.text,
      'after',
    );
  });

  testWidgets('cell Backspace never reaches the parent Quill document', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final table = NoteTable(
      id: 'editor-table',
      rows: const [
        ['alpha'],
      ],
    );
    final note = Note(
      title: 'Table note',
      content: jsonEncode([
        {'insert': 'Table note'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': 'before\n'},
        {'insert': NoteTableCodec.encodeInsert(table)},
        {'insert': '\nafter\n'},
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NoteEditor(note: note),
      ),
    );
    await tester.pump();
    final quill = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    quill.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.text('alpha'));
    await tester.pump();
    await tester.pump();
    final parentDelta = quill.document.toDelta().toJson();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('note_table_active_cell')),
    );
    expect(field.focusNode?.hasPrimaryFocus, isTrue);
    await tester.pump(const Duration(milliseconds: 550));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(field.controller?.text, 'alpha');
    expect(quill.document.toDelta().toJson(), parentDelta);

    field.controller?.selection = const TextSelection.collapsed(offset: 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(field.controller?.text, 'alpha');
    expect(quill.document.toDelta().toJson(), parentDelta);

    field.controller?.selection = const TextSelection.collapsed(offset: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(field.controller?.text, 'apha');
    expect(quill.document.toDelta().toJson(), parentDelta);
    await tester.pump(const Duration(milliseconds: 550));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(field.controller?.text, 'alpha');
    expect(quill.document.toDelta().toJson(), parentDelta);

    final cellFocus = find.byWidgetPredicate(
      (widget) => widget is Focus && widget.focusNode == field.focusNode,
    );
    Actions.invoke(
      tester.element(cellFocus),
      const RedoTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();
    expect(field.controller?.text, 'apha');
    expect(quill.document.toDelta().toJson(), parentDelta);

    await tester.enterText(
      find.byKey(const ValueKey('note_table_active_cell')),
      '',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(field.controller?.text, isEmpty);
    expect(quill.document.toDelta().toJson(), parentDelta);
  });

  testWidgets('Tab navigation and Escape commit through one cell editor', (
    tester,
  ) async {
    final table = NoteTable(
      id: 'navigation-table',
      rows: const [
        ['first', 'second'],
      ],
    );
    final quill = QuillController(
      document: Document.fromDelta(
        Delta()
          ..insert(NoteTableCodec.encodeInsert(table))
          ..insert('\n'),
      ),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final parentFocus = FocusNode();
    final coordinator = NoteTableController(
      controller: quill,
      parentFocusNode: parentFocus,
    );
    addTearDown(() {
      coordinator.dispose();
      quill.dispose();
      parentFocus.dispose();
    });

    await tester.pumpWidget(
      _testApp(
        NoteTableEmbed(
          table: table,
          readOnly: false,
          parentColor: Colors.white,
          presentation: NoteTablePresentation.editor,
          tableController: coordinator,
        ),
      ),
    );
    await tester.tap(find.text('first'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('note_table_active_cell')),
      'edited first',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(coordinator.activeCell?.column, 1);
    expect(coordinator.activeTable?.cellAt(0, 0), 'edited first');
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(coordinator.activeCell?.column, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(coordinator.hasActiveCell, isFalse);
    expect(coordinator.isCellInputFocused, isFalse);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('six columns wrap within a narrow large-text viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final table = NoteTable(
      id: 'table',
      rows: [List.generate(6, (index) => 'very long cell content $index')],
    );

    await tester.pumpWidget(
      _testApp(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.6),
          ),
          child: NoteTableEmbed(
            table: table,
            readOnly: true,
            parentColor: Colors.white,
            presentation: NoteTablePresentation.editor,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(Table)).width, lessThanOrEqualTo(320));
  });

  testWidgets('card preview caps tables at three rows', (tester) async {
    final table = NoteTable(
      id: 'table',
      rows: List.generate(5, (row) => ['row $row']),
    );

    await tester.pumpWidget(
      _testApp(
        NoteTableEmbed(
          table: table,
          readOnly: true,
          parentColor: Colors.white,
          presentation: NoteTablePresentation.card,
        ),
      ),
    );

    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 2'), findsOneWidget);
    expect(find.text('row 3'), findsNothing);
    expect(find.text('+2 more rows'), findsOneWidget);
  });

  testWidgets('malformed and future embeds render a safe fallback', (
    tester,
  ) async {
    final controller = QuillController(
      document: Document.fromJson([
        {
          'insert': {NoteTableCodec.embedType: '{bad-json'},
        },
        {'insert': '\n'},
        {
          'insert': {'future-better-keep-embed': 'raw'},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 0),
      readOnly: true,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _testApp(
        QuillEditor.basic(
          controller: controller,
          config: const QuillEditorConfig(
            scrollable: false,
            embedBuilders: [NoteTableEmbedBuilder(parentColor: Colors.white)],
            unknownEmbedBuilder: UnknownNoteEmbedBuilder(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('This table or embedded content cannot be displayed safely'),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('insert sheet defaults to 2 by 2 and validates custom limits', (
    tester,
  ) async {
    NoteTable? selected;
    await tester.pumpWidget(
      _testApp(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selected = await showInsertTableSheet(context);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('2 × 2'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('table_rows_input')),
      '21',
    );
    await tester.pump();
    final invalidButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('insert_table_confirm')),
    );
    expect(invalidButton.onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('table_rows_input')), '3');
    await tester.enterText(
      find.byKey(const ValueKey('table_columns_input')),
      '6',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('insert_table_confirm')));
    await tester.pumpAndSettle();

    expect(selected?.rowCount, 3);
    expect(selected?.columnCount, 6);
    expect(selected?.header, isFalse);
  });

  testWidgets('quick picker fits a narrow short sheet and reaches 5 by 5', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_testApp(_openTableSheetButton()));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final picker = find.byKey(const ValueKey('table_quick_picker'));
    final finalCell = find.byKey(const ValueKey('table_quick_cell_5_5'));
    final pickerRect = tester.getRect(picker);
    final finalCellRect = tester.getRect(finalCell);

    expect(pickerRect.width, pickerRect.height);
    expect(pickerRect.width, lessThanOrEqualTo(240));
    expect(finalCellRect.right, lessThanOrEqualTo(pickerRect.right));
    expect(finalCellRect.bottom, lessThanOrEqualTo(pickerRect.bottom));

    await tester.tap(finalCell);
    await tester.pump();
    expect(find.text('5 × 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short large-text keyboard layout keeps compact controls and action visible',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        _testApp(
          _openTableSheetButton(),
          textScaler: const TextScaler.linear(1.4),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('insert_table_sheet_scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('table_rows_control')),
        160,
        scrollable: scrollable,
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('table_rows_control'))).width,
        128,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('table_columns_control')))
            .width,
        128,
      );
      expect(
        find.byKey(const ValueKey('insert_table_confirm')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'dimension steppers follow the ${brightness.name} color scheme and limits',
      (tester) async {
        final theme = ThemeData(
          brightness: brightness,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        );
        await tester.pumpWidget(
          _testApp(_openTableSheetButton(), theme: theme),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('table_rows_control')),
          160,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('insert_table_sheet_scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );

        final decrement = find.descendant(
          of: find.byKey(const ValueKey('table_rows_decrement')),
          matching: find.byType(IconButton),
        );
        final enabledButton = tester.widget<IconButton>(decrement);
        expect(
          enabledButton.style?.backgroundColor?.resolve({}),
          theme.colorScheme.primaryContainer,
        );
        expect(
          tester
              .widget<Icon>(
                find.descendant(
                  of: decrement,
                  matching: find.byIcon(Icons.remove),
                ),
              )
              .color,
          theme.colorScheme.onPrimaryContainer,
        );

        await tester.tap(decrement);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('table_rows_input')))
              .controller
              ?.text,
          '1',
        );
        final disabledButton = tester.widget<IconButton>(decrement);
        expect(disabledButton.onPressed, isNull);
        expect(
          disabledButton.style?.backgroundColor?.resolve({
            WidgetState.disabled,
          }),
          theme.colorScheme.surfaceContainerHighest,
        );

        await tester.enterText(
          find.byKey(const ValueKey('table_rows_input')),
          '20',
        );
        await tester.enterText(
          find.byKey(const ValueKey('table_columns_input')),
          '6',
        );
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.descendant(
                  of: find.byKey(const ValueKey('table_rows_increment')),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.descendant(
                  of: find.byKey(const ValueKey('table_columns_increment')),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
      },
    );
  }
}

Widget _openTableSheetButton() {
  return Builder(
    builder: (context) => FilledButton(
      onPressed: () => showInsertTableSheet(context),
      child: const Text('Open'),
    ),
  );
}

Widget _testApp(
  Widget child, {
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}
