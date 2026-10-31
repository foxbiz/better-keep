import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Quill 11 does not expose a text-field semantics node. Flutter web needs one
/// to attach its DOM input when accessibility is enabled.
extension QuillInputSemantics on QuillEditor {
  Widget withWebInputSemantics() => kIsWeb ? _WebQuillEditor(this) : this;
}

class _WebQuillEditor extends QuillEditor {
  _WebQuillEditor(QuillEditor editor)
    : super(
        key: editor.key,
        controller: editor.controller,
        focusNode: editor.focusNode,
        scrollController: editor.scrollController,
        config: editor.config,
      );

  @override
  QuillEditorState createState() => _WebQuillEditorState();
}

class _WebQuillEditorState extends QuillEditorState {
  @override
  Widget build(BuildContext context) {
    var editor = super.build(context);
    if (editor is KeyboardListener) {
      // Quill's web keyboard guard has a separate focus node. Exposing that
      // node steals DOM focus from the actual editor and disconnects input.
      editor = KeyboardListener(
        key: editor.key,
        focusNode: editor.focusNode,
        autofocus: editor.autofocus,
        onKeyEvent: editor.onKeyEvent,
        includeSemantics: false,
        child: editor.child,
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, widget.focusNode]),
      child: editor,
      builder: (context, child) => Semantics(
        container: true,
        textField: true,
        multiline: true,
        enabled: true,
        readOnly: widget.controller.readOnly,
        value: widget.controller.document.toPlainText(),
        // Let Quill's real Focus contribute focus actions/state to this node.
        // Keep embed semantics and route edits through Quill's TextInputClient.
        child: child,
      ),
    );
  }
}
