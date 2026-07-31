import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A menu item for the bubble menu
class BubbleMenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? backgroundColor;
  final Color? iconColor;

  const BubbleMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.backgroundColor,
    this.iconColor,
  });
}

/// A gesture-based radial bubble menu that appears on touch/press.
///
/// Interaction:
/// 1. Touch down on FAB → shows bubble menu items in an arc
/// 2. Slide finger to a bubble → highlights it, release triggers action
/// 3. Release on FAB (no slide) → triggers default action
class BubbleMenu extends StatefulWidget {
  /// The menu items to display in the radial menu
  final List<BubbleMenuItem> items;

  /// Called when FAB is tapped without sliding to any menu item
  final VoidCallback? onDefaultAction;

  /// The background color of the FAB
  final Color? fabColor;

  /// The icon color of the FAB
  final Color? fabIconColor;

  /// The icon to show on the FAB
  final IconData fabIcon;

  /// Distance from the FAB center to the menu items
  final double itemDistance;

  /// Size of the menu item bubbles
  final double itemSize;

  /// Size of the FAB
  final double fabSize;

  /// Whether the menu is disabled
  final bool disabled;

  /// Animation duration
  final Duration animationDuration;

  /// Tooltip for the FAB
  final String? tooltip;

  /// Called when menu open state changes
  final ValueChanged<bool>? onMenuStateChanged;

  const BubbleMenu({
    super.key,
    required this.items,
    this.onDefaultAction,
    this.fabColor,
    this.fabIconColor,
    this.fabIcon = Icons.add,
    this.itemDistance = 100,
    this.itemSize = 56,
    this.fabSize = 56,
    this.disabled = false,
    this.animationDuration = const Duration(milliseconds: 200),
    this.tooltip,
    this.onMenuStateChanged,
  });

  @override
  State<BubbleMenu> createState() => _BubbleMenuState();
}

class _BubbleMenuState extends State<BubbleMenu>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _expandAnimation;

  bool _isMenuOpen = false;
  int? _hoveredItemIndex;
  Offset _startPosition = Offset.zero;
  Offset _currentPosition = Offset.zero;
  bool _hasMoved = false;
  bool _isWaitingToOpen = false;
  bool _isTouching = false;

  static const double _moveThreshold = 10.0;
  static const Duration _menuOpenDelay = Duration(milliseconds: 150);
  static const double _startAngle = math.pi * 0.52;
  static const double _endAngle = math.pi * 1.08;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: widget.animationDuration,
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  double _getAngleStep() {
    final itemCount = widget.items.length;
    return itemCount > 1 ? (_endAngle - _startAngle) / (itemCount - 1) : 0.0;
  }

  double _getBaseAngle(int index) {
    final itemCount = widget.items.length;
    return itemCount > 1
        ? _startAngle + (_getAngleStep() * index)
        : math.pi * 0.75;
  }

  void _openMenu() {
    if (_isMenuOpen || widget.disabled) return;
    setState(() {
      _isMenuOpen = true;
      _hoveredItemIndex = null;
      _hasMoved = false;
    });
    _animationController.forward();
    HapticFeedback.lightImpact();
    widget.onMenuStateChanged?.call(true);
  }

  void _closeMenu({int? selectedIndex}) {
    if (!_isMenuOpen) return;
    final wasHovering = selectedIndex != null;
    setState(() {
      _isMenuOpen = false;
      _hoveredItemIndex = null;
    });
    widget.onMenuStateChanged?.call(false);
    _animationController.reverse().then((_) {
      if (wasHovering &&
          selectedIndex >= 0 &&
          selectedIndex < widget.items.length) {
        widget.items[selectedIndex].onTap();
        HapticFeedback.mediumImpact();
      }
    });
  }

  void _handlePanStart(DragStartDetails details) {
    _startPosition = details.localPosition;
    _hasMoved = false;
    _isWaitingToOpen = true;
    setState(() => _isTouching = true);
    Future.delayed(_menuOpenDelay, () {
      if (_isWaitingToOpen && mounted) _openMenu();
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!_isMenuOpen) return;
    final currentPosition = details.localPosition;
    if ((currentPosition - _startPosition).distance > _moveThreshold) {
      _hasMoved = true;
    }
    _currentPosition = currentPosition;

    final totalWidth = widget.itemDistance + widget.itemSize + widget.fabSize;
    final totalHeight =
        widget.itemDistance + widget.itemSize + widget.fabSize + 24;
    final fabLeft = totalWidth - widget.fabSize;
    final fabTop = totalHeight - widget.fabSize;
    final stackPosition = Offset(
      fabLeft + currentPosition.dx,
      fabTop + currentPosition.dy,
    );

    final hoveredIndex = _getHoveredItemIndex(stackPosition);
    if (hoveredIndex != _hoveredItemIndex) {
      setState(() => _hoveredItemIndex = hoveredIndex);
      if (hoveredIndex != null) HapticFeedback.selectionClick();
    } else {
      setState(() {});
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    setState(() => _isTouching = false);
    if (_isWaitingToOpen && !_isMenuOpen) {
      _isWaitingToOpen = false;
      if (widget.onDefaultAction != null) {
        HapticFeedback.lightImpact();
        widget.onDefaultAction!();
      } else {
        _openMenu();
      }
      return;
    }
    _isWaitingToOpen = false;
    if (!_isMenuOpen) return;
    if (_hoveredItemIndex != null) {
      _closeMenu(selectedIndex: _hoveredItemIndex);
    } else {
      _closeMenu();
    }
  }

  void _handlePanCancel() {
    _isWaitingToOpen = false;
    setState(() => _isTouching = false);
    _closeMenu();
  }

  int? _getHoveredItemIndex(Offset localPosition) {
    final itemCount = widget.items.length;
    final totalWidth = widget.itemDistance + widget.itemSize + widget.fabSize;
    final totalHeight =
        widget.itemDistance + widget.itemSize + widget.fabSize + 24;
    final fabCenterX = totalWidth - widget.fabSize / 2;

    for (int i = 0; i < itemCount; i++) {
      final angle = _getBaseAngle(i);
      final x = fabCenterX + math.cos(angle) * widget.itemDistance;
      final bottomFromOrigin = math.sin(angle) * widget.itemDistance + 24;
      final y = totalHeight - bottomFromOrigin - widget.itemSize / 2;
      final distance = (localPosition - Offset(x, y)).distance;
      if (distance <= widget.itemSize / 2 + 16) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fabColor = widget.fabColor ?? colorScheme.primaryContainer;
    final fabIconColor = widget.fabIconColor ?? colorScheme.onPrimaryContainer;
    final totalWidth = widget.itemDistance + widget.itemSize + widget.fabSize;
    final totalHeight =
        widget.itemDistance + widget.itemSize + widget.fabSize + 24;

    return TapRegion(
      onTapOutside: (_) {
        if (_isMenuOpen) {
          _closeMenu();
        }
      },
      child: SizedBox(
        width: totalWidth,
        height: totalHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ..._buildMenuItems(context),
                    if (_isMenuOpen && _hasMoved)
                      _buildGhostFab(
                        fabColor,
                        fabIconColor,
                        totalWidth,
                        totalHeight,
                      ),
                  ],
                );
              },
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: GestureDetector(
                onPanStart: widget.disabled ? null : _handlePanStart,
                onPanUpdate: widget.disabled ? null : _handlePanUpdate,
                onPanEnd: widget.disabled ? null : _handlePanEnd,
                onPanCancel: widget.disabled ? null : _handlePanCancel,
                behavior: HitTestBehavior.opaque,
                child: _buildFab(fabColor, fabIconColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGhostFab(
    Color fabColor,
    Color fabIconColor,
    double totalWidth,
    double totalHeight,
  ) {
    final fabLeft = totalWidth - widget.fabSize;
    final fabTop = totalHeight - widget.fabSize;
    return Positioned(
      left: fabLeft + _currentPosition.dx - widget.fabSize * 0.4,
      top: fabTop + _currentPosition.dy - widget.fabSize * 0.4,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.4,
          child: Container(
            width: widget.fabSize * 0.8,
            height: widget.fabSize * 0.8,
            decoration: BoxDecoration(
              color: fabColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              widget.fabIcon,
              color: fabIconColor.withValues(alpha: 0.7),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFab(Color fabColor, Color fabIconColor) {
    final scale = _isMenuOpen ? 1.0 + (_expandAnimation.value * 0.1) : 1.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = _isTouching || _isMenuOpen ? widget.fabSize / 2 : 16.0;

    return Transform.scale(
      scale: scale,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          width: widget.fabSize,
          height: widget.fabSize,
          decoration: BoxDecoration(
            color: fabColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.2)
                  : fabIconColor.withValues(alpha: 0.1),
              width: isDark ? 1.5 : 1,
            ),
          ),
          child: AnimatedRotation(
            turns: _isMenuOpen ? 0.125 : 0,
            duration: widget.animationDuration,
            curve: Curves.easeOutCubic,
            child: Icon(widget.fabIcon, color: fabIconColor, size: 28),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMenuItems(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final items = widget.items;
    final itemCount = items.length;
    final totalWidth = widget.itemDistance + widget.itemSize + widget.fabSize;
    final fabCenterX = totalWidth - widget.fabSize / 2;

    return List.generate(itemCount, (index) {
      final item = items[index];
      final isHovered = _hoveredItemIndex == index;

      final itemDelay = index / itemCount;
      final itemProgress = Interval(
        itemDelay * 0.3,
        0.6 + itemDelay * 0.4,
        curve: Curves.easeOutBack,
      ).transform(_animationController.value);

      final baseAngle = _getBaseAngle(index);
      final distance = widget.itemDistance * itemProgress;
      final baseX =
          fabCenterX + math.cos(baseAngle) * distance - widget.itemSize / 2;
      final baseY =
          widget.fabSize / 2 -
          math.sin(baseAngle) * distance -
          widget.itemSize / 2;

      final bgColor = item.backgroundColor ?? colorScheme.secondaryContainer;
      final iconColor = item.iconColor ?? colorScheme.onSecondaryContainer;
      final hoveredBgColor = colorScheme.primary;
      final hoveredIconColor = colorScheme.onPrimary;

      double targetOffsetX = 0;
      double targetOffsetY = 0;

      if (_hoveredItemIndex != null && itemProgress > 0 && !isHovered) {
        final diff = index - _hoveredItemIndex!;
        if (diff.abs() == 1) {
          final pushDistance = widget.itemSize * 0.08;
          targetOffsetX = math.cos(baseAngle) * pushDistance * diff.sign;
          targetOffsetY = -math.sin(baseAngle) * pushDistance * diff.sign;
        }
      }

      return Positioned(
        bottom: widget.fabSize / 2 - baseY - widget.itemSize / 2 + 24,
        left: baseX,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: isHovered ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          builder: (context, hoverValue, child) {
            return TweenAnimationBuilder<Offset>(
              tween: Tween(
                begin: Offset.zero,
                end: Offset(targetOffsetX, targetOffsetY),
              ),
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              builder: (context, offset, child) {
                final currentScale = itemProgress * (1.0 + hoverValue * 0.1);
                return Transform.translate(
                  offset: offset,
                  child: Transform.scale(
                    scale: currentScale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedOpacity(
                          opacity: isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: AnimatedSlide(
                            offset: isHovered
                                ? Offset.zero
                                : const Offset(0, 0.5),
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOutCubic,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (_isMenuOpen) {
                              _closeMenu(selectedIndex: index);
                            }
                          },
                          child: MouseRegion(
                            onEnter: (_) {
                              if (_isMenuOpen) {
                                setState(() => _hoveredItemIndex = index);
                              }
                            },
                            onExit: (_) {
                              if (_isMenuOpen && _hoveredItemIndex == index) {
                                setState(() => _hoveredItemIndex = null);
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOutCubic,
                              width: widget.itemSize,
                              height: widget.itemSize,
                              decoration: BoxDecoration(
                                color: isHovered ? hoveredBgColor : bgColor,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isHovered ? 0.25 : 0.15,
                                    ),
                                    blurRadius: isHovered ? 12 : 8,
                                    offset: const Offset(0, 3),
                                  ),
                                  if (isHovered)
                                    BoxShadow(
                                      color: hoveredBgColor.withValues(
                                        alpha: 0.4,
                                      ),
                                      blurRadius: 16,
                                      spreadRadius: 2,
                                    ),
                                ],
                              ),
                              child: Icon(
                                item.icon,
                                size: widget.itemSize * 0.5,
                                color: isHovered ? hoveredIconColor : iconColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    });
  }
}
