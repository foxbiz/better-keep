import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';

/// Text size options with their corresponding font sizes
enum TextSizeOption {
  tiny(12, 'Tiny'),
  small(14, 'Small'),
  normal(16, 'Normal'),
  big(20, 'Big'),
  huge(24, 'Huge');

  final double fontSize;
  final String label;

  const TextSizeOption(this.fontSize, this.label);
}

class TextSizeButton extends StatefulWidget {
  final bool readOnly;
  final bool isEditingTitle;
  final FocusNode focusNode;
  final Color? parentColor;
  final QuillController controller;

  const TextSizeButton({
    super.key,
    this.parentColor,
    required this.readOnly,
    required this.focusNode,
    required this.controller,
    required this.isEditingTitle,
  });

  @override
  State<TextSizeButton> createState() => _TextSizeButtonState();
}

class _TextSizeButtonState extends State<TextSizeButton> {
  final AdaptivePopupController _controller = AdaptivePopupController();
  TextSizeOption? _currentSize;

  @override
  void initState() {
    _controller.isDisabled = widget.readOnly || widget.isEditingTitle;
    widget.controller.addListener(_onSelectionChanged);
    _updateCurrentSize();
    super.initState();
  }

  @override
  void didUpdateWidget(TextSizeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.isDisabled = widget.readOnly || widget.isEditingTitle;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    _controller.close();
    _updateCurrentSize();
  }

  void _updateCurrentSize() {
    final attrs = widget.controller.getSelectionStyle().attributes;
    final sizeAttr = attrs[Attribute.size.key];

    if (sizeAttr == null || sizeAttr.value == null) {
      _currentSize = null; // Default/normal size
    } else {
      final sizeValue = _parseSizeValue(sizeAttr.value);
      _currentSize = TextSizeOption.values.cast<TextSizeOption?>().firstWhere(
        (option) => option?.fontSize == sizeValue,
        orElse: () => null,
      );
    }
    if (mounted) setState(() {});
  }

  double? _parseSizeValue(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      // Handle values like "12" or "12px"
      final numStr = value.replaceAll(RegExp(r'[^0-9.]'), '');
      return double.tryParse(numStr);
    }
    return null;
  }

  void _applySize(TextSizeOption option) {
    widget.controller.skipRequestKeyboard = true;
    try {
      if (option == TextSizeOption.normal) {
        // Clear the size attribute to use default
        widget.controller.formatSelection(
          Attribute.clone(Attribute.size, null),
        );
      } else {
        // Quill expects size as a string value
        widget.controller.formatSelection(
          Attribute.fromKeyValue('size', '${option.fontSize.toInt()}'),
        );
      }
    } finally {
      widget.controller.skipRequestKeyboard = false;
    }
    _updateCurrentSize();
    _controller.close();
    // Re-focus the editor after applying the format
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: _controller,
      parentColor: widget.parentColor,
      fitContent: true,
      items: (context) => TextSizeOption.values
          .map(
            (option) => AdaptiveMenuItem(
              icon: Icons.format_size,
              label: option.label,
              isSelected:
                  _currentSize == option ||
                  (option == TextSizeOption.normal && _currentSize == null),
              onTap: () => _applySize(option),
            ),
          )
          .toList(),
      child: IconButton(
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: _buildIconWithIndicator(),
        tooltip: 'Text Size',
      ),
    );
  }

  Widget _buildIconWithIndicator() {
    // Show current size abbreviation if not normal
    final sizeLabel =
        _currentSize != null && _currentSize != TextSizeOption.normal
        ? _currentSize!.label[0] // First letter: T, S, B, H
        : null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sizeLabel != null)
          SizedBox(
            width: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.format_size),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      sizeLabel,
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          const Icon(Icons.format_size),
        const Icon(Icons.arrow_drop_down, size: 16),
      ],
    );
  }
}
