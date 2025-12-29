import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

/// Tool types for the sketch page
enum SketchToolType { pen, eraser }

/// A popup menu for sketch tool options (pen/eraser settings)
class SketchToolPopup extends StatefulWidget {
  final SketchToolType toolType;
  final Color selectedColor;
  final double penSize;
  final double eraserSize;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onPenSizeChanged;
  final ValueChanged<double> onEraserSizeChanged;
  final Widget child;

  const SketchToolPopup({
    super.key,
    required this.toolType,
    required this.selectedColor,
    required this.penSize,
    required this.eraserSize,
    required this.onColorChanged,
    required this.onPenSizeChanged,
    required this.onEraserSizeChanged,
    required this.child,
  });

  @override
  State<SketchToolPopup> createState() => _SketchToolPopupState();
}

class _SketchToolPopupState extends State<SketchToolPopup> {
  final AdaptivePopupController _controller = AdaptivePopupController();
  double _currentSize = 0;
  OverlayEntry? _sizePreviewEntry;
  final ValueNotifier<double> _sizeNotifier = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _updateCurrentSize();
  }

  @override
  void didUpdateWidget(SketchToolPopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateCurrentSize();
  }

  void _updateCurrentSize() {
    _currentSize = widget.toolType == SketchToolType.eraser
        ? widget.eraserSize
        : widget.penSize;
    _sizeNotifier.value = _currentSize;
  }

  @override
  void deactivate() {
    // Close overlay immediately when widget is removed from tree
    _sizePreviewEntry?.remove();
    _sizePreviewEntry = null;
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    _sizePreviewEntry?.remove();
    _sizeNotifier.dispose();
    super.dispose();
  }

  void _showSizePreview(BuildContext context) {
    _sizePreviewEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Container(color: Colors.black54),
          Center(
            child: ValueListenableBuilder<double>(
              valueListenable: _sizeNotifier,
              builder: (context, value, child) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 50),
                  width: value,
                  height: value,
                  decoration: BoxDecoration(
                    color: widget.toolType == SketchToolType.eraser
                        ? Colors.white
                        : widget.selectedColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_sizePreviewEntry!);
  }

  void _hideSizePreview() {
    _sizePreviewEntry?.remove();
    _sizePreviewEntry = null;
  }

  void _pickCustomColor(BuildContext context) async {
    _controller.close();
    final color = await colorPicker(
      context,
      "Select Pen Color",
      widget.selectedColor,
    );
    if (color != null) {
      widget.onColorChanged(color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;

    // On mobile: use full width minus padding
    // On larger screens: let it fit to content (pass null)
    final double? popupWidth = isMobile ? screenSize.width - 32 : null;

    return AdaptivePopupMenu(
      controller: _controller,
      width: popupWidth,
      builder: (context, close) => _buildPopupContent(context, close),
      child: GestureDetector(onTap: _controller.toggle, child: widget.child),
    );
  }

  Widget _buildPopupContent(BuildContext context, VoidCallback close) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Size slider section - always show first
        Padding(
          padding: const EdgeInsets.only(bottom: 4, left: 4),
          child: Text(
            'Size',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        _buildSizeSlider(context),
        // Color palette for pen tool - show after size
        if (widget.toolType == SketchToolType.pen) ...[
          const SizedBox(height: 12),
          Divider(
            height: 1,
            color: colorScheme.onSurface.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4),
            child: Text(
              'Color',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          _buildColorPalette(context, close),
        ],
      ],
    );
  }

  Widget _buildColorPalette(BuildContext context, VoidCallback close) {
    // Scrollable horizontal color palette
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // Custom color picker first
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildCustomColorPicker(context),
          ),
          // Then recent colors
          ...AppState.recentColors.map(
            (color) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildColorItem(color, close),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorItem(Color color, VoidCallback close) {
    final isSelected = widget.selectedColor == color;

    return GestureDetector(
      onTap: () {
        widget.onColorChanged(color);
        close();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected
                ? Colors.white
                : Colors.grey.withValues(alpha: 0.3),
            width: isSelected ? 2.5 : 1,
          ),
        ),
        child: isSelected
            ? Icon(
                Icons.check,
                color: isDark(color) ? Colors.white : Colors.black,
                size: 18,
              )
            : null,
      ),
    );
  }

  Widget _buildCustomColorPicker(BuildContext context) {
    return GestureDetector(
      onTap: () => _pickCustomColor(context),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [
              Colors.red,
              Colors.orange,
              Colors.yellow,
              Colors.green,
              Colors.blue,
              Colors.purple,
              Colors.red,
            ],
          ),
          border: Border.all(
            color: Colors.grey.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Center(
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.add, size: 14, color: Colors.black87),
          ),
        ),
      ),
    );
  }

  Widget _buildSizeSlider(BuildContext context) {
    final theme = Theme.of(context);
    final isEraser = widget.toolType == SketchToolType.eraser;
    final minSize = isEraser ? 10.0 : 1.0;
    final maxSize = isEraser ? 100.0 : 50.0;

    return StatefulBuilder(
      builder: (context, setLocalState) {
        return Row(
          children: [
            Icon(
              isEraser ? CustomIcons.eraser : CustomIcons.pen,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                  activeTrackColor: theme.colorScheme.primary,
                  inactiveTrackColor: theme.colorScheme.primary.withValues(
                    alpha: 0.3,
                  ),
                  thumbColor: theme.colorScheme.primary,
                ),
                child: Slider(
                  value: _currentSize,
                  min: minSize,
                  max: maxSize,
                  onChangeStart: (value) {
                    _showSizePreview(context);
                  },
                  onChanged: (value) {
                    setLocalState(() {
                      _currentSize = value;
                    });
                    _sizeNotifier.value = value;
                    if (isEraser) {
                      widget.onEraserSizeChanged(value);
                    } else {
                      widget.onPenSizeChanged(value);
                    }
                  },
                  onChangeEnd: (_) {
                    _hideSizePreview();
                  },
                ),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                _currentSize.toInt().toString(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
