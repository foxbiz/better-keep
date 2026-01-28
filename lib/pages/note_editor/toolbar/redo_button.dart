import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class RedoButton extends StatefulWidget {
  final QuillController controller;
  final bool readOnly;
  final FocusNode focusNode;

  const RedoButton({
    super.key,
    required this.readOnly,
    required this.controller,
    required this.focusNode,
  });

  @override
  State<RedoButton> createState() => _RedoButtonState();
}

class _RedoButtonState extends State<RedoButton> {
  bool canRedo = false;
  bool hasSelection = false;

  void _didChangeSelection() {
    setState(() {
      canRedo = widget.controller.hasRedo;
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
      icon: const Icon(Icons.redo),
      onPressed: canRedo && !widget.readOnly ? widget.controller.redo : null,
    );
  }
}
