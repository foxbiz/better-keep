import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class CheckListButton extends StatefulWidget {
  final QuillController controller;
  final FocusNode focusNode;
  final bool isEditingTitle;
  final bool readOnly;

  const CheckListButton({
    super.key,
    required this.readOnly,
    required this.controller,
    required this.focusNode,
    required this.isEditingTitle,
  });

  @override
  State<CheckListButton> createState() => _CheckListButtonState();
}

class _CheckListButtonState extends State<CheckListButton> {
  bool enabled = false;
  Style get _selectionStyle => widget.controller.getSelectionStyle();

  void _didChangeSelection() {
    setState(() {
      enabled = _getIsToggled(_selectionStyle.attributes);
    });
  }

  bool _getIsToggled(Map<String, Attribute> attrs) {
    var attribute = widget.controller.toolbarButtonToggler[Attribute.list.key];

    if (attribute == null) {
      attribute = attrs[Attribute.list.key];
    } else {
      // checkbox tapping causes controller.selection to go to offset 0
      widget.controller.toolbarButtonToggler.remove(Attribute.list.key);
    }

    if (attribute == null) {
      return false;
    }
    return attribute.value == Attribute.unchecked.value ||
        attribute.value == Attribute.checked.value;
  }

  @override
  void initState() {
    enabled = _getIsToggled(_selectionStyle.attributes);
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
      isSelected: enabled && !widget.readOnly,
      icon: Icon(Icons.check_box_outlined),
      onPressed: widget.isEditingTitle || widget.readOnly
          ? null
          : () async {
              enabled = _getIsToggled(_selectionStyle.attributes);
              widget.controller
                ..skipRequestKeyboard = !Attribute.list.isInline
                ..formatSelection(
                  enabled
                      ? Attribute.clone(Attribute.unchecked, null)
                      : Attribute.unchecked,
                );

              widget.focusNode.requestFocus();
              setState(() {});
            },
    );
  }
}
