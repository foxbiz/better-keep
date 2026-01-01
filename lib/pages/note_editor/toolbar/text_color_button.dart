import 'package:better_keep/dialogs/color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class TextColorButton extends StatefulWidget {
  final QuillController controller;
  final FocusNode focusNode;
  final Color color;
  final bool readOnly;
  final bool isEditingTitle;

  const TextColorButton({
    super.key,
    required this.color,
    required this.readOnly,
    required this.focusNode,
    required this.controller,
    this.isEditingTitle = false,
  });

  @override
  State<TextColorButton> createState() => _TextColorButtonState();
}

class _TextColorButtonState extends State<TextColorButton> {
  bool enabled = false;

  void _didChangeSelection() {
    final toggled = _getIsToggled();

    if (toggled == enabled || !mounted) {
      enabled = toggled;
      return;
    }

    setState(() {
      enabled = toggled;
    });
  }

  bool _getIsToggled() {
    final attrs = widget.controller.getSelectionStyle().attributes;
    return attrs.containsKey(Attribute.color.key);
  }

  @override
  void initState() {
    enabled = _getIsToggled();
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
    final isDisabled = widget.readOnly || widget.isEditingTitle;
    return IconButton(
      isSelected: enabled,
      icon: Icon(Icons.text_format),
      onPressed: isDisabled
          ? null
          : () async {
              final shouldSkipKeyboard = !Attribute.color.isInline;
              widget.controller.skipRequestKeyboard = shouldSkipKeyboard;
              try {
                final Attribute attribute;

                if (!enabled) {
                  widget.focusNode.unfocus();
                  final color = await colorPicker(
                    context,
                    "Pick Text Color",
                    widget.color,
                  );
                  widget.focusNode.requestFocus();
                  if (color == null) return;
                  String hex =
                      '#${color.toARGB32().toRadixString(16).substring(2)}';
                  attribute = ColorAttribute(hex);
                } else {
                  attribute = Attribute.clone(Attribute.color, null);
                }

                widget.controller.formatSelection(attribute);
              } finally {
                widget.controller.skipRequestKeyboard = false;
              }

              if (context.mounted) {
                setState(() {});
              }
            },
    );
  }
}
