import 'dart:async';
import 'dart:convert';

import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/pages/checklist_editor/rich_checklist_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_app_bar.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_size_button.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets(
    'virtualizes inactive rich rows and rebinds one live Quill editor',
    (tester) async {
      final document = RichChecklistDocument([
        _item('active', 'Active task'),
        _item(
          'styled',
          'Styled RTL task that wraps onto another visual line',
          indent: 1,
          attributes: const {'bold': true, 'size': 24, 'color': '#ff0000'},
          lineAttributes: const {'direction': 'rtl', 'align': 'right'},
        ),
        _item('done', 'Done task', checked: true),
      ]);

      await _pumpEditor(
        tester,
        note: Note(readOnly: true, color: const Color(0xff202124)),
        document: document,
      );

      expect(find.byType(QuillEditor), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rich_checklist_toolbar')),
        findsNothing,
      );
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      expect(find.text('Completed (1)'), findsOneWidget);

      final richText = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() ==
                  'Styled RTL task that wraps onto another visual line',
        ),
      );
      final rootSpan = richText.text as TextSpan;
      final run = rootSpan.children!.single as TextSpan;
      expect(richText.textDirection, TextDirection.rtl);
      expect(richText.textAlign, TextAlign.right);
      expect(run.style?.fontWeight, FontWeight.bold);
      expect(run.style?.fontSize, 24);
      expect(run.style?.color, const Color(0xffff0000));
      expect(find.text('Done task', findRichText: true), findsOneWidget);
      expect(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
        findsOneWidget,
      );
      expect(find.text('1/3'), findsOneWidget);

      await tester.tap(find.text('Completed (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Done task', findRichText: true), findsNothing);
    },
  );

  testWidgets(
    'shares app-bar colors and shows title with live checklist count',
    (tester) async {
      for (final color in <Color>[
        const Color(0xfffff8e1),
        const Color(0xff202124),
        Colors.transparent,
      ]) {
        final document = RichChecklistDocument([
          _item('a', 'Open'),
          _item('b', 'Done', checked: true),
        ]);
        await _pumpEditor(
          tester,
          note: Note(title: 'Tasks', readOnly: true, color: color),
          title: 'Tasks',
          document: document,
        );

        final focusedBack = tester.widget<BackButton>(
          find.descendant(
            of: find.byType(NoteEditorAppBar),
            matching: find.byType(BackButton),
          ),
        );
        expect(find.text('Tasks'), findsOneWidget);
        final focusedTitle = tester.widget<Text>(
          find.byKey(const ValueKey('rich_checklist_note_title')),
        );
        expect(focusedTitle.maxLines, 1);
        expect(focusedTitle.overflow, TextOverflow.ellipsis);
        expect(
          find.byKey(const ValueKey('note_checkbox_progress_title')),
          findsOneWidget,
        );
        expect(find.text('1/2'), findsOneWidget);

        await tester.pumpWidget(
          _host(
            NoteEditor(
              key: ValueKey('normal-editor-$color'),
              note: Note(
                readOnly: true,
                color: color,
                content: _content('', document.items),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final normalBack = tester.widget<BackButton>(
          find.descendant(
            of: find.byType(NoteEditorAppBar),
            matching: find.byType(BackButton),
          ),
        );
        expect(normalBack.color, focusedBack.color);
        expect(find.text('1/2'), findsOneWidget);
      }
    },
  );

  testWidgets(
    'checklist app-bar title truncates and has no empty placeholder',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const longTitle =
          'قائمة التسوق 🛒 with a deliberately long title that must truncate';
      final document = RichChecklistDocument([_item('a', 'Task')]);
      await _pumpEditor(
        tester,
        note: Note(title: longTitle, readOnly: true),
        title: longTitle,
        document: document,
      );

      final titleFinder = find.byKey(
        const ValueKey('rich_checklist_note_title'),
      );
      final title = tester.widget<Text>(titleFinder);
      expect(title.data, longTitle);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(
        tester.renderObject<RenderParagraph>(titleFinder).didExceedMaxLines,
        isTrue,
      );
      expect(find.text('0/1'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpEditor(
        tester,
        note: Note(title: '', readOnly: true),
        document: document,
      );
      expect(tester.widget<Text>(titleFinder).data, isEmpty);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('centers rich checklist content on the first visual line', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('active', 'Active'),
      _item('plain', 'Plain item'),
      _item(
        'large-rtl',
        'مهمة طويلة تلتف على أكثر من سطر مع تنسيق كبير',
        attributes: const {'size': 24, 'color': '#1a73e8'},
        lineAttributes: const {'direction': 'rtl', 'line-height': 1.4},
      ),
    ]);
    await _pumpEditor(tester, note: Note(readOnly: true), document: document);

    for (final entry in <(String, String)>[
      ('plain', 'Plain item'),
      ('large-rtl', 'مهمة طويلة تلتف على أكثر من سطر مع تنسيق كبير'),
    ]) {
      final checkboxCenter = tester
          .getRect(find.byKey(ValueKey('checklist-checkbox-${entry.$1}')))
          .center
          .dy;
      final text = find.text(entry.$2, findRichText: true);
      final firstGlyphCenter = _firstGlyphCenter(tester, text);
      expect(
        (checkboxCenter - firstGlyphCenter).abs(),
        lessThanOrEqualTo(4),
        reason: '${entry.$1} should align with its first visual line',
      );
    }
  });

  testWidgets('row background and active highlight share one geometry', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('first', 'First task'),
      _item('second', 'Second task'),
    ]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    final firstSurface = find.byKey(
      const ValueKey('checklist-row-surface-first'),
    );
    final secondSurface = find.byKey(
      const ValueKey('checklist-row-surface-second'),
    );
    final firstWidget = tester.widget<AnimatedContainer>(firstSurface);
    final secondWidget = tester.widget<AnimatedContainer>(secondSurface);
    final firstDecoration = firstWidget.decoration as BoxDecoration;
    final secondDecoration = secondWidget.decoration as BoxDecoration;
    expect(firstDecoration.color?.a, greaterThan(secondDecoration.color!.a));
    expect(secondDecoration.color?.a, greaterThan(0));
    final dismissible = tester.widget<Dismissible>(
      find.byKey(const ValueKey('checklist-item-second')),
    );
    final deleteBackground = dismissible.background! as Container;
    expect(deleteBackground.margin, secondWidget.margin);
    expect(
      (deleteBackground.decoration! as BoxDecoration).borderRadius,
      secondDecoration.borderRadius,
    );

    final before = tester.getRect(secondSurface);
    await tester.tap(find.text('Second task', findRichText: true));
    await tester.pumpAndSettle();
    expect(tester.getRect(secondSurface), before);
    final activeDecoration =
        tester.widget<AnimatedContainer>(secondSurface).decoration
            as BoxDecoration;
    expect(activeDecoration.borderRadius, secondDecoration.borderRadius);
    expect(activeDecoration.color?.a, firstDecoration.color?.a);
  });

  testWidgets('focused app bar contains Back, read-only title, and progress', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'Task')]);
    for (final note in <Note>[
      Note(id: 7, title: 'Normal'),
      Note(id: 8, title: 'Read only', readOnly: true),
      Note(id: 9, title: 'Locked', locked: true),
      Note(id: 10, title: 'Trashed', trashed: true),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpEditor(
        tester,
        note: note,
        title: note.title!,
        document: document,
      );

      final appBar = tester.widget<NoteEditorAppBar>(
        find.byType(NoteEditorAppBar),
      );
      expect(appBar.actions, hasLength(1), reason: note.title);
      expect(
        find.descendant(
          of: find.byType(NoteEditorAppBar),
          matching: find.byType(BackButton),
        ),
        findsOneWidget,
        reason: note.title,
      );
      expect(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
        findsOneWidget,
        reason: note.title,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('rich_checklist_note_title')),
            )
            .data,
        note.title,
        reason: note.title,
      );
      expect(find.byType(TextField), findsNothing, reason: note.title);
      expect(find.text('0/1'), findsOneWidget, reason: note.title);
      for (final key in <String>[
        'note_editor_color_action',
        'note_editor_reminder_action',
        'note_editor_pin_action',
        'note_editor_labels_action',
        'note_editor_overflow_menu',
        'checklist-page-menu',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: note.title);
      }
      expect(
        find.descendant(
          of: find.byType(NoteEditorAppBar),
          matching: find.byIcon(Icons.restore_from_trash),
        ),
        findsNothing,
        reason: note.title,
      );
      expect(
        tester
            .widget<QuillEditor>(find.byType(QuillEditor))
            .controller
            .readOnly,
        note.readOnly || note.trashed,
        reason: note.title,
      );
    }

    expect(find.text('Convert entire checklist to text'), findsNothing);
  });

  testWidgets('note-level actions remain in the parent normal editor', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'Task')]);
    await tester.pumpWidget(
      _host(
        NoteEditor(
          note: Note(
            id: 11,
            title: 'Parent actions',
            content: _content('Parent actions', document.items),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in <String>[
      'note_editor_color_action',
      'note_editor_reminder_action',
      'note_editor_pin_action',
      'note_editor_labels_action',
      'note_editor_overflow_menu',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }

    await tester.pumpWidget(
      _host(
        NoteEditor(
          key: const ValueKey('trashed-parent-editor'),
          note: Note(
            id: 12,
            title: 'Trashed parent',
            trashed: true,
            content: _content('Trashed parent', document.items),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);
  });

  testWidgets('delete has no notice and remains recoverable from the toolbar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(424, 924);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    final document = RichChecklistDocument([
      _item('active', 'Active task'),
      _item('delete', 'Delete task'),
    ]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    final deleteRow = find.ancestor(
      of: find.text('Delete task', findRichText: true),
      matching: find.byType(Dismissible),
    );
    await tester.tap(
      find.descendant(
        of: deleteRow,
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const ValueKey('editor_action_notice')), findsNothing);
    expect(find.text('Delete task', findRichText: true), findsNothing);
    expect(find.text('0/1'), findsOneWidget);
    final toolbar = tester.getRect(
      find.byKey(const ValueKey('rich_checklist_toolbar')),
    );
    final keyboardTop =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom;
    expect(toolbar.bottom, lessThanOrEqualTo(keyboardTop));

    await tester.tap(find.byKey(const ValueKey('editor_toolbar_undo')));
    await tester.pumpAndSettle();
    expect(find.text('Delete task', findRichText: true), findsOneWidget);
    expect(find.text('0/2'), findsOneWidget);
  });

  testWidgets(
    'clear completed has no notice and remains recoverable from the toolbar',
    (tester) async {
      final document = RichChecklistDocument([
        _item('active', 'Active task'),
        _item('done-one', 'Done one', checked: true),
        _item('done-two', 'Done two', checked: true),
      ]);
      await _pumpEditor(
        tester,
        note: _RecordingNote(content: _content('Tasks', document.items)),
        title: 'Tasks',
        document: document,
      );

      expect(find.text('2/3'), findsOneWidget);
      await tester.tap(find.text('Clear completed'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const ValueKey('editor_action_notice')), findsNothing);
      expect(find.text('0/1'), findsOneWidget);
      expect(find.text('Done one', findRichText: true), findsNothing);
      expect(find.text('Done two', findRichText: true), findsNothing);

      await tester.tap(find.byKey(const ValueKey('editor_toolbar_undo')));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('Done one', findRichText: true), findsOneWidget);
      expect(find.text('Done two', findRichText: true), findsOneWidget);
    },
  );

  testWidgets('focus changes keep the shared toolbar on one controller', (
    tester,
  ) async {
    final note = _RecordingNote(
      title: 'Tasks',
      content: _content('Tasks', [_item('a', 'First'), _item('b', 'Second')]),
    );
    await _pumpEditor(
      tester,
      note: note,
      title: 'Tasks',
      document: RichChecklistDocument([
        _item('a', 'First'),
        _item('b', 'Second'),
      ]),
    );

    expect(find.byType(QuillEditor), findsOneWidget);
    expect(find.byType(NoteEditorToolbar), findsOneWidget);
    expect(find.byType(TextSizeButton), findsOneWidget);
    expect(find.byType(QuillToolbarFontFamilyButton), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NoteEditorAppBar),
        matching: find.byIcon(Icons.undo),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rich_checklist_toolbar')),
        matching: find.byKey(const ValueKey('editor_toolbar_undo')),
      ),
      findsOneWidget,
    );
    final firstToolbar = tester.widget<NoteEditorToolbar>(
      find.byType(NoteEditorToolbar),
    );

    await tester.tap(find.text('Second', findRichText: true));
    await tester.pump();

    expect(find.byType(QuillEditor), findsOneWidget);
    final secondToolbar = tester.widget<NoteEditorToolbar>(
      find.byType(NoteEditorToolbar),
    );
    expect(secondToolbar.controller, same(firstToolbar.controller));
    expect(secondToolbar.controller.document.toPlainText(), 'Second\n');
  });

  testWidgets('switching rows preserves the complete Quill input lifecycle', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('a', 'First'),
      _item('b', 'Second'),
    ]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final firstEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final firstQuillState = tester.state<QuillEditorState>(
      find.byType(QuillEditor),
    );
    final firstRawEditorState = firstQuillState.editableTextKey.currentState;
    expect(firstEditor.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);

    await tester.tap(find.text('Second', findRichText: true));
    await tester.pump();
    await tester.pump();

    final secondEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final secondQuillState = tester.state<QuillEditorState>(
      find.byType(QuillEditor),
    );
    expect(secondQuillState, same(firstQuillState));
    expect(
      secondQuillState.editableTextKey.currentState,
      same(firstRawEditorState),
    );
    expect(secondEditor.controller, same(firstEditor.controller));
    expect(secondEditor.focusNode, same(firstEditor.focusNode));
    expect(secondEditor.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);
    expect(
      secondEditor.controller.selection,
      const TextSelection.collapsed(offset: 6),
    );
  });

  testWidgets('Android newline creates a caret-ready row without another tap', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'First')]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
      platform: TargetPlatform.android,
    );

    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final firstEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final firstQuillState = tester.state<QuillEditorState>(
      find.byType(QuillEditor),
    );
    final firstRawEditorState = firstQuillState.editableTextKey.currentState;
    expect(tester.testTextInput.isRegistered, isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    await tester.pump();

    expect(find.byType(Dismissible), findsNWidgets(2));
    final newItemEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final newItemQuillState = tester.state<QuillEditorState>(
      find.byType(QuillEditor),
    );
    expect(newItemQuillState, same(firstQuillState));
    expect(
      newItemQuillState.editableTextKey.currentState,
      same(firstRawEditorState),
    );
    expect(newItemEditor.controller, same(firstEditor.controller));
    expect(newItemEditor.focusNode, same(firstEditor.focusNode));
    expect(newItemEditor.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);
    expect(newItemEditor.controller.document.toPlainText(), '\n');
    expect(
      newItemEditor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Typed immediately\n',
        selection: TextSelection.collapsed(offset: 17),
      ),
    );
    await tester.pump();

    expect(
      newItemEditor.controller.document.toPlainText(),
      'Typed immediately\n',
    );
    expect(
      newItemEditor.controller.selection,
      const TextSelection.collapsed(offset: 17),
    );
  });

  testWidgets(
    'iOS Return creates exactly one new checklist row',
    (tester) async {
      const sentinel = '\u2060';
      final document = RichChecklistDocument([_item('a', 'First')]);
      final note = _RecordingNote(content: _content('Tasks', document.items));
      await _pumpEditor(
        tester,
        note: note,
        title: 'Tasks',
        document: document,
        platform: TargetPlatform.iOS,
      );

      await tester.tap(find.text('First', findRichText: true));
      await tester.pump();
      final firstEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      final firstQuillState = tester.state<QuillEditorState>(
        find.byType(QuillEditor),
      );
      final firstRawEditorState = firstQuillState.editableTextKey.currentState;

      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'First\n\n',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(Dismissible), findsNWidgets(2));
      expect(find.text('First', findRichText: true), findsOneWidget);
      final newItemEditor = tester.widget<QuillEditor>(
        find.byType(QuillEditor),
      );
      final newItemQuillState = tester.state<QuillEditorState>(
        find.byType(QuillEditor),
      );
      expect(newItemQuillState, same(firstQuillState));
      expect(
        newItemQuillState.editableTextKey.currentState,
        same(firstRawEditorState),
      );
      expect(newItemEditor.controller, same(firstEditor.controller));
      expect(newItemEditor.focusNode, same(firstEditor.focusNode));
      expect(newItemEditor.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isRegistered, isTrue);
      expect(newItemEditor.controller.document.toPlainText(), '$sentinel\n');
      expect(
        newItemEditor.controller.selection,
        const TextSelection.collapsed(offset: 1),
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '${sentinel}Typed immediately\n',
          selection: TextSelection.collapsed(offset: 18),
        ),
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.byType(Dismissible), findsNWidgets(2));
      expect(
        newItemEditor.controller.document.toPlainText(),
        'Typed immediately\n',
      );
      expect(
        newItemEditor.controller.selection,
        const TextSelection.collapsed(offset: 17),
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(note.saveCalls, 1);
      expect(note.content, isNot(contains(sentinel)));
      expect(note.plainText, 'Tasks\nFirst\nTyped immediately');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('an inserted newline uses the same persistent row split path', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'First')]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final quillState = tester.state<QuillEditorState>(find.byType(QuillEditor));
    final rawEditorState = quillState.editableTextKey.currentState;

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'First\n\n',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(Dismissible), findsNWidgets(2));
    final splitEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final splitState = tester.state<QuillEditorState>(find.byType(QuillEditor));
    expect(splitEditor.controller, same(editor.controller));
    expect(splitEditor.focusNode, same(editor.focusNode));
    expect(splitState, same(quillState));
    expect(splitState.editableTextKey.currentState, same(rawEditorState));
    expect(splitEditor.controller.document.toPlainText(), '\n');
    expect(
      splitEditor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
  });

  testWidgets('hardware Enter creates exactly one persistent active row', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'First')]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final quillState = tester.state<QuillEditorState>(find.byType(QuillEditor));
    final rawEditorState = quillState.editableTextKey.currentState;

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();

    expect(find.byType(Dismissible), findsNWidgets(2));
    final splitEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final splitState = tester.state<QuillEditorState>(find.byType(QuillEditor));
    expect(splitEditor.controller, same(editor.controller));
    expect(splitEditor.focusNode, same(editor.focusNode));
    expect(splitState, same(quillState));
    expect(splitState.editableTextKey.currentState, same(rawEditorState));
    expect(splitEditor.controller.document.toPlainText(), '\n');
    expect(
      splitEditor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
  });

  testWidgets('Backspace on an empty item focuses the previous item end', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('previous', 'Previous'),
      _item('empty', ''),
    ]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.byKey(const ValueKey('checklist-text-lane-empty')));
    await tester.pump();
    await tester.pump();
    final emptyEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final quillState = tester.state<QuillEditorState>(find.byType(QuillEditor));
    final rawEditorState = quillState.editableTextKey.currentState;
    expect(emptyEditor.controller.document.toPlainText(), '\n');

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    await tester.pump();

    expect(find.byType(Dismissible), findsOneWidget);
    final previousEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final previousQuillState = tester.state<QuillEditorState>(
      find.byType(QuillEditor),
    );
    expect(previousQuillState, same(quillState));
    expect(
      previousQuillState.editableTextKey.currentState,
      same(rawEditorState),
    );
    expect(previousEditor.controller, same(emptyEditor.controller));
    expect(previousEditor.focusNode, same(emptyEditor.focusNode));
    expect(previousEditor.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);
    expect(previousEditor.controller.document.toPlainText(), 'Previous\n');
    expect(
      previousEditor.controller.selection,
      const TextSelection.collapsed(offset: 8),
    );
  });

  group('iOS soft-keyboard Backspace', () {
    const sentinel = '\u2060';

    testWidgets(
      'deletes an empty row and focuses the previous item end',
      (tester) async {
        final document = RichChecklistDocument([
          _item('previous', 'Previous'),
          _item('empty', ''),
        ]);
        await _pumpEditor(
          tester,
          note: _RecordingNote(content: _content('Tasks', document.items)),
          title: 'Tasks',
          document: document,
          platform: TargetPlatform.iOS,
        );

        await tester.tap(
          find.byKey(const ValueKey('checklist-text-lane-empty')),
        );
        await tester.pump();
        await tester.pump();
        final emptyEditor = tester.widget<QuillEditor>(
          find.byType(QuillEditor),
        );
        expect(emptyEditor.controller.document.toPlainText(), '$sentinel\n');
        expect(
          emptyEditor.controller.selection,
          const TextSelection.collapsed(offset: 1),
        );

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(Dismissible), findsOneWidget);
        final previousEditor = tester.widget<QuillEditor>(
          find.byType(QuillEditor),
        );
        expect(previousEditor.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isRegistered, isTrue);
        expect(previousEditor.controller.document.toPlainText(), 'Previous\n');
        expect(
          previousEditor.controller.selection,
          const TextSelection.collapsed(offset: 8),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'keeps the sole empty row and restores usable input',
      (tester) async {
        final document = RichChecklistDocument([_item('only', '')]);
        final note = _RecordingNote(content: _content('Tasks', document.items));
        await _pumpEditor(
          tester,
          note: note,
          title: 'Tasks',
          document: document,
          platform: TargetPlatform.iOS,
        );

        await tester.tap(
          find.byKey(const ValueKey('checklist-text-lane-only')),
        );
        await tester.pump();
        final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(Dismissible), findsOneWidget);
        expect(editor.controller.document.toPlainText(), '$sentinel\n');
        expect(editor.controller.selection.baseOffset, 1);
        expect(editor.controller.selection.extentOffset, 1);
        expect(tester.testTextInput.isRegistered, isTrue);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${sentinel}A\n',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));

        expect(editor.controller.document.toPlainText(), 'A\n');
        expect(
          editor.controller.selection,
          const TextSelection.collapsed(offset: 1),
        );

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        expect(editor.controller.document.toPlainText(), '$sentinel\n');
        expect(editor.controller.selection.baseOffset, 1);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byType(Dismissible), findsOneWidget);
        expect(editor.controller.document.toPlainText(), '$sentinel\n');
        expect(note.saveCalls, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'strips the sentinel after IME composition before saving',
      (tester) async {
        final document = RichChecklistDocument([_item('only', '')]);
        final note = _RecordingNote(content: _content('Tasks', document.items));
        await _pumpEditor(
          tester,
          note: note,
          title: 'Tasks',
          document: document,
          platform: TargetPlatform.iOS,
        );

        await tester.tap(
          find.byKey(const ValueKey('checklist-text-lane-only')),
        );
        await tester.pump();
        final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
        editor.controller.formatSelection(Attribute.bold);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${sentinel}Typed\n',
            selection: TextSelection.collapsed(offset: 6),
            composing: TextRange(start: 1, end: 6),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));
        expect(editor.controller.document.toPlainText(), '${sentinel}Typed\n');

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${sentinel}Typed\n',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));

        expect(editor.controller.document.toPlainText(), 'Typed\n');
        expect(
          editor.controller.selection,
          const TextSelection.collapsed(offset: 5),
        );
        expect(editor.controller.document.toDelta().toJson().first, {
          'insert': 'Typed',
          'attributes': {'bold': true},
        });

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        expect(note.saveCalls, 1);
        expect(note.content, isNot(contains(sentinel)));
        expect(note.plainText, 'Tasks\nTyped');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'keeps logical selection after autocorrect replaces the sentinel',
      (tester) async {
        final document = RichChecklistDocument([
          _item('previous', 'Previous'),
          _item('only', ''),
        ]);
        final note = _RecordingNote(
          title: 'Tasks',
          content: _content('Tasks', document.items),
        );
        Object? navigationResult;
        await tester.pumpWidget(
          _focusedLaunchHost(
            note,
            document,
            onResult: (result) => navigationResult = result,
          ),
        );
        await tester.tap(find.text('Open checklist'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('checklist-text-lane-only')),
        );
        await tester.pump();

        final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
        editor.controller.formatSelection(Attribute.bold);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${sentinel}teh\n',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();
        expect(editor.controller.document.toDelta().toJson(), [
          {'insert': sentinel},
          {
            'insert': 'teh',
            'attributes': {'bold': true},
          },
          {'insert': '\n'},
        ]);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'the\n',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        await tester.pump(const Duration(milliseconds: 220));

        expect(editor.controller.document.toPlainText(), 'the\n');
        expect(
          editor.controller.selection,
          const TextSelection.collapsed(offset: 3),
        );
        expect(editor.controller.document.toDelta().toJson().first, {
          'insert': 'the',
          'attributes': {'bold': true},
        });

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        final result = navigationResult as RichChecklistEditorResult;
        expect(result.selectionStart, 12);
        expect(result.selectionEnd, 12);
        expect(result.document.itemById('only')!.plainText, 'the');
        expect(result.content, isNot(contains(sentinel)));
        expect(jsonEncode(result.bodyDelta), isNot(contains(sentinel)));
        expect(result.plainText, 'Tasks\nPrevious\nthe');
        expect(note.content, isNot(contains(sentinel)));
        expect(note.plainText, 'Tasks\nPrevious\nthe');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      're-arms Backspace after a replacement removes the sentinel',
      (tester) async {
        final document = RichChecklistDocument([
          _item('previous', 'Previous'),
          _item('empty', ''),
        ]);
        await _pumpEditor(
          tester,
          note: _RecordingNote(content: _content('Tasks', document.items)),
          title: 'Tasks',
          document: document,
          platform: TargetPlatform.iOS,
        );
        await tester.tap(
          find.byKey(const ValueKey('checklist-text-lane-empty')),
        );
        await tester.pump();

        final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${sentinel}teh\n',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'the\n',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(editor.controller.document.toPlainText(), '$sentinel\n');
        expect(
          editor.controller.selection,
          const TextSelection.collapsed(offset: 1),
        );

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\n',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(Dismissible), findsOneWidget);
        expect(editor.controller.document.toPlainText(), 'Previous\n');
        expect(editor.focusNode.hasFocus, isTrue);
        expect(
          editor.controller.selection,
          const TextSelection.collapsed(offset: 8),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'announces the placeholder only while the sentinel row is empty',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final document = RichChecklistDocument([_item('only', '')]);
          await _pumpEditor(
            tester,
            note: _RecordingNote(content: _content('Tasks', document.items)),
            title: 'Tasks',
            document: document,
            platform: TargetPlatform.iOS,
          );
          await tester.tap(
            find.byKey(const ValueKey('checklist-text-lane-only')),
          );
          await tester.pump();

          expect(find.bySemanticsLabel('Start writing...'), findsOneWidget);

          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '${sentinel}A\n',
              selection: TextSelection.collapsed(offset: 2),
            ),
          );
          await tester.pump();

          expect(find.bySemanticsLabel('Start writing...'), findsNothing);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  testWidgets('row switching waits for Android IME composition to finish', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('a', 'First'),
      _item('b', 'Second'),
    ]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Firstx\n',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 5, end: 6),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Second', findRichText: true));
    await tester.pump();
    expect(editor.controller.document.toPlainText(), 'Firstx\n');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Firstx\n',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(editor.controller.document.toPlainText(), 'Second\n');
    expect(editor.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);
  });

  testWidgets('undo and redo restore the exact row selection', (tester) async {
    final document = RichChecklistDocument([_item('a', 'abcdef')]);
    await _pumpEditor(
      tester,
      note: _RecordingNote(content: _content('Tasks', document.items)),
      title: 'Tasks',
      document: document,
    );

    await tester.tap(find.text('abcdef', findRichText: true));
    await tester.pump();
    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    controller.updateSelection(
      const TextSelection.collapsed(offset: 2),
      ChangeSource.local,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'abXcdef\n',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('editor_toolbar_undo')));
    await tester.pump();
    await tester.pump();
    expect(controller.document.toPlainText(), 'abcdef\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));

    await tester.tap(find.byKey(const ValueKey('editor_toolbar_redo')));
    await tester.pump();
    await tester.pump();
    expect(controller.document.toPlainText(), 'abXcdef\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets('dragging a row animates the gap and commits the new order', (
    tester,
  ) async {
    final initial = RichChecklistDocument([
      _item('first', 'First'),
      _item('second', 'Second'),
      _item('third', 'Third'),
    ]);
    final note = _RecordingNote(
      title: 'Tasks',
      content: _content('Tasks', initial.items),
    );
    await _pumpEditor(tester, note: note, title: 'Tasks', document: initial);
    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    final editorBeforeDrag = tester.widget<QuillEditor>(
      find.byType(QuillEditor),
    );
    final selectionBeforeDrag = editorBeforeDrag.controller.selection;
    expect(editorBeforeDrag.focusNode.hasFocus, isTrue);

    expect(find.byType(ReorderableListView), findsOneWidget);
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final handles = find.byType(ReorderableDragStartListener);
    expect(handles, findsNWidgets(3));

    final gesture = await tester.startGesture(tester.getCenter(handles.at(2)));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      hapticCalls.where(
        (call) => call.arguments == 'HapticFeedbackType.selectionClick',
      ),
      hasLength(1),
    );

    final proxy = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString().contains('DragItemProxy'),
    );
    expect(proxy, findsOneWidget);
    final proxyMaterials = tester.widgetList<Material>(
      find.descendant(of: proxy, matching: find.byType(Material)),
    );
    expect(proxyMaterials, isNotEmpty);
    expect(proxyMaterials.every((material) => material.elevation == 0), isTrue);
    expect(
      find.descendant(
        of: proxy,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).color ==
                  Colors.red.withValues(alpha: 0.8),
        ),
      ),
      findsNothing,
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller
          .document
          .toPlainText(),
      'First\n',
    );
    final editorAfterDrag = tester.widget<QuillEditor>(
      find.byType(QuillEditor),
    );
    expect(editorAfterDrag.focusNode.hasFocus, isTrue);
    expect(editorAfterDrag.controller.selection, selectionBeforeDrag);
    final thirdY = tester.getTopLeft(find.text('Third', findRichText: true)).dy;
    final firstY = tester.getTopLeft(find.text('First', findRichText: true)).dy;
    final secondY = tester
        .getTopLeft(find.text('Second', findRichText: true))
        .dy;
    expect(thirdY, lessThan(firstY));
    expect(firstY, lessThan(secondY));
  });

  testWidgets('completion cascades, undo restores, and locked notes autosave', (
    tester,
  ) async {
    final initial = RichChecklistDocument([
      _item('parent', 'Parent'),
      _item('child', 'Child', indent: 1),
      _item('other', 'Other'),
    ]);
    final note = _RecordingNote(
      title: 'Tasks',
      content: _content('Tasks', initial.items),
      locked: true,
    );
    await _pumpEditor(tester, note: note, title: 'Tasks', document: initial);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NoteEditorAppBar),
        matching: find.byIcon(Icons.undo),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-parent')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Completed (1)'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editor_toolbar_undo')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Completed (1)'), findsNothing);
    expect(find.text('0/3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editor_toolbar_redo')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Completed (1)'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor_toolbar_undo')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-parent')));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(note.saveCalls, 1);

    final saved = jsonDecode(note.content!) as List<dynamic>;
    expect(
      saved.where(
        (operation) =>
            operation is Map &&
            (operation['attributes'] as Map?)?['list'] == 'checked',
      ),
      hasLength(2),
    );
  });

  testWidgets('dirty local changes pause autosave on an external conflict', (
    tester,
  ) async {
    final initial = RichChecklistDocument([_item('a', 'Local task')]);
    final note = _RecordingNote(
      id: 41,
      title: 'Tasks',
      content: _content('Tasks', initial.items),
    );
    await _pumpEditor(tester, note: note, title: 'Tasks', document: initial);

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-a')));
    await tester.pump(const Duration(milliseconds: 100));
    _RecordingNote(
      id: 41,
      title: 'Remote',
      content: _content('Remote', [_item('remote', 'Remote task')]),
    ).notify('updated', false);
    await tester.pump();

    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rich_checklist_note_title')))
          .data,
      'Remote',
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(note.saveCalls, 0);

    await tester.tap(find.text('Keep my edits'));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(note.saveCalls, 1);
    expect(note.title, 'Remote');
  });

  for (final useSystemBack in [false, true]) {
    testWidgets(
      'conflicts block ${useSystemBack ? 'system' : 'leading'} Back until resolved',
      (tester) async {
        final initial = RichChecklistDocument([_item('a', 'Local task')]);
        final note = _RecordingNote(
          id: 44,
          title: 'Tasks',
          content: _content('Tasks', initial.items),
        );
        await tester.pumpWidget(_focusedLaunchHost(note, initial));
        await tester.tap(find.text('Open checklist'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('checklist-checkbox-a')));
        await tester.pump(const Duration(milliseconds: 100));
        _RecordingNote(
          id: 44,
          title: 'Remote',
          content: _content('Remote', [_item('remote', 'Remote task')]),
        ).notify('updated', false);
        await tester.pump();

        if (useSystemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pump();

        expect(find.byType(RichChecklistEditor), findsOneWidget);
        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(find.text('Open checklist'), findsNothing);
        expect(note.saveCalls, 0);

        await tester.tap(find.text('Keep my edits'));
        await tester.pump(const Duration(milliseconds: 1100));
        if (useSystemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pumpAndSettle();

        expect(find.byType(RichChecklistEditor), findsNothing);
        expect(find.text('Open checklist'), findsOneWidget);
        expect(note.saveCalls, 1);
      },
    );
  }

  testWidgets('a conflict arriving during save keeps the editor open', (
    tester,
  ) async {
    final initial = RichChecklistDocument([_item('a', 'Local task')]);
    final note = _DeferredSaveNote(
      id: 46,
      title: 'Tasks',
      content: _content('Tasks', initial.items),
    );
    await tester.pumpWidget(_focusedLaunchHost(note, initial));
    await tester.tap(find.text('Open checklist'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-a')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(note.saveCalls, 1);

    _RecordingNote(
      id: 46,
      title: 'Remote',
      content: _content('Remote', [_item('remote', 'Remote task')]),
    ).notify('updated', false);
    await tester.pump();
    note.completeFirstSave();
    await tester.pump();

    expect(find.byType(RichChecklistEditor), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('Open checklist'), findsNothing);

    await tester.tap(find.text('Keep my edits'));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(RichChecklistEditor), findsNothing);
    expect(find.text('Open checklist'), findsOneWidget);
    expect(note.saveCalls, 2);
  });

  testWidgets('external edits outside the selected block merge safely', (
    tester,
  ) async {
    final codec = ChecklistDeltaCodec();
    final initialBody = <Map<String, dynamic>>[
      {'insert': 'Before\n'},
      {'insert': 'Task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': 'After\n'},
    ];
    final initialDocument = documentFromJsonSafe(initialBody);
    final block = codec
        .scanChecklistBlocks(initialDocument)
        .single
        .slice!
        .copyWith(document: RichChecklistDocument([_item('a', 'Task')]));
    final note = _RecordingNote(
      id: 43,
      title: 'Mixed',
      content: codec.encodeCombinedBodyJson(
        title: 'Mixed',
        bodyDelta: initialBody,
      ),
    );
    await tester.pumpWidget(
      _host(
        RichChecklistEditor(
          note: note,
          session: ChecklistBlockEditSession(
            title: 'Mixed',
            bodyDelta: initialBody,
            block: block,
            selectionStart: block.startOffset,
            selectionEnd: block.startOffset,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-a')));
    await tester.pump(const Duration(milliseconds: 100));
    final remoteBody = <Map<String, dynamic>>[
      {'insert': 'Remote before\n'},
      {'insert': 'Task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': 'After\n'},
    ];
    _RecordingNote(
      id: 43,
      title: 'Remote title',
      content: codec.encodeCombinedBodyJson(
        title: 'Remote title',
        bodyDelta: remoteBody,
      ),
    ).notify('updated', false);
    await tester.pump();

    expect(find.byType(MaterialBanner), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rich_checklist_note_title')))
          .data,
      'Remote title',
    );
    await tester.pump(const Duration(milliseconds: 1100));
    expect(note.saveCalls, 1);
    expect(note.title, 'Remote title');
    final saved = jsonDecode(note.content!) as List<dynamic>;
    expect(
      codec
          .tryParseCombinedJson(note.content)!
          .bodyDelta
          .map((operation) => operation['insert'])
          .whereType<String>()
          .join()
          .startsWith('Remote before\n'),
      isTrue,
    );
    expect(
      saved.any(
        (operation) =>
            operation is Map &&
            (operation['attributes'] as Map?)?['list'] == 'checked',
      ),
      isTrue,
    );
  });

  testWidgets('external surrounding edits preserve uncommitted IME row text', (
    tester,
  ) async {
    final codec = ChecklistDeltaCodec();
    final initialBody = <Map<String, dynamic>>[
      {'insert': 'Before\n'},
      {'insert': 'Task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': 'After\n'},
    ];
    final block = codec
        .scanChecklistBlocks(documentFromJsonSafe(initialBody))
        .single
        .slice!
        .copyWith(document: RichChecklistDocument([_item('a', 'Task')]));
    final note = _RecordingNote(
      id: 45,
      title: 'Mixed',
      content: codec.encodeCombinedBodyJson(
        title: 'Mixed',
        bodyDelta: initialBody,
      ),
    );
    await tester.pumpWidget(
      _host(
        RichChecklistEditor(
          note: note,
          session: ChecklistBlockEditSession(
            title: 'Mixed',
            bodyDelta: initialBody,
            block: block,
            selectionStart: block.startOffset,
            selectionEnd: block.startOffset,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('checklist-text-lane-a')));
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Task local\n',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 5, end: 10),
      ),
    );
    await tester.pump();
    final remoteBody = <Map<String, dynamic>>[
      {'insert': 'Remote before\n'},
      {'insert': 'Task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': 'After\n'},
    ];
    _RecordingNote(
      id: 45,
      title: 'Remote title',
      content: codec.encodeCombinedBodyJson(
        title: 'Remote title',
        bodyDelta: remoteBody,
      ),
    ).notify('updated', false);
    await tester.pump();

    expect(find.byType(MaterialBanner), findsNothing);
    expect(
      tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller
          .document
          .toPlainText(),
      'Task local\n',
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Task local\n',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 1100));

    expect(note.saveCalls, 1);
    expect(
      documentFromJsonSafe(
        codec.tryParseCombinedJson(note.content)!.bodyDelta,
      ).toPlainText(),
      'Remote before\nTask local\nAfter\n',
    );
  });

  testWidgets('an older save cannot clear a newer local revision', (
    tester,
  ) async {
    final document = RichChecklistDocument([_item('a', 'Task')]);
    final note = _DeferredSaveNote(content: _content('Tasks', document.items));
    await _pumpEditor(tester, note: note, title: 'Tasks', document: document);
    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;

    controller.replaceText(
      0,
      4,
      'First edit',
      const TextSelection.collapsed(offset: 10),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(note.saveCalls, 1);

    controller.replaceText(
      0,
      10,
      'Second edit',
      const TextSelection.collapsed(offset: 11),
    );
    await tester.pump(const Duration(milliseconds: 220));
    note.completeFirstSave();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    expect(note.saveCalls, 2);
    expect(
      ChecklistDeltaCodec()
          .tryParseCombinedJson(note.content)!
          .bodyDelta
          .map((operation) => operation['insert'])
          .whereType<String>()
          .join(),
      'Second edit\n',
    );
  });

  testWidgets('reload conflict action replaces dirty local state', (
    tester,
  ) async {
    final initial = RichChecklistDocument([_item('a', 'Local task')]);
    final note = _RecordingNote(
      id: 42,
      title: 'Local',
      content: _content('Local', initial.items),
    );
    await _pumpEditor(tester, note: note, title: 'Local', document: initial);

    await tester.tap(find.byKey(const ValueKey('checklist-checkbox-a')));
    await tester.pump(const Duration(milliseconds: 100));
    _RecordingNote(
      id: 42,
      title: 'Remote',
      content: _content('Remote', [_item('remote', 'Remote task')]),
    ).notify('updated', false);
    await tester.pump();

    await tester.tap(find.text('Reload'));
    await tester.pump();

    expect(find.byType(MaterialBanner), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rich_checklist_note_title')))
          .data,
      'Remote',
    );
    expect(find.byType(TextField), findsNothing);
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(editor.controller.document.toPlainText(), 'Remote task\n');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(note.saveCalls, 0);
  });

  testWidgets('collection keeps missing contextual section labels empty', (
    tester,
  ) async {
    final codec = ChecklistDeltaCodec();
    final body = <Map<String, dynamic>>[
      {'insert': 'First task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': '\n'},
      {
        'insert': {'image': 'between.png'},
      },
      {'insert': '\n'},
      {'insert': 'Second task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
    ];
    final session = codec.createCollectionEditSession(
      title: 'Lists',
      document: documentFromJsonSafe(body),
      selectionStart: 0,
      selectionEnd: 0,
    )!;
    await tester.pumpWidget(
      _host(
        RichChecklistCollectionEditor(
          note: Note(
            title: 'Lists',
            readOnly: true,
            content: codec.encodeCombinedBodyJson(
              title: 'Lists',
              bodyDelta: body,
            ),
          ),
          session: session,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Checklist 1'), findsNothing);
    expect(find.text('Checklist 2'), findsNothing);
    expect(find.text('0/1'), findsNWidgets(2));
    expect(find.text('0/2'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rich_checklist_note_title')))
          .data,
      'Lists',
    );
  });

  testWidgets('an inactive sole section row cannot be deleted', (tester) async {
    final codec = ChecklistDeltaCodec();
    final body = <Map<String, dynamic>>[
      {'insert': 'First task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {
        'insert': {'image': 'between.png'},
      },
      {'insert': '\n'},
      {'insert': 'Second task'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
    ];
    final session = codec.createCollectionEditSession(
      title: 'Lists',
      document: documentFromJsonSafe(body),
      selectionStart: 0,
      selectionEnd: 0,
    )!;
    await tester.pumpWidget(
      _host(
        RichChecklistCollectionEditor(
          note: _RecordingNote(
            title: 'Lists',
            content: codec.encodeCombinedBodyJson(
              title: 'Lists',
              bodyDelta: body,
            ),
          ),
          session: session,
        ),
      ),
    );
    await tester.pump();

    final secondRow = find.ancestor(
      of: find.text('Second task', findRichText: true),
      matching: find.byType(Dismissible),
    );
    expect(
      tester.widget<Dismissible>(secondRow).direction,
      DismissDirection.none,
    );

    await tester.tap(
      find.descendant(
        of: secondRow,
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    final deleteItem = tester.widget<PopupMenuItem<String>>(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String> && widget.value == 'delete',
      ),
    );
    expect(deleteItem.enabled, isFalse);
  });

  testWidgets(
    'whole-note counter opens editable contextual checklist sections',
    (tester) async {
      final codec = ChecklistDeltaCodec();
      final body = <Map<String, dynamic>>[
        {'insert': 'Groceries\n'},
        {'insert': 'Milk'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {
          'insert': {'image': 'between.png'},
        },
        {'insert': '\nCalls\n'},
        {'insert': 'Call Mom'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': 'Tail\n'},
      ];
      final note = _RecordingNote(
        id: 91,
        title: 'Mixed',
        content: codec.encodeCombinedBodyJson(title: 'Mixed', bodyDelta: body),
      );
      await tester.pumpWidget(_host(NoteEditor(note: note)));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('note_checkbox_progress_title')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RichChecklistCollectionEditor), findsOneWidget);
      expect(
        find.byKey(const ValueKey('rich_checklist_collection_scroll_view')),
        findsOneWidget,
      );
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Calls'), findsOneWidget);
      expect(find.text('0/2'), findsOneWidget);
      expect(find.byType(QuillEditor), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('Milk', findRichText: true));
      await tester.pump();
      final rowEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      rowEditor.controller.replaceText(
        0,
        4,
        'Oat milk',
        const TextSelection.collapsed(offset: 8),
      );
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(find.text('Call Mom', findRichText: true));
      await tester.pump();
      rowEditor.controller.replaceText(
        0,
        8,
        'Call Dad',
        const TextSelection.collapsed(offset: 8),
      );
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      final normalEditor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      expect(
        normalEditor.controller.document.toPlainText(),
        'Groceries\nOat milk\n￼\nCalls\nCall Dad\nTail\n',
      );
      final savedBody = codec.tryParseCombinedJson(note.content)!.bodyDelta;
      expect(
        savedBody.any(
          (operation) =>
              operation['insert'] is Map &&
              (operation['insert'] as Map)['image'] == 'between.png',
        ),
        isTrue,
      );

      normalEditor.controller.undo();
      await tester.pump();
      expect(
        normalEditor.controller.document.toPlainText(),
        'Groceries\nMilk\n￼\nCalls\nCall Mom\nTail\n',
      );
    },
  );

  testWidgets('collection page keeps unsupported checklist blocks visible', (
    tester,
  ) async {
    final codec = ChecklistDeltaCodec();
    final body = <Map<String, dynamic>>[
      {'insert': 'Valid\nTask'},
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
      {'insert': 'Attachment task\n'},
      {
        'insert': {'image': 'unsupported.png'},
      },
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
    ];
    final note = Note(
      readOnly: true,
      title: 'Mixed',
      content: codec.encodeCombinedBodyJson(title: 'Mixed', bodyDelta: body),
    );
    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('note_checkbox_progress_title')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'unsupported-checklist-section-',
            ),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Attachments and block formatting are available only in the rich-text editor.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('whole-note counter stays tappable on a narrow phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final document = RichChecklistDocument([_item('a', 'Task')]);
    await tester.pumpWidget(
      _host(
        NoteEditor(
          note: Note(
            readOnly: true,
            content: _content('Tasks', document.items),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final counter = find.byKey(const ValueKey('note_checkbox_progress_title'));
    expect(counter, findsOneWidget);
    expect(tester.getSize(counter).height, greaterThanOrEqualTo(48));
    expect(
      find.descendant(of: counter, matching: find.byType(Icon)),
      findsNothing,
    );

    await tester.tap(counter);
    await tester.pumpAndSettle();
    expect(find.byType(RichChecklistCollectionEditor), findsOneWidget);
  });

  testWidgets('checklist row menus no longer offer text conversion', (
    tester,
  ) async {
    final document = RichChecklistDocument([
      _item('a', 'First'),
      _item('b', 'Second'),
    ]);
    await _pumpEditor(tester, note: Note(), document: document);

    final row = find.ancestor(
      of: find.text('Second', findRichText: true),
      matching: find.byType(Dismissible),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Convert to normal text'), findsNothing);
  });

  testWidgets('To-do launch opens normal Quill and Back returns its caller', (
    tester,
  ) async {
    final note = _RecordingNote(
      id: 42,
      title: 'Tasks',
      content: _emptyTodoContent(),
    );

    await tester.pumpWidget(_todoLaunchHost(note));
    await tester.tap(find.text('Create To-do'));
    await tester.pumpAndSettle();

    expect(find.byType(RichChecklistEditor), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
    final editor = tester.widget<NoteEditor>(find.byType(NoteEditor));
    expect(editor.autoFocus, isTrue);
    expect(editor.deleteIfUnchanged, isTrue);
    final quill = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(quill.controller.document.toDelta().toJson(), [
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
    ]);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsNothing);
    expect(find.text('Create To-do'), findsOneWidget);
    expect(note.deleteCalls, 1);
    expect(note.saveCalls, 0);
  });

  testWidgets('To-do launch preserves entered task content', (tester) async {
    final note = _RecordingNote(
      id: 43,
      title: 'Tasks',
      content: _emptyTodoContent(),
    );

    await tester.pumpWidget(_todoLaunchHost(note));
    await tester.tap(find.text('Create To-do'));
    await tester.pumpAndSettle();

    final quill = tester.widget<QuillEditor>(find.byType(QuillEditor));
    quill.controller.replaceText(
      0,
      0,
      'Buy milk',
      const TextSelection.collapsed(offset: 8),
    );
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsNothing);
    expect(note.deleteCalls, 0);
    expect(note.saveCalls, 1);
    expect(note.plainText, 'Tasks\nBuy milk');
  });

  testWidgets('normal editor enables comfortable list spacing', (tester) async {
    final note = Note(
      readOnly: true,
      content: jsonEncode([
        {'insert': 'A checklist item that may wrap'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]),
    );

    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final lists = editor.config.customStyles?.lists;
    expect(lists?.style.height, 1.25);
    expect(lists?.verticalSpacing.top, 0);
    expect(lists?.verticalSpacing.bottom, 0);
    expect(lists?.lineSpacing.top, 0);
    expect(lists?.lineSpacing.bottom, 6);
  });

  testWidgets('normal checklist toolbar remains a formatting toggle', (
    tester,
  ) async {
    final note = _RecordingNote(
      content: jsonEncode([
        {'insert': 'Ordinary line\n'},
      ]),
    );
    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ordinary line', findRichText: true));
    await tester.pump();

    final checklistButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.check_box_outlined),
        matching: find.byType(IconButton),
      ),
    );
    checklistButton.onPressed!();
    await tester.pump();

    expect(find.byType(RichChecklistEditor), findsNothing);
    final quill = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(quill.controller.document.toDelta().toJson().last['attributes'], {
      'list': 'unchecked',
    });

    tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.check_box_outlined),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!();
    await tester.pump();
    expect(
      quill.controller.document.toDelta().toJson().last['attributes'],
      isNull,
    );
  });

  testWidgets('NoteEditor offers focused view for a checklist caret', (
    tester,
  ) async {
    final checklist = RichChecklistDocument([_item('a', 'Formatted task')]);
    final note = Note(
      readOnly: true,
      content: _content('Tasks', checklist.items),
    );
    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);
    var taskText = find.text('Formatted task', findRichText: true);
    await tester.tap(taskText);
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<QuillEditor>(find.byType(QuillEditor)).focusNode.hasFocus,
      isTrue,
    );

    expect(
      find.byKey(const ValueKey('open_focused_checklist')),
      findsOneWidget,
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('open_focused_checklist_popup')))
          .bottom,
      lessThanOrEqualTo(tester.getRect(taskText).top),
    );
    expect(
      find.byKey(const ValueKey('focused_checklist_popup_barrier')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('focused_checklist_popup_barrier')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);
    expect(
      find.byKey(const ValueKey('focused_checklist_popup_barrier')),
      findsNothing,
    );

    // The transparent barrier consumes the outside tap. A later, deliberate
    // caret tap can offer the focused view again in the same editor visit.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(taskText);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('open_focused_checklist')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('dismiss_focused_checklist_popup')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);

    final sameVisitQuill = tester.widget<QuillEditor>(find.byType(QuillEditor));
    sameVisitQuill.focusNode.unfocus();
    await tester.pump();
    sameVisitQuill.focusNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);

    // Passive focus changes do not undo dismissal. A fresh visit may prompt
    // again as soon as the user places a caret.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _host(
        NoteEditor(key: const ValueKey('reopened-checklist-note'), note: note),
      ),
    );
    await tester.pumpAndSettle();
    taskText = find.text('Formatted task', findRichText: true);
    await tester.tap(taskText);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('open_focused_checklist')),
      findsOneWidget,
    );

    final reopenedQuill = tester.widget<QuillEditor>(find.byType(QuillEditor));
    reopenedQuill.controller.updateSelection(
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open_focused_checklist')));
    await tester.pumpAndSettle();
    expect(find.byType(RichChecklistEditor), findsOneWidget);
    expect(
      tester.getSize(
        find.descendant(
          of: find.byType(RichChecklistEditor),
          matching: find.byType(Scaffold),
        ),
      ),
      const Size(800, 600),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(RichChecklistEditor),
        matching: find.byType(BackButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(
      tester.widget<QuillEditor>(find.byType(QuillEditor)).controller.selection,
      const TextSelection.collapsed(offset: 3),
    );
    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _host(
        NoteEditor(
          key: const ValueKey('reopened-after-focused-view'),
          note: note,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Formatted task', findRichText: true));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('open_focused_checklist')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      _host(
        NoteEditor(
          key: const ValueKey('mixed-note-editor'),
          note: Note(
            readOnly: true,
            content: jsonEncode([
              {'insert': 'Ordinary paragraph\n'},
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open_focused_checklist')), findsNothing);
  });

  testWidgets('opens and saves only the selected block in a mixed note', (
    tester,
  ) async {
    final note = _RecordingNote(
      content: jsonEncode([
        {'insert': 'Mixed'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': 'First block'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': 'Paragraph\n'},
        {'insert': 'Second block'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]),
    );

    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Second block', findRichText: true));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('open_focused_checklist')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('open_focused_checklist')));
    await tester.pumpAndSettle();

    expect(find.byType(RichChecklistEditor), findsOneWidget);
    expect(find.text('Second block', findRichText: true), findsOneWidget);
    expect(find.text('First block', findRichText: true), findsNothing);
    expect(find.text('Paragraph', findRichText: true), findsNothing);

    final saveCallsBeforeEdit = note.saveCalls;
    final rowController = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    rowController.replaceText(
      0,
      'Second block'.length,
      'Second edited',
      const TextSelection.collapsed(offset: 13),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 1100));

    expect(note.saveCalls, saveCallsBeforeEdit + 1);
    expect(
      documentFromJsonSafe(
        ChecklistDeltaCodec().tryParseCombinedJson(note.content)!.bodyDelta,
      ).toPlainText(),
      'First block\nParagraph\nSecond edited\n',
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(RichChecklistEditor), findsNothing);
    expect(
      tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller
          .document
          .toPlainText(),
      'First block\nParagraph\nSecond edited\n',
    );
  });

  testWidgets('positions the popup within a Motorola-sized keyboard viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(424, 924);
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    addTearDown(tester.view.reset);

    final checklist = RichChecklistDocument([_item('a', 'Device task')]);
    final note = Note(
      readOnly: true,
      content: _content('Tasks', checklist.items),
    );
    await tester.pumpWidget(_host(NoteEditor(note: note)));
    await tester.pumpAndSettle();
    final taskText = find.text('Device task', findRichText: true);
    await tester.tap(taskText);
    await tester.pump();
    await tester.pump();

    final popup = tester.getRect(
      find.byKey(const ValueKey('open_focused_checklist_popup')),
    );
    expect(popup.left, greaterThanOrEqualTo(8));
    expect(popup.right, lessThanOrEqualTo(416));
    expect(popup.top, greaterThanOrEqualTo(8));
    expect(popup.bottom, lessThanOrEqualTo(tester.getRect(taskText).top));
  });
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required Note note,
  required RichChecklistDocument document,
  String title = '',
  TargetPlatform? platform,
}) async {
  final codec = ChecklistDeltaCodec();
  final body = codec.encodeBody(document);
  final block = codec
      .findChecklistBlockAt(documentFromJsonSafe(body), 0)
      .slice!
      .copyWith(document: document);
  await tester.pumpWidget(
    _host(
      RichChecklistEditor(
        note: note,
        session: ChecklistBlockEditSession(
          title: title,
          bodyDelta: body,
          block: block,
          selectionStart: 0,
          selectionEnd: 0,
        ),
      ),
      platform: platform,
    ),
  );
  await tester.pump();
}

Widget _host(Widget home, {TargetPlatform? platform}) => MaterialApp(
  localizationsDelegates: betterKeepLocalizationDelegates,
  supportedLocales: betterKeepSupportedLocales,
  theme: ThemeData(platform: platform),
  home: home,
);

Widget _todoLaunchHost(Note note) => _host(
  Builder(
    builder: (context) => ElevatedButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              NoteEditor(note: note, autoFocus: true, deleteIfUnchanged: true),
        ),
      ),
      child: const Text('Create To-do'),
    ),
  ),
);

Widget _focusedLaunchHost(
  Note note,
  RichChecklistDocument document, {
  ValueChanged<Object?>? onResult,
}) {
  final codec = ChecklistDeltaCodec();
  final body = codec.encodeBody(document);
  final block = codec
      .findChecklistBlockAt(documentFromJsonSafe(body), 0)
      .slice!
      .copyWith(document: document);
  return _host(
    Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          final result = await Navigator.of(context).push(
            MaterialPageRoute<Object?>(
              builder: (_) => RichChecklistEditor(
                note: note,
                session: ChecklistBlockEditSession(
                  title: note.title ?? '',
                  bodyDelta: body,
                  block: block,
                  selectionStart: 0,
                  selectionEnd: 0,
                ),
              ),
            ),
          );
          onResult?.call(result);
        },
        child: const Text('Open checklist'),
      ),
    ),
  );
}

double _firstGlyphCenter(WidgetTester tester, Finder richText) {
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final box = paragraph
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .first;
  return paragraph.localToGlobal(Offset(0, (box.top + box.bottom) / 2)).dy;
}

RichChecklistItem _item(
  String id,
  String text, {
  bool checked = false,
  int indent = 0,
  Map<String, dynamic>? attributes,
  Map<String, dynamic> lineAttributes = const {},
}) => RichChecklistItem(
  id: id,
  inlineDelta: [
    {'insert': text, 'attributes': ?attributes},
  ],
  checked: checked,
  indent: indent,
  lineAttributes: lineAttributes,
);

String _content(String title, Iterable<RichChecklistItem> items) =>
    ChecklistDeltaCodec().encodeCombinedJson(
      title: title,
      document: RichChecklistDocument(items),
    );

String _emptyTodoContent() => jsonEncode([
  {'insert': 'Tasks'},
  {
    'insert': '\n',
    'attributes': {'header': 1},
  },
  {
    'insert': '\n',
    'attributes': {'list': 'unchecked'},
  },
]);

class _RecordingNote extends Note {
  _RecordingNote({super.id, super.title, super.content, super.locked});

  int saveCalls = 0;
  int deleteCalls = 0;

  @override
  Future<int> delete({
    bool trackSync = true,
    ModelChangeOrigin origin = ModelChangeOrigin.local,
  }) async {
    deleteCalls++;
    return id == null ? 0 : 1;
  }

  @override
  Future<int> saveEditorSnapshot({
    required String title,
    required String content,
    required String plainText,
    bool trackSync = true,
  }) async {
    saveCalls++;
    this.title = title;
    this.content = content;
    this.plainText = plainText;
    return id ?? 1;
  }
}

class _DeferredSaveNote extends _RecordingNote {
  _DeferredSaveNote({super.id, super.title, super.content});

  final Completer<void> _firstSave = Completer<void>();

  void completeFirstSave() => _firstSave.complete();

  @override
  Future<int> saveEditorSnapshot({
    required String title,
    required String content,
    required String plainText,
    bool trackSync = true,
  }) async {
    saveCalls++;
    if (saveCalls == 1) await _firstSave.future;
    this.title = title;
    this.content = content;
    this.plainText = plainText;
    return id ?? 1;
  }
}
