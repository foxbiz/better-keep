import 'dart:async';

import 'package:better_keep/utils/note_embed_rules.dart';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Routes the existing toolbar to the focused note or table cell.
class NoteEmbedEditing extends ChangeNotifier {
  final _regions = <GlobalKey, QuillController>{};

  bool handlesTapDown(
    QuillController owner,
    TapDownDetails details,
    EditorState? editor, [
    FocusNode? focus,
  ]) {
    if (!handlesGesture(owner, details.globalPosition) &&
        !(focus != null &&
            _focusAfterTable(owner, details.globalPosition, focus, editor))) {
      return false;
    }
    if (editor == null) return true;
    // Quill runs its double-tap handler even when onTapDown handled the tap.
    // Initialize its tap position, but suppress parent selection for this
    // dispatch so a rapid cell/control tap cannot select or refocus the note.
    final render = editor.renderEditor;
    render.handleTapDown(details);
    final previous = render.onSelectionChanged;
    void ignore(TextSelection selection, SelectionChangedCause cause) {}
    render.onSelectionChanged = ignore;
    scheduleMicrotask(() {
      // The same double-tap dispatch can also queue a parent context menu.
      // Dismiss it before focus changes disable that editor's menu builder.
      if (editor.mounted) editor.hideToolbar();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (editor.mounted) editor.hideToolbar();
      });
      if (identical(render.onSelectionChanged, ignore)) {
        render.onSelectionChanged = previous;
      }
    });
    return true;
  }

  bool handlesTapUp(
    QuillController owner,
    TapUpDetails details,
    FocusNode focus, [
    EditorState? editor,
  ]) {
    if (handlesGesture(owner, details.globalPosition)) return true;
    if (owner.readOnly) return false;
    if (_focusAfterTable(owner, details.globalPosition, focus, editor)) {
      return true;
    }
    // Quill uses hasFocus, which is also true for an ancestor of the active
    // cell. An explicit request gives the tapped document primary focus.
    if (!focus.hasPrimaryFocus) focus.requestFocus();
    return false;
  }

  bool _focusAfterTable(
    QuillController owner,
    Offset position,
    FocusNode focus,
    EditorState? editor,
  ) {
    if (owner.readOnly || editor == null) return false;
    // A table's surrounding margin is a way back to writing after the block,
    // not a caret as tall as the table at the end of its embed line.
    final offset = editor.renderEditor.getPositionForOffset(position).offset;
    final line = owner.document.queryChild(offset).node;
    if (line is Line &&
        line.childCount == 1 &&
        line.children.first is Embed &&
        isNoteTable((line.children.first as Embed).value.toJson())) {
      final after = line.documentOffset + line.length;
      if (after >= owner.document.length) {
        owner.replaceText(owner.document.length - 1, 0, '\n', null);
      }
      owner.updateSelection(
        TextSelection.collapsed(offset: after),
        ChangeSource.local,
      );
      focus.requestFocus();
      return true;
    }
    return false;
  }

  bool handlesGesture(QuillController owner, Offset position) {
    for (final entry in _regions.entries) {
      if (!identical(entry.value, owner)) continue;
      final box = entry.key.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (Offset.zero & box.size).contains(box.globalToLocal(position))) {
        return true;
      }
    }
    return false;
  }

  QuillController? rootController;
  QuillController? controller;
  FocusNode? focusNode;

  void activate(QuillController controller, FocusNode focusNode) {
    if (identical(this.controller, controller)) return;
    this.controller = controller;
    this.focusNode = focusNode;
    notifyListeners();
  }

  void release(QuillController controller) {
    if (!identical(this.controller, controller)) return;
    this.controller = null;
    focusNode = null;
    // Cells may disappear during a table rebuild or undo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Native rich paste bypasses Quill's insertion rules when its payload is a
/// Delta, so isolate note blocks before the controller applies that payload.
class NoteEditorController extends QuillController {
  NoteEditorController({
    required super.document,
    required super.selection,
    super.readOnly,
    this.allowTables = true,
  });

  final bool allowTables;

  Delta prepareContent(Delta content) =>
      normalizeNoteBlocks(allowTables ? content : flattenNoteTables(content));

  @override
  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    bool shouldNotifyListeners = true,
  }) {
    if (!allowTables && data is Embeddable && isNoteTable(data.toJson())) {
      data = Delta()..insert(data.toJson());
    }
    if (data is Delta && data.toList().any((op) => isNoteBlock(op.data))) {
      final normalized = prepareContent(data);
      final insert = Delta();
      if (isNoteBlock(normalized.first.data) &&
          index > 0 &&
          document.toPlainText()[index - 1] != '\n') {
        insert.insert('\n');
      }
      for (final op in normalized.toList()) {
        insert.push(op);
      }
      data = insert;
    }
    super.replaceText(
      index,
      len,
      data,
      textSelection,
      ignoreFocus: ignoreFocus,
      shouldNotifyListeners: shouldNotifyListeners,
    );
  }
}

int? noteEmbedOffset(
  QuillController controller,
  String type,
  String id, {
  int? offsetHint,
}) {
  var offset = 0;
  int? firstMatch;
  for (final op in controller.document.toDelta().toList()) {
    final data = op.data;
    if (data is Map && data[type] is Map && (data[type] as Map)['id'] == id) {
      if (offset == offsetHint) return offset;
      firstMatch ??= offset;
    }
    offset += op.length!;
  }
  return firstMatch;
}

/// A table boundary is a writing position, even in a document with no text.
void focusBesideNoteTable(
  QuillController owner,
  FocusNode focus,
  String id, {
  required bool before,
  int? offsetHint,
}) {
  if (owner.readOnly || !focus.canRequestFocus) return;
  final offset = noteEmbedOffset(
    owner,
    'note-table',
    id,
    offsetHint: offsetHint,
  );
  if (offset == null) return;
  var position = before ? offset - 1 : offset + 2;
  final neighbor = position >= 0 && position < owner.document.length
      ? owner.document.queryChild(position).node
      : null;
  if (neighbor == null ||
      (neighbor is Line &&
          neighbor.childCount == 1 &&
          neighbor.children.first is Embed)) {
    position = before ? offset : offset + 2;
    owner.replaceText(
      before ? offset : position.clamp(0, owner.document.length - 1),
      0,
      '\n',
      null,
    );
  }
  owner.updateSelection(
    TextSelection.collapsed(offset: position),
    ChangeSource.local,
  );
  focus.requestFocus();
}

void replaceNoteEmbed(
  QuillController controller,
  String type,
  String id,
  Map<String, dynamic>? data, {
  int? offsetHint,
}) {
  if (controller.readOnly) return;
  final offset = noteEmbedOffset(controller, type, id, offsetHint: offsetHint);
  if (offset == null) return;
  final delta = Delta()..retain(offset);
  if (data != null) delta.insert({type: data});
  delta.delete(1);
  final selection = controller.selection;
  // Updating an embed must not reveal the surrounding document's caret. That
  // scroll animation temporarily blocks further cell and divider gestures.
  // Deletion needs Quill's normal rebuild to remove the embed from the screen.
  final ignoreFocus = controller.ignoreFocusOnTextChange;
  controller.ignoreFocusOnTextChange = data != null || ignoreFocus;
  try {
    controller.compose(delta, selection, ChangeSource.local);
    if (data != null) {
      controller.updateSelection(
        TextSelection(
          baseOffset: selection.baseOffset.clamp(
            0,
            controller.document.length - 1,
          ),
          extentOffset: selection.extentOffset.clamp(
            0,
            controller.document.length - 1,
          ),
        ),
        ChangeSource.local,
      );
    }
  } finally {
    controller.ignoreFocusOnTextChange = ignoreFocus;
  }
}

void insertNoteEmbed(
  QuillController controller,
  String type,
  Map<String, dynamic> data, {
  required bool block,
}) {
  if (controller.readOnly) return;
  if (type == 'note-table' &&
      controller is NoteEditorController &&
      !controller.allowTables) {
    return;
  }
  final selection = controller.selection;
  final start = selection.isValid
      ? selection.start.clamp(0, controller.document.length - 1)
      : controller.document.length - 1;
  final length = selection.isValid
      ? (selection.end - start).clamp(0, controller.document.length - 1 - start)
      : 0;
  final plain = controller.document.toPlainText();
  final leading = block && start > 0 && plain[start - 1] != '\n';
  final delta = Delta()..retain(start);
  if (leading) delta.insert('\n');
  delta.insert({type: data});
  if (block) delta.insert('\n');
  delta.delete(length);
  final nextSelection = TextSelection.collapsed(
    offset: start + (leading ? 1 : 0) + 1 + (block ? 1 : 0),
  );
  controller.compose(delta, nextSelection, ChangeSource.local);
  controller.updateSelection(nextSelection, ChangeSource.local);
}

/// Quill deliberately accepts taps won by descendants (selection handles).
/// Embed controls need a boundary so those same taps cannot refocus the parent.
class NoteEmbedGestureRegion extends StatefulWidget {
  const NoteEmbedGestureRegion({
    super.key,
    required this.editing,
    required this.owner,
    required this.child,
  });
  final NoteEmbedEditing editing;
  final QuillController owner;
  final Widget child;
  @override
  State<NoteEmbedGestureRegion> createState() => _NoteEmbedGestureRegionState();
}

class _NoteEmbedGestureRegionState extends State<NoteEmbedGestureRegion> {
  final _key = GlobalKey();
  @override
  void initState() {
    super.initState();
    widget.editing._regions[_key] = widget.owner;
  }

  @override
  void didUpdateWidget(NoteEmbedGestureRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget.editing._regions.remove(_key);
    widget.editing._regions[_key] = widget.owner;
  }

  @override
  void dispose() {
    widget.editing._regions.remove(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(key: _key, child: widget.child);
}
