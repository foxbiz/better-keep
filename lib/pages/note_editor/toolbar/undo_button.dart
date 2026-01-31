import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/utils/l10n_helper.dart';

class UndoButton extends StatefulWidget {
  final QuillController controller;
  final bool readOnly;
  final FocusNode focusNode;

  const UndoButton({
    super.key,
    required this.readOnly,
    required this.controller,
    required this.focusNode,
  });

  @override
  State<UndoButton> createState() => _UndoButtonState();
}

class _UndoButtonState extends State<UndoButton> {
  bool canUndo = false;

  void _didChangeSelection() {
    setState(() {
      canUndo = widget.controller.hasUndo;
    });
  }

  @override
  void initState() {
    widget.controller.addListener(_didChangeSelection);
    super.initState();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_didChangeSelection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.undo),
      tooltip: context.l10n.undo,
      onPressed: canUndo && !widget.readOnly ? widget.controller.undo : null,
    );
  }
}
