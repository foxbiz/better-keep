import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Normalizes hardware-keyboard vertical selection movement while keeping
/// Flutter Quill's preferred horizontal caret position between consecutive
/// Shift+Arrow presses.
class QuillVerticalSelectionAction
    extends ContextAction<ExtendSelectionVerticallyToAdjacentLineIntent> {
  QuillVerticalSelectionAction({
    required this.controller,
    required this.editorKey,
    required this.focusNode,
  }) {
    controller.addListener(_handleControllerChange);
  }

  final QuillController controller;
  final GlobalKey<EditorState> editorKey;
  final FocusNode focusNode;

  QuillVerticalCaretMovementRun? _verticalMovementRun;
  TextSelection? _runSelection;
  bool _isApplyingSelection = false;

  void _handleControllerChange() {
    if (!_isApplyingSelection) _resetVerticalRun();
  }

  void _resetVerticalRun() {
    _verticalMovementRun = null;
    _runSelection = null;
  }

  /// Invokes the action from Quill's early raw-key hook.
  ///
  /// Real browser arrow events can update the DOM selection before Flutter's
  /// shortcut dispatcher reaches [customActions]. Handling them at Quill's
  /// `onKeyPressed` hook keeps the movement on this single, resettable path.
  bool invokeFromKeyboard({
    required bool forward,
    required bool extendSelection,
  }) {
    final context = focusNode.context;
    if (context == null || editorKey.currentState == null) return false;
    invoke(
      ExtendSelectionVerticallyToAdjacentLineIntent(
        forward: forward,
        collapseSelection: !extendSelection,
      ),
      context,
    );
    return true;
  }

  /// Collapses an expanded selection to the endpoint the user was extending.
  bool dismissSelectionFromKeyboard() {
    final context = focusNode.context;
    final editorState = editorKey.currentState;
    final value = editorState?.textEditingValue;
    if (context == null ||
        editorState == null ||
        value == null ||
        !value.selection.isValid ||
        value.selection.isCollapsed) {
      return false;
    }

    final newSelection = TextSelection.collapsed(
      offset: value.selection.extentOffset,
      affinity: value.selection.affinity,
    );
    _applySelection(context, value, newSelection);
    _resetVerticalRun();
    return controller.selection == newSelection;
  }

  @override
  Object? invoke(
    ExtendSelectionVerticallyToAdjacentLineIntent intent, [
    BuildContext? context,
  ]) {
    final editorState = editorKey.currentState;
    final value = editorState?.textEditingValue;
    if (editorState == null ||
        context == null ||
        value == null ||
        !value.selection.isValid) {
      _resetVerticalRun();
      return null;
    }

    // A browser/native selection update can arrive without going through this
    // Action. Reset here as a second line of defense if the controller listener
    // did not observe it before this invocation.
    if (_runSelection != null && _runSelection != value.selection) {
      _resetVerticalRun();
    }

    final collapseSelection =
        intent.collapseSelection || !editorState.widget.config.selectionEnabled;
    if (collapseSelection && !value.selection.isCollapsed) {
      final targetOffset = intent.forward
          ? value.selection.end
          : value.selection.start;
      final newSelection = TextSelection.collapsed(
        offset: targetOffset,
        affinity: value.selection.affinity,
      );
      final result = _applySelection(context, value, newSelection);
      _resetVerticalRun();
      return result;
    }

    final currentRun =
        _verticalMovementRun ??
        editorState.renderEditor.startVerticalCaretMovement(
          editorState.renderEditor.selection.extent,
        );
    final shouldMove = intent.forward
        ? currentRun.moveNext()
        : currentRun.movePrevious();
    final newExtent = shouldMove
        ? currentRun.current
        : intent.forward
        ? TextPosition(offset: value.text.length)
        : const TextPosition(offset: 0);
    final newSelection = collapseSelection
        ? TextSelection.fromPosition(newExtent)
        : value.selection.extendTo(newExtent);

    final result = _applySelection(context, value, newSelection);

    if (controller.selection == newSelection) {
      _verticalMovementRun = currentRun;
      _runSelection = newSelection;
    } else {
      _resetVerticalRun();
    }
    return result;
  }

  Object? _applySelection(
    BuildContext context,
    TextEditingValue value,
    TextSelection newSelection,
  ) {
    Object? result;
    _isApplyingSelection = true;
    try {
      result = Actions.invoke(
        context,
        UpdateSelectionIntent(
          value,
          newSelection,
          SelectionChangedCause.keyboard,
        ),
      );
    } finally {
      _isApplyingSelection = false;
    }
    return result;
  }

  void dispose() {
    controller.removeListener(_handleControllerChange);
  }
}
