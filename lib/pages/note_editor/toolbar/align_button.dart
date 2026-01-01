import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';

class AlignButton extends StatefulWidget {
  final bool readOnly;
  final bool isEditingTitle;
  final FocusNode focusNode;
  final Color? parentColor;
  final QuillController controller;

  const AlignButton({
    super.key,
    this.parentColor,
    required this.readOnly,
    required this.focusNode,
    required this.controller,
    required this.isEditingTitle,
  });

  @override
  State<AlignButton> createState() => _AlignButtonState();
}

class _AlignButtonState extends State<AlignButton> {
  final AdaptivePopupController _controller = AdaptivePopupController();

  Attribute? _currentAlignment;

  @override
  void initState() {
    _controller.isDisabled = widget.readOnly || widget.isEditingTitle;
    widget.controller.addListener(_onSelectionChanged);
    _updateCurrentAlignment();
    super.initState();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    _controller.close();
    _updateCurrentAlignment();
  }

  void _updateCurrentAlignment() {
    final attrs = widget.controller.getSelectionStyle().attributes;
    if (attrs.containsKey(Attribute.align.key)) {
      final alignValue = attrs[Attribute.align.key]?.value;
      if (alignValue == 'center') {
        _currentAlignment = Attribute.centerAlignment;
      } else if (alignValue == 'right') {
        _currentAlignment = Attribute.rightAlignment;
      } else {
        _currentAlignment = Attribute.leftAlignment;
      }
    } else {
      _currentAlignment = null;
    }
    if (mounted) setState(() {});
  }

  IconData _getAlignIcon() {
    if (_currentAlignment == Attribute.centerAlignment) {
      return Icons.format_align_center;
    } else if (_currentAlignment == Attribute.rightAlignment) {
      return Icons.format_align_right;
    }
    return Icons.format_align_left;
  }

  void _applyAlignment(Attribute attribute) {
    widget.controller.skipRequestKeyboard = true;
    try {
      final isCurrentlySelected = _currentAlignment == attribute;
      widget.controller.formatSelection(
        isCurrentlySelected ? Attribute.clone(attribute, null) : attribute,
      );
    } finally {
      widget.controller.skipRequestKeyboard = false;
    }
    _updateCurrentAlignment();
    _controller.close();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: _controller,
      parentColor: widget.parentColor,
      items: (context) => [
        AdaptiveMenuItem(
          icon: Icons.format_align_left,
          label: 'Left',
          isSelected: _currentAlignment == Attribute.leftAlignment,
          onTap: () => _applyAlignment(Attribute.leftAlignment),
        ),
        AdaptiveMenuItem(
          icon: Icons.format_align_center,
          label: 'Center',
          isSelected: _currentAlignment == Attribute.centerAlignment,
          onTap: () => _applyAlignment(Attribute.centerAlignment),
        ),
        AdaptiveMenuItem(
          icon: Icons.format_align_right,
          label: 'Right',
          isSelected: _currentAlignment == Attribute.rightAlignment,
          onTap: () => _applyAlignment(Attribute.rightAlignment),
        ),
      ],
      child: IconButton(
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: Icon(_getAlignIcon()),
        tooltip: 'Align',
      ),
    );
  }
}
