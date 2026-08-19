import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
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

  testWidgets('blank space focuses short notes at the document end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final lines in const [
      ['One line'],
      ['First line', 'Second line'],
    ]) {
      await _pumpNoteEditor(
        tester,
        bodyDelta: [
          for (final line in lines) {'insert': '$line\n'},
        ],
      );
      final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      final surface = tester.getRect(
        find.byKey(const ValueKey('note_editor_scroll_surface')),
      );
      final editorRect = tester.getRect(find.byType(QuillEditor));
      expect(surface.bottom, greaterThan(editorRect.bottom + 40));
      expect(editor.focusNode.hasFocus, isFalse);

      await tester.tapAt(Offset(surface.center.dx, surface.bottom - 24));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(editor.focusNode.hasFocus, isTrue);
      expect(
        editor.controller.selection,
        TextSelection.collapsed(offset: editor.controller.document.length - 1),
      );
      expect(find.byKey(const Key('note_editor_toolbar')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('text and title taps keep their native focus behavior', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'First line\nSecond line\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));

    await tester.tap(find.text('First line', findRichText: true));
    await tester.pump();
    expect(editor.focusNode.hasFocus, isTrue);
    expect(
      editor.controller.selection.baseOffset,
      lessThan('First line'.length + 1),
    );

    final title = tester.widget<TextField>(find.byType(TextField).first);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(title.focusNode?.hasFocus, isTrue);
    expect(editor.focusNode.hasFocus, isFalse);
  });

  testWidgets('vertical selection restarts from an arrow-collapsed caret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'first line\nsecond line\nthird line\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final editorState = editor.config.editorKey!.currentState!;
    final lastLineCaret = editor.controller.document.length - 1;
    editor.controller.updateSelection(
      TextSelection.collapsed(offset: lastLineCaret),
      ChangeSource.local,
    );
    editor.focusNode.requestFocus();
    await tester.pump();

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(editor.controller.selection.isCollapsed, isFalse);
    final selectionBeforeCollapse = editor.controller.selection;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final collapsedCaret = editor.controller.selection;
    expect(
      collapsedCaret,
      TextSelection.collapsed(offset: selectionBeforeCollapse.end),
    );
    final expectedRun = editorState.renderEditor.startVerticalCaretMovement(
      collapsedCaret.extent,
    )..movePrevious();

    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(editor.controller.selection.baseOffset, collapsedCaret.baseOffset);
    expect(
      editor.controller.selection.extentOffset,
      expectedRun.current.offset,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('selection keys work in read-only and trashed normal notes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final state in const [
      (readOnly: true, trashed: false),
      (readOnly: false, trashed: true),
    ]) {
      await _pumpNoteEditor(
        tester,
        readOnly: state.readOnly,
        trashed: state.trashed,
        bodyDelta: const [
          {'insert': 'first line\nsecond line\nthird line\n'},
        ],
      );
      final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
      editor.focusNode.requestFocus();
      editor.controller.updateSelection(
        const TextSelection(baseOffset: 2, extentOffset: 25),
        ChangeSource.local,
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        editor.controller.selection,
        const TextSelection.collapsed(offset: 25),
      );

      editor.controller.updateSelection(
        const TextSelection(baseOffset: 25, extentOffset: 2),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        editor.controller.selection,
        const TextSelection.collapsed(offset: 2),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('desktop link taps focus the exact link and show its preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const linkText = 'Linked text';
    const url = 'https://example.invalid/link';
    await _pumpNoteEditor(
      tester,
      platform: TargetPlatform.macOS,
      bodyDelta: const [
        {
          'insert': linkText,
          'attributes': {'link': url},
        },
        {'insert': '\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    expect(editor.config.customRecognizerBuilder, isNotNull);
    final linkedText = find.text(linkText, findRichText: true);
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 41,
    );
    addTearDown(mouse.removePointer);

    var linkPosition = _globalTextPosition(tester, linkedText, 1);
    await mouse.addPointer(location: linkPosition);
    await mouse.down(linkPosition);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    final firstOffset = editor.controller.selection.baseOffset;
    expect(editor.focusNode.hasFocus, isTrue);
    expect(firstOffset, inInclusiveRange(0, linkText.length - 1));
    expect(
      editor.controller.document
          .collectStyle(firstOffset, 1)
          .attributes[Attribute.link.key]
          ?.value,
      url,
    );
    expect(
      find.byKey(const ValueKey('note_editor_link_preview')),
      findsOneWidget,
    );
    expect(find.text(url), findsWidgets);

    linkPosition = _globalTextPosition(tester, linkedText, 8);
    await mouse.moveTo(linkPosition);
    await mouse.down(linkPosition);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    final secondOffset = editor.controller.selection.baseOffset;
    expect(secondOffset, inInclusiveRange(0, linkText.length - 1));
    expect(secondOffset, greaterThan(firstOffset));
    expect(find.text(url), findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('note_editor_link_preview')),
      findsOneWidget,
    );
    expect(find.text(url), findsWidgets);
  });

  testWidgets('mobile editors keep Flutter Quill link gestures', (
    tester,
  ) async {
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      await _pumpNoteEditor(
        tester,
        platform: platform,
        bodyDelta: const [
          {
            'insert': 'Mobile link',
            'attributes': {'link': 'https://example.invalid/mobile'},
          },
          {'insert': '\n'},
        ],
      );

      expect(
        tester
            .widget<QuillEditor>(find.byType(QuillEditor))
            .config
            .customRecognizerBuilder,
        isNull,
        reason: '$platform should retain Flutter Quill link gestures',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('Add Link renders, cancels, inserts, and restores focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document(),
      selection: const TextSelection.collapsed(offset: 0),
    );

    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    var dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.controller.document.toPlainText(), '\n');

    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    dialog = find.byType(AlertDialog);
    final fields = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, 'Example');
    await tester.enterText(fields.last, 'https://example.com');
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, 'Add'),
      ),
    );
    await tester.pumpAndSettle();

    expect(harness.focusNode.hasFocus, isTrue);
    expect(harness.controller.document.toDelta().toJson(), [
      {
        'insert': 'Example',
        'attributes': {'link': 'https://example.com'},
      },
      {'insert': '\n'},
    ]);
    harness.controller.undo();
    await tester.pump();
    expect(harness.controller.document.toPlainText(), '\n');
  });

  testWidgets('scrolling is not treated as an empty-space tap', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: [
        {'insert': List.generate(80, (index) => 'Line $index').join('\n')},
        {'insert': '\n'},
      ],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    await tester.pump();

    final surface = find.byKey(const ValueKey('note_editor_scroll_surface'));
    await tester.drag(surface, const Offset(0, -300));
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: surface,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable.first).position.pixels,
      greaterThan(0),
    );
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
  });

  testWidgets('attachment taps keep their navigation gesture', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpNoteEditor(
      tester,
      bodyDelta: const [
        {'insert': 'Body\n'},
      ],
      attachments: [NoteAttachment.sketch(SketchData())],
    );
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final sketch = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is SketchPainter,
    );

    expect(editor.focusNode.hasFocus, isFalse);
    await tester.tap(sketch.first);
    await tester.pumpAndSettle();

    expect(find.byType(SketchPage), findsOneWidget);
    expect(editor.focusNode.hasFocus, isFalse);
  });

  testWidgets('line spacing can be applied and removed from an indent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document.fromJson(const [
        {'insert': 'Indented'},
        {
          'insert': '\n',
          'attributes': {'indent': 1},
        },
      ]),
      selection: const TextSelection.collapsed(offset: 2),
    );

    await tester.tap(find.byTooltip('Line Spacing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Relaxed'));
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().last, {
      'insert': '\n',
      'attributes': {'indent': 1, 'line-height': 1.5},
    });

    await tester.tap(find.byTooltip('Line Spacing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Spacing'));
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().last, {
      'insert': '\n',
      'attributes': {'indent': 1},
    });
    expect(harness.focusNode.hasFocus, isTrue);
  });

  testWidgets('Link toolbar converts, updates, and removes selected text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const text = 'Selected text';
    final harness = await _pumpToolbarHarness(
      tester,
      document: Document.fromJson(const [
        {
          'insert': text,
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: text.length),
    );

    await _submitLinkDialog(
      tester,
      action: 'Add',
      url: 'https://example.com/first',
    );
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
      'link': 'https://example.com/first',
    });

    harness.controller.updateSelection(
      const TextSelection.collapsed(offset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await _submitLinkDialog(
      tester,
      action: 'Update',
      url: 'https://example.com/updated',
    );
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
      'link': 'https://example.com/updated',
    });

    harness.controller.updateSelection(
      const TextSelection.collapsed(offset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Link'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Remove Link'),
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.controller.document.toDelta().toJson().first['attributes'], {
      'bold': true,
    });
    expect(harness.focusNode.hasFocus, isTrue);
  });
}

Offset _globalTextPosition(
  WidgetTester tester,
  Finder richText,
  int textOffset,
) {
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final caret = paragraph.getOffsetForCaret(
    TextPosition(offset: textOffset),
    Rect.zero,
  );
  return paragraph.localToGlobal(caret + const Offset(1, 8));
}

Future<void> _pumpNoteEditor(
  WidgetTester tester, {
  required List<Map<String, dynamic>> bodyDelta,
  List<NoteAttachment> attachments = const [],
  TargetPlatform platform = TargetPlatform.macOS,
  bool readOnly = false,
  bool trashed = false,
}) async {
  final content = jsonEncode([
    {'insert': 'Interaction note'},
    {
      'insert': '\n',
      'attributes': {'header': 1},
    },
    ...bodyDelta,
  ]);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      locale: const Locale('en'),
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: NoteEditor(
        note: Note(
          title: 'Interaction note',
          content: content,
          attachments: attachments,
          readOnly: readOnly,
          trashed: trashed,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<({QuillController controller, FocusNode focusNode})> _pumpToolbarHarness(
  WidgetTester tester, {
  required Document document,
  required TextSelection selection,
}) async {
  final controller = QuillController(document: document, selection: selection);
  final focusNode = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focusNode.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.macOS),
      locale: const Locale('en'),
      localizationsDelegates: betterKeepLocalizationDelegates,
      supportedLocales: betterKeepSupportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: QuillEditor.basic(
                controller: controller,
                focusNode: focusNode,
              ),
            ),
            NoteEditorToolbar(
              controller: controller,
              focusNode: focusNode,
              readOnly: false,
              parentColor: Colors.white,
              showHistory: false,
              showAttachments: false,
              showChecklist: false,
              showBlockLists: false,
              showIndent: false,
            ),
          ],
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  return (controller: controller, focusNode: focusNode);
}

Future<void> _submitLinkDialog(
  WidgetTester tester, {
  required String action,
  required String url,
}) async {
  await tester.tap(find.byTooltip('Link'));
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  final fields = find.descendant(of: dialog, matching: find.byType(TextField));
  await tester.enterText(fields.last, url);
  await tester.tap(
    find.descendant(
      of: dialog,
      matching: find.widgetWithText(FilledButton, action),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _sendShiftArrow(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(arrow);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}
