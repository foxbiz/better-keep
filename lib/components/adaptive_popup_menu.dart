import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

/// Controller for managing the popup menu state
class AdaptivePopupController extends ChangeNotifier {
  bool _isOpen = false;
  bool _isDisabled = false;
  bool _isHovered = false;

  bool get isOpen => _isOpen;
  bool get isDisabled => _isDisabled;
  bool get isHovered => _isHovered;

  set isDisabled(bool value) {
    _isDisabled = value;
    if (_isDisabled && _isOpen) {
      _isOpen = false;
    }
    notifyListeners();
  }

  void open() {
    if (!_isDisabled) {
      _isOpen = true;
      notifyListeners();
    }
  }

  void close() {
    _isOpen = false;
    notifyListeners();
  }

  void toggle() {
    if (_isDisabled) return;
    _isOpen = !_isOpen;
    notifyListeners();
  }

  void setHovered(bool value) {
    _isHovered = value;
    notifyListeners();
  }
}

/// Configuration for popup menu items
class AdaptiveMenuItem {
  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final bool isSelected;
  final Color? iconColor;
  final Widget? customWidget;

  const AdaptiveMenuItem({
    required this.icon,
    this.label,
    this.onTap,
    this.isSelected = false,
    this.iconColor,
    this.customWidget,
  });
}

/// A section in the popup menu
class AdaptiveMenuSection {
  final String? title;
  final List<AdaptiveMenuItem> items;
  final bool isGrid;
  final int gridCrossAxisCount;
  final Widget? customContent;

  const AdaptiveMenuSection({
    this.title,
    this.items = const [],
    this.isGrid = false,
    this.gridCrossAxisCount = 4,
    this.customContent,
  });
}

/// The direction from which the popup should appear
enum PopupDirection { above, below }

/// A beautiful, consistent popup menu component with animations
/// that adapts to different screen sizes and platforms
class AdaptivePopupMenu extends StatefulWidget {
  /// The child widget (usually an IconButton) that triggers the popup
  final Widget child;

  /// Controller to manage popup state externally
  final AdaptivePopupController? controller;

  /// Builder for popup content
  final List<AdaptiveMenuSection> Function(BuildContext context)? sections;

  /// Simple list of items (used when sections is null)
  final List<AdaptiveMenuItem> Function(BuildContext context)? items;

  /// Custom popup content builder
  final Widget Function(BuildContext context, VoidCallback close)? builder;

  /// The parent/background color to adapt the popup colors
  final Color? parentColor;

  /// Direction to show the popup
  final PopupDirection direction;

  /// Whether to show the popup on hover (desktop only)
  final bool showOnHover;

  /// Hover delay in milliseconds
  final int hoverDelay;

  /// Custom width for the popup
  final double? width;

  /// Whether to show labels with icons
  final bool showLabels;

  /// Animation duration
  final Duration animationDuration;

  const AdaptivePopupMenu({
    super.key,
    required this.child,
    this.controller,
    this.sections,
    this.items,
    this.builder,
    this.parentColor,
    this.direction = PopupDirection.above,
    this.showOnHover = true,
    this.hoverDelay = 200,
    this.width,
    this.showLabels = false,
    this.animationDuration = const Duration(milliseconds: 200),
  });

  @override
  State<AdaptivePopupMenu> createState() => _AdaptivePopupMenuState();
}

class _AdaptivePopupMenuState extends State<AdaptivePopupMenu>
    with SingleTickerProviderStateMixin {
  late AdaptivePopupController _controller;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  bool _isHovering = false;
  bool _isOverlayHovering = false;

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AdaptivePopupController();
    _controller.addListener(_onControllerChanged);

    _animationController = AnimationController(
      duration: widget.animationDuration,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );

    final slideBegin = widget.direction == PopupDirection.above
        ? const Offset(0, 0.1)
        : const Offset(0, -0.1);
    _slideAnimation = Tween<Offset>(begin: slideBegin, end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );
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
    _controller.removeListener(_onControllerChanged);
    _closeOverlay(animate: false);
    _animationController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_controller.isOpen) {
      _showOverlay();
    } else {
      _closeOverlay();
    }
  }

  void _showOverlay() {
    if (_overlayEntry != null) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final screenSize = MediaQuery.of(context).size;
    final buttonOffset = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;

    final isMobile = screenSize.width < 600;

    // Gap between button and popup
    const gap = 8.0;
    const screenPadding = 16.0;

    _overlayEntry = OverlayEntry(
      builder: (context) {
        // For mobile: use Positioned to ensure popup stays on screen
        if (isMobile) {
          final popupWidth = screenSize.width - (screenPadding * 2);

          // Calculate vertical position
          double top;
          if (widget.direction == PopupDirection.above) {
            // Position above the button - we need to measure content, so use bottom positioning
            top = 0; // Will be overridden by bottom
          } else {
            top = buttonOffset.dy + buttonSize.height + gap;
          }

          return Stack(
            children: [
              // Backdrop to close on tap outside
              Positioned.fill(
                child: GestureDetector(
                  onTap: _controller.close,
                  behavior: HitTestBehavior.translucent,
                  child: Container(color: Colors.transparent),
                ),
              ),
              // The popup - centered horizontally on mobile
              Positioned(
                left: screenPadding,
                right: screenPadding,
                bottom: widget.direction == PopupDirection.above
                    ? screenSize.height - buttonOffset.dy + gap
                    : null,
                top: widget.direction == PopupDirection.above ? null : top,
                child: MouseRegion(
                  onEnter: (_) => _onOverlayHover(true),
                  onExit: (_) => _onOverlayHover(false),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: ScaleTransition(
                      scale: _scaleAnimation,
                      alignment: widget.direction == PopupDirection.above
                          ? Alignment.bottomCenter
                          : Alignment.topCenter,
                      child: SlideTransition(
                        position: _slideAnimation,
                        child: _buildPopupContent(popupWidth, screenSize),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        // For larger screens: use CompositedTransformFollower
        final popupWidth = widget.width ?? _calculatePopupWidth(screenSize);

        // Calculate horizontal offset to keep popup on screen
        double horizontalOffset = 0;
        final buttonCenterX = buttonOffset.dx + buttonSize.width / 2;
        final popupLeft = buttonCenterX - popupWidth / 2;
        final popupRight = buttonCenterX + popupWidth / 2;

        if (popupLeft < screenPadding) {
          horizontalOffset = screenPadding - popupLeft;
        } else if (popupRight > screenSize.width - screenPadding) {
          horizontalOffset = (screenSize.width - screenPadding) - popupRight;
        }

        return Stack(
          children: [
            // Backdrop to close on tap outside
            Positioned.fill(
              child: GestureDetector(
                onTap: _controller.close,
                behavior: HitTestBehavior.translucent,
                child: Container(color: Colors.transparent),
              ),
            ),
            // The popup
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: widget.direction == PopupDirection.above
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              followerAnchor: widget.direction == PopupDirection.above
                  ? Alignment.bottomCenter
                  : Alignment.topCenter,
              offset: Offset(
                horizontalOffset,
                widget.direction == PopupDirection.above ? -gap : gap,
              ),
              child: MouseRegion(
                onEnter: (_) => _onOverlayHover(true),
                onExit: (_) => _onOverlayHover(false),
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    alignment: widget.direction == PopupDirection.above
                        ? Alignment.bottomCenter
                        : Alignment.topCenter,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: _buildPopupContent(widget.width, screenSize),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
    _animationController.forward();
  }

  double _calculatePopupWidth(Size screenSize) {
    final isSmallScreen = screenSize.width < 600;
    final isMediumScreen = screenSize.width < 900;

    if (isSmallScreen) {
      return screenSize.width - 32;
    } else if (isMediumScreen) {
      return 280;
    } else {
      return 320;
    }
  }

  Widget _buildPopupContent(double? width, Size screenSize) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Determine colors based on parent color or theme
    final backgroundColor = widget.parentColor != null
        ? colorScheme.surfaceContainerHigh
        : colorScheme.surfaceContainerHigh;
    final foregroundColor = colorScheme.onSurface;

    // Maximum width considering screen padding
    final maxWidth = screenSize.width - 24;
    final isMobile = screenSize.width < 600;

    // On mobile: use provided width or full screen width
    // On larger screens: fit to content with max constraint
    final double effectiveMaxWidth =
        width?.clamp(0.0, maxWidth) ?? (isMobile ? maxWidth : 400);

    return Material(
      elevation: 16,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(16),
      color: backgroundColor,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: isMobile ? effectiveMaxWidth : 120,
          maxWidth: effectiveMaxWidth,
          maxHeight: screenSize.height * 0.5,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildContent(foregroundColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContent(Color foregroundColor) {
    if (widget.builder != null) {
      return [widget.builder!(context, _controller.close)];
    }

    if (widget.sections != null) {
      return _buildSections(widget.sections!(context), foregroundColor);
    }

    if (widget.items != null) {
      return [_buildItemsRow(widget.items!(context), foregroundColor)];
    }

    return [];
  }

  List<Widget> _buildSections(
    List<AdaptiveMenuSection> sections,
    Color foregroundColor,
  ) {
    final widgets = <Widget>[];
    for (int i = 0; i < sections.length; i++) {
      final section = sections[i];

      // Section title
      if (section.title != null) {
        widgets.add(
          Padding(
            padding: EdgeInsets.only(top: i > 0 ? 12 : 0, bottom: 8, left: 4),
            child: Text(
              section.title!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: foregroundColor.withValues(alpha: 0.6),
              ),
            ),
          ),
        );
      }

      // Custom content
      if (section.customContent != null) {
        widgets.add(section.customContent!);
      }
      // Grid layout
      else if (section.isGrid) {
        widgets.add(
          _buildItemsGrid(
            section.items,
            foregroundColor,
            section.gridCrossAxisCount,
          ),
        );
      }
      // Row layout
      else {
        widgets.add(_buildItemsRow(section.items, foregroundColor));
      }

      // Divider between sections
      if (i < sections.length - 1) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(
              height: 1,
              color: foregroundColor.withValues(alpha: 0.1),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _buildItemsRow(List<AdaptiveMenuItem> items, Color foregroundColor) {
    // Vertically stacked items with staggered animations
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: List.generate(items.length, (index) {
        return _AnimatedMenuItem(
          item: items[index],
          index: index,
          totalItems: items.length,
          foregroundColor: foregroundColor,
          showLabels: widget.showLabels,
          animationController: _animationController,
          onTap: () {
            _controller.close();
            items[index].onTap?.call();
          },
        );
      }),
    );
  }

  Widget _buildItemsGrid(
    List<AdaptiveMenuItem> items,
    Color foregroundColor,
    int crossAxisCount,
  ) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(items.length, (index) {
        return _AnimatedMenuItem(
          item: items[index],
          index: index,
          totalItems: items.length,
          foregroundColor: foregroundColor,
          showLabels: false,
          animationController: _animationController,
          onTap: () {
            _controller.close();
            items[index].onTap?.call();
          },
        );
      }),
    );
  }

  Future<void> _closeOverlay({bool animate = true}) async {
    if (_overlayEntry == null) return;

    if (animate) {
      await _animationController.reverse();
    }
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _onHover(bool isHovering) {
    if (!widget.showOnHover || !_isDesktop) return;

    _isHovering = isHovering;
    _controller.setHovered(isHovering);

    if (isHovering) {
      Future.delayed(Duration(milliseconds: widget.hoverDelay), () {
        if (_isHovering && mounted && !_controller.isOpen) {
          _controller.open();
        }
      });
    } else {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!_isHovering && !_isOverlayHovering && mounted) {
          _controller.close();
        }
      });
    }
  }

  void _onOverlayHover(bool isHovering) {
    if (!widget.showOnHover || !_isDesktop) return;

    _isOverlayHovering = isHovering;

    if (!isHovering) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!_isHovering && !_isOverlayHovering && mounted) {
          _controller.close();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_controller.isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controller.isOpen) {
          _controller.close();
        }
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: MouseRegion(
          onEnter: (_) => _onHover(true),
          onExit: (_) => _onHover(false),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Animated menu item with staggered animation
class _AnimatedMenuItem extends StatelessWidget {
  final AdaptiveMenuItem item;
  final int index;
  final int totalItems;
  final Color foregroundColor;
  final bool showLabels;
  final AnimationController animationController;
  final VoidCallback? onTap;

  const _AnimatedMenuItem({
    required this.item,
    required this.index,
    required this.totalItems,
    required this.foregroundColor,
    required this.showLabels,
    required this.animationController,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (item.customWidget != null) {
      return item.customWidget!;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Staggered animation - each item animates slightly after the previous
    final startInterval = index / (totalItems + 2);
    final endInterval = (index + 2) / (totalItems + 2);

    final animation = CurvedAnimation(
      parent: animationController,
      curve: Interval(
        startInterval.clamp(0.0, 1.0),
        endInterval.clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );

    final slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(animation);

    final fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(animation);

    return SlideTransition(
      position: slideAnimation,
      child: FadeTransition(
        opacity: fadeAnimation,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: item.isSelected
                    ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                    : Colors.transparent,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.icon,
                    size: 20,
                    color:
                        item.iconColor ??
                        (item.isSelected
                            ? colorScheme.primary
                            : foregroundColor),
                  ),
                  if (showLabels && item.label != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.label!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: item.isSelected
                              ? colorScheme.primary
                              : foregroundColor,
                        ),
                      ),
                    ),
                  ] else if (item.label != null) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.label!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: item.isSelected
                              ? colorScheme.primary
                              : foregroundColor,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A preset popup menu for toolbar actions (attachments, formatting, etc.)
class ToolbarPopupMenu extends StatelessWidget {
  final AdaptivePopupController controller;
  final IconData icon;
  final String? tooltip;
  final List<AdaptiveMenuItem> Function(BuildContext context) items;
  final Color? parentColor;
  final bool showOnHover;
  final bool isDisabled;

  const ToolbarPopupMenu({
    super.key,
    required this.controller,
    required this.icon,
    required this.items,
    this.tooltip,
    this.parentColor,
    this.showOnHover = true,
    this.isDisabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: controller,
      items: items,
      parentColor: parentColor,
      showOnHover: showOnHover,
      child: IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: isDisabled ? null : controller.toggle,
      ),
    );
  }
}
