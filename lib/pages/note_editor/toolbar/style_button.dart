import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

const iconMap = {
  "bold": Icons.format_bold,
  "italic": Icons.format_italic,
  "underline": Icons.format_underlined,
  "strike": Icons.format_strikethrough,
  "code": Icons.code,
  "blockquote": Icons.format_quote,
  "ol": Icons.format_list_numbered,
  "ul": Icons.format_list_bulleted,
  "align_left": Icons.format_align_left,
  "align_center": Icons.format_align_center,
  "align_right": Icons.format_align_right,
};

class StyleButton extends StatefulWidget {
  final QuillController controller;
  final Attribute attribute;
  final bool isEditingTitle;
  final bool readOnly;

  const StyleButton({
    super.key,
    required this.readOnly,
    required this.controller,
    required this.attribute,
    required this.isEditingTitle,
  });

  @override
  State<StyleButton> createState() => _StyleButtonState();
}

class _StyleButtonState extends State<StyleButton> {
  bool enabled = false;

  void _didChangeSelection() {
    setState(() {
      enabled = _getIsToggled();
    });
  }

  bool _getIsToggled() {
    final key = widget.attribute.key;
    final value = widget.attribute.value;
    final attrs = widget.controller.getSelectionStyle().attributes;

    if (Attribute.list.key == key) {
      final listAttr = attrs[Attribute.list.key];

      if (listAttr == null) {
        return false;
      }

      if (listAttr.value == value) {
        return true;
      } else {
        return false;
      }
    }

    return attrs.containsKey(widget.attribute.key);
  }

  IconData _getIcon() {
    final key = widget.attribute.key;
    final value = widget.attribute.value;
    if (Attribute.list.key == key) {
      if (value == 'bullet') {
        return Icons.format_list_bulleted;
      } else {
        return Icons.format_list_numbered;
      }
    } else if (Attribute.align.key == key) {
      return switch (value) {
        'center' => Icons.format_align_center,
        'right' => Icons.format_align_right,
        'left' => Icons.format_align_left,
        _ => Icons.help,
      };
    } else {
      return iconMap[widget.attribute.key] ?? Icons.help;
    }
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
    return IconButton(
      isSelected: enabled,
      icon: Icon(_getIcon()),
      onPressed: widget.isEditingTitle || widget.readOnly
          ? null
          : () async {
              final shouldSkipKeyboard = !widget.attribute.isInline;

              widget.controller.skipRequestKeyboard = shouldSkipKeyboard;
              try {
                widget.controller.formatSelection(
                  enabled
                      ? Attribute.clone(widget.attribute, null)
                      : widget.attribute,
                );
              } finally {
                widget.controller.skipRequestKeyboard = false;
              }

              setState(() {});
            },
    );
  }
}
