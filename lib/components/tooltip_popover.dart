import 'package:flutter/material.dart';

class PopoverController extends ChangeNotifier {
  bool _isDisabled = false;
  bool _isPopoverVisible = false;

  bool get isPopoverVisible => _isPopoverVisible;
  bool get isDisabled => _isDisabled;
  set isDisabled(bool value) {
    _isDisabled = value;
    if (_isDisabled && _isPopoverVisible) {
      _isPopoverVisible = false;
    }
    notifyListeners();
  }

  void showPopover() {
    _isPopoverVisible = true;
    notifyListeners();
  }

  void hidePopover() {
    _isPopoverVisible = false;
    notifyListeners();
  }

  void toggle() {
    if (_isDisabled) return;
    _isPopoverVisible = !_isPopoverVisible;
    notifyListeners();
  }
}

class TooltipPopover extends StatefulWidget {
  final Widget child;
  final Color? parentColor;
  final PopoverController? controller;
  final List<Widget> Function(BuildContext) popover;

  const TooltipPopover({
    super.key,
    this.controller,
    this.parentColor,
    required this.child,
    required this.popover,
  });

  @override
  State<TooltipPopover> createState() => _TooltipPopoverState();
}

class _TooltipPopoverState extends State<TooltipPopover> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late final PopoverController _controller;

  @override
  void initState() {
    _controller = widget.controller ?? PopoverController();
    _controller.addListener(_notifierListener);
    super.initState();
  }

  @override
  void deactivate() {
    // Close overlay immediately when widget is removed from tree
    // This handles cases like auth state changes during navigation
    if (_overlayEntry != null) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.removeListener(_notifierListener);
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_controller.isPopoverVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controller.isPopoverVisible) {
          _controller.hidePopover();
        }
      },
      child: _buildView(),
    );
  }

  void _notifierListener() {
    if (_controller.isPopoverVisible) {
      final renderBox = context.findRenderObject() as RenderBox;
      final offset = renderBox.localToGlobal(Offset.zero);
      final screenWidth = MediaQuery.of(context).size.width;

      // Estimated width of the popup (3 icons * 48 + padding)
      const double popupWidth = 150.0;
      const double padding = 8.0;

      // Calculate horizontal offset to keep popup on screen
      double dx = -50; // Default centered offset

      // Check left bound
      if (offset.dx + dx < padding) {
        dx = padding - offset.dx;
      }

      // Check right bound
      if (offset.dx + dx + popupWidth > screenWidth - padding) {
        dx = screenWidth - padding - popupWidth - offset.dx;
      }

      setState(() {});

      _overlayEntry = OverlayEntry(
        builder: (context) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _controller.hidePopover,
                behavior: HitTestBehavior.translucent,
                child: Container(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              offset: Offset(
                dx,
                -60,
              ), // Position above with calculated horizontal offset
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color:
                    widget.parentColor ?? Theme.of(context).colorScheme.surface,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.popover(context),
                ),
              ),
            ),
          ],
        ),
      );

      Overlay.of(context).insert(_overlayEntry!);
      return;
    }

    if (!_controller.isPopoverVisible) {
      setState(() {});
      _overlayEntry?.remove();
      _overlayEntry = null;
    }
  }

  Widget _buildView() {
    return CompositedTransformTarget(link: _layerLink, child: widget.child);
  }
}
