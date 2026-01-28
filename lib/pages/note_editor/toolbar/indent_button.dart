import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';

class IndentButton extends StatefulWidget {
  final bool readOnly;
  final FocusNode focusNode;
  final Color? parentColor;
  final QuillController controller;

  const IndentButton({
    super.key,
    this.parentColor,
    required this.readOnly,
    required this.focusNode,
    required this.controller,
  });

  @override
  State<IndentButton> createState() => _IndentButtonState();
}

class _IndentButtonState extends State<IndentButton> {
  final AdaptivePopupController _controller = AdaptivePopupController();

  @override
  void initState() {
    _controller.isDisabled = widget.readOnly;
    super.initState();
  }

  @override
  void didUpdateWidget(IndentButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.isDisabled = widget.readOnly;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _indent() {
    widget.controller.indentSelection(true);
    _controller.close();
    widget.focusNode.requestFocus();
  }

  void _outdent() {
    widget.controller.indentSelection(false);
    _controller.close();
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: _controller,
      parentColor: widget.parentColor,
      fitContent: true,
      items: (context) => [
        AdaptiveMenuItem(
          icon: Icons.format_indent_increase,
          label: 'Indent',
          onTap: _indent,
        ),
        AdaptiveMenuItem(
          icon: Icons.format_indent_decrease,
          label: 'Outdent',
          onTap: _outdent,
        ),
      ],
      child: IconButton(
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: _buildIconWithIndicator(const Icon(Icons.format_indent_increase)),
        tooltip: 'Indent',
      ),
    );
  }

  Widget _buildIconWithIndicator(Widget icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const Icon(Icons.arrow_drop_down, size: 16)],
    );
  }
}
