import 'package:better_keep/utils/quill_vertical_selection_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bare vertical arrows collapse selections to their directional endpoint',
    (tester) async {
      const text = 'alpha line\nbravo line\ncharlie line\n';
      final harness = await _pumpEditor(tester, text);

      for (final selection in const [
        TextSelection(baseOffset: 2, extentOffset: 29),
        TextSelection(baseOffset: 29, extentOffset: 2),
        TextSelection(baseOffset: 2, extentOffset: 7),
        TextSelection(baseOffset: 7, extentOffset: 2),
      ]) {
        for (final expectation in [
          (key: LogicalKeyboardKey.arrowUp, offset: selection.start),
          (key: LogicalKeyboardKey.arrowDown, offset: selection.end),
        ]) {
          harness.controller.updateSelection(selection, ChangeSource.local);
          await tester.pump();
          await tester.sendKeyEvent(expectation.key);
          await tester.pump();
          expect(
            harness.controller.selection,
            TextSelection.collapsed(offset: expectation.offset),
          );
        }
      }
      await tester.pump(const Duration(milliseconds: 600));
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('Escape collapses to the active end without editing the note', (
    tester,
  ) async {
    const text = 'alpha line\nbravo line\ncharlie line\n';
    final harness = await _pumpEditor(tester, text);
    final deltaBefore = harness.controller.document.toDelta();

    for (final selection in const [
      TextSelection(baseOffset: 2, extentOffset: 29),
      TextSelection(baseOffset: 29, extentOffset: 2),
    ]) {
      harness.controller.updateSelection(selection, ChangeSource.local);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        harness.controller.selection,
        TextSelection.collapsed(offset: selection.extentOffset),
      );
      expect(harness.focusNode.hasFocus, isTrue);
      expect(harness.controller.document.toDelta(), deltaBefore);
      expect(harness.controller.hasUndo, isFalse);
    }
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('selection keys remain available in a read-only editor', (
    tester,
  ) async {
    const text = 'alpha line\nbravo line\n';
    final harness = await _pumpEditor(tester, text, readOnly: true);

    harness.controller.updateSelection(
      const TextSelection(baseOffset: 2, extentOffset: 15),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      harness.controller.selection,
      const TextSelection.collapsed(offset: 15),
    );

    harness.controller.updateSelection(
      const TextSelection(baseOffset: 15, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      harness.controller.selection,
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('external caret changes reset upward and downward runs', (
    tester,
  ) async {
    const text = 'alpha line\nbravo line\ncharlie line\ndelta line\n';
    final harness = await _pumpEditor(tester, text);
    final renderEditor = harness.editorKey.currentState!.renderEditor;

    final lastLineCaret = text.indexOf('delta') + 5;
    harness.controller.updateSelection(
      TextSelection.collapsed(offset: lastLineCaret),
      ChangeSource.local,
    );
    await tester.pump();
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(harness.controller.selection.isCollapsed, isFalse);

    // Simulates the browser collapsing the selection with an unmodified Down
    // key without advancing Flutter Quill's cached vertical movement run.
    harness.controller.updateSelection(
      TextSelection.collapsed(offset: lastLineCaret),
      ChangeSource.local,
    );
    await tester.pump();
    final upwardRun = renderEditor.startVerticalCaretMovement(
      TextPosition(offset: lastLineCaret),
    )..movePrevious();
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
    expect(harness.controller.selection.baseOffset, lastLineCaret);
    expect(harness.controller.selection.extentOffset, upwardRun.current.offset);

    final firstLineCaret = text.indexOf('alpha') + 5;
    harness.controller.updateSelection(
      TextSelection.collapsed(offset: firstLineCaret),
      ChangeSource.local,
    );
    await tester.pump();
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowDown);
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.controller.selection.isCollapsed, isFalse);

    // Mirrors a browser-driven collapse with an unmodified Up key.
    harness.controller.updateSelection(
      TextSelection.collapsed(offset: firstLineCaret),
      ChangeSource.local,
    );
    await tester.pump();
    final downwardRun = renderEditor.startVerticalCaretMovement(
      TextPosition(offset: firstLineCaret),
    )..moveNext();
    await _sendShiftArrow(tester, LogicalKeyboardKey.arrowDown);
    expect(harness.controller.selection.baseOffset, firstLineCaret);
    expect(
      harness.controller.selection.extentOffset,
      downwardRun.current.offset,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
    'continuous vertical movement preserves its column and reverses',
    (tester) async {
      const text = 'abcdefghij\nxy\nabcdefghij\n';
      final harness = await _pumpEditor(tester, text);
      const startOffset = 8;
      harness.controller.updateSelection(
        const TextSelection.collapsed(offset: startOffset),
        ChangeSource.local,
      );
      await tester.pump();

      final expectedRun = harness.editorKey.currentState!.renderEditor
          .startVerticalCaretMovement(const TextPosition(offset: startOffset));
      expectedRun.moveNext();
      final shortLineOffset = expectedRun.current.offset;
      expectedRun.moveNext();
      final restoredColumnOffset = expectedRun.current.offset;

      await _sendShiftArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(harness.controller.selection.extentOffset, shortLineOffset);
      await _sendShiftArrow(tester, LogicalKeyboardKey.arrowDown);
      expect(harness.controller.selection.extentOffset, restoredColumnOffset);
      await _sendShiftArrow(tester, LogicalKeyboardKey.arrowUp);
      expect(harness.controller.selection.extentOffset, shortLineOffset);
      expect(harness.controller.selection.baseOffset, startOffset);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );
}

Future<
  ({
    QuillController controller,
    FocusNode focusNode,
    GlobalKey<EditorState> editorKey,
  })
>
_pumpEditor(WidgetTester tester, String text, {bool readOnly = false}) async {
  final controller = QuillController(
    readOnly: readOnly,
    document: Document.fromJson([
      {'insert': text},
    ]),
    selection: const TextSelection.collapsed(offset: 0),
  );
  final focusNode = FocusNode();
  final editorKey = GlobalKey<EditorState>();
  final action = QuillVerticalSelectionAction(
    controller: controller,
    editorKey: editorKey,
    focusNode: focusNode,
  );
  addTearDown(() {
    action.dispose();
    focusNode.dispose();
    controller.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QuillEditor.basic(
          controller: controller,
          focusNode: focusNode,
          config: QuillEditorConfig(
            editorKey: editorKey,
            onKeyPressed: (event, _) => _handleKey(action, event),
            customActions: <Type, Action<Intent>>{
              ExtendSelectionVerticallyToAdjacentLineIntent: action,
            },
          ),
        ),
      ),
    ),
  );
  focusNode.requestFocus();
  await tester.pump();
  return (controller: controller, focusNode: focusNode, editorKey: editorKey);
}

KeyEventResult? _handleKey(
  QuillVerticalSelectionAction action,
  KeyEvent event,
) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  final keyboard = HardwareKeyboard.instance;
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return null;
    }
    return action.dismissSelectionFromKeyboard()
        ? KeyEventResult.handled
        : null;
  }
  if (keyboard.isAltPressed ||
      keyboard.isControlPressed ||
      keyboard.isMetaPressed) {
    return null;
  }
  final forward = switch (event.logicalKey) {
    LogicalKeyboardKey.arrowUp => false,
    LogicalKeyboardKey.arrowDown => true,
    _ => null,
  };
  if (forward == null) return null;
  return action.invokeFromKeyboard(
        forward: forward,
        extendSelection: keyboard.isShiftPressed,
      )
      ? KeyEventResult.handled
      : null;
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
