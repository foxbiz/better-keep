import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/utils/l10n_helper.dart';

/// Line spacing options with their corresponding line-height values
enum LineSpacingOption {
  tight(1.0),
  normal(1.15),
  relaxed(1.5),
  doubleSpacing(2.0);

  final double lineHeightValue;

  const LineSpacingOption(this.lineHeightValue);

  String getLabel(BuildContext context) {
    return switch (this) {
      LineSpacingOption.tight => context.l10n.lineSpacingTight,
      LineSpacingOption.normal => context.l10n.lineSpacingNormal,
      LineSpacingOption.relaxed => context.l10n.lineSpacingRelaxed,
      LineSpacingOption.doubleSpacing => context.l10n.lineSpacingDouble,
    };
  }

  Attribute get attribute => LineHeightAttribute(lineHeight: lineHeightValue);
}

class LineSpacingButton extends StatefulWidget {
  final bool readOnly;
  final FocusNode focusNode;
  final Color? parentColor;
  final QuillController controller;

  const LineSpacingButton({
    super.key,
    this.parentColor,
    required this.readOnly,
    required this.focusNode,
    required this.controller,
  });

  @override
  State<LineSpacingButton> createState() => _LineSpacingButtonState();
}

class _LineSpacingButtonState extends State<LineSpacingButton> {
  final AdaptivePopupController _controller = AdaptivePopupController();
  LineSpacingOption? _currentSpacing;

  @override
  void initState() {
    _controller.isDisabled = widget.readOnly;
    widget.controller.addListener(_onSelectionChanged);
    _updateCurrentSpacing();
    super.initState();
  }

  @override
  void didUpdateWidget(LineSpacingButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.isDisabled = widget.readOnly;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    _controller.close();
    _updateCurrentSpacing();
  }

  void _updateCurrentSpacing() {
    final attrs = widget.controller.getSelectionStyle().attributes;
    final lineHeightAttr = attrs['line-height'];

    if (lineHeightAttr == null || lineHeightAttr.value == null) {
      _currentSpacing = null; // Default spacing
    } else {
      final lineHeightValue = _parseLineHeightValue(lineHeightAttr.value);
      _currentSpacing = LineSpacingOption.values
          .cast<LineSpacingOption?>()
          .firstWhere(
            (option) => option?.lineHeightValue == lineHeightValue,
            orElse: () => null,
          );
    }
    if (mounted) setState(() {});
  }

  double? _parseLineHeightValue(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  void _applySpacing(LineSpacingOption? option) {
    widget.controller.skipRequestKeyboard = true;
    try {
      if (option == null) {
        // Remove the line-height attribute by setting value to null
        widget.controller.formatSelection(const LineHeightAttribute());
      } else {
        widget.controller.formatSelection(option.attribute);
      }
    } finally {
      widget.controller.skipRequestKeyboard = false;
    }
    _updateCurrentSpacing();
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
      items: (context) => [
        ...LineSpacingOption.values.map(
          (option) => AdaptiveMenuItem(
            icon: Icons.format_line_spacing,
            label: option.getLabel(context),
            isSelected: _currentSpacing == option,
            onTap: () => _applySpacing(option),
          ),
        ),
        // Add divider-like spacing via a remove option
        AdaptiveMenuItem(
          icon: Icons.format_clear,
          label: context.l10n.lineSpacingRemove,
          isSelected: false,
          onTap: () => _applySpacing(null),
        ),
      ],
      child: IconButton(
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: _buildIconWithIndicator(context),
        tooltip: context.l10n.lineSpacing,
      ),
    );
  }

  Widget _buildIconWithIndicator(BuildContext context) {
    // Show current spacing indicator if not default
    final spacingLabel = _currentSpacing?.getLabel(context).characters.first;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spacingLabel != null)
          SizedBox(
            width: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Icon(Icons.format_line_spacing),
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
                      spacingLabel,
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
          const Icon(Icons.format_line_spacing),
        const Icon(Icons.arrow_drop_down, size: 16),
      ],
    );
  }
}
