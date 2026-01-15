import 'dart:ui';

import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class AdaptiveToolbar extends StatelessWidget {
  final Color parentColor;
  final Widget child;
  final double? iconSize;
  final bool isGridMode;

  const AdaptiveToolbar({
    super.key,
    required this.parentColor,
    required this.child,
    this.iconSize,
    this.isGridMode = false,
  });

  @override
  Widget build(BuildContext context) {
    late Color backgroundColor;
    late Color foregroundColor;
    late Color disabledColor;
    const Color selectedColor = Colors.amber;

    // When parent is light, use dark toolbar for contrast (and vice versa)
    if (isDark(parentColor)) {
      backgroundColor = const Color.fromARGB(123, 255, 255, 255);
      foregroundColor = Colors.black;
      disabledColor = Colors.black38;
    } else {
      backgroundColor = const Color.fromARGB(123, 0, 0, 0);
      foregroundColor = Colors.white;
      disabledColor = Colors.white38;
    }

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isGridMode ? 16 : 100),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(77),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
                color: backgroundColor,
              ),
              height: isGridMode ? null : 50,
              constraints: isGridMode
                  ? const BoxConstraints(minHeight: 50, maxHeight: 150)
                  : const BoxConstraints(minHeight: 50, maxHeight: 50),
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: ButtonStyle(
                    iconSize: iconSize != null
                        ? WidgetStateProperty.all(iconSize)
                        : null,
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return selectedColor;
                      }
                      if (states.contains(WidgetState.disabled)) {
                        return disabledColor;
                      }
                      return foregroundColor;
                    }),
                  ),
                ),
                child: IconTheme(
                  data: IconThemeData(color: foregroundColor, size: iconSize),
                  child: DefaultTextStyle(
                    style: TextStyle(color: foregroundColor),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, animation) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                      child: isGridMode
                          ? SingleChildScrollView(
                              key: const ValueKey('grid'),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  alignment: WrapAlignment.center,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: _extractChildren(child),
                                ),
                              ),
                            )
                          : SizedBox(
                              key: const ValueKey('scroll'),
                              height: 50,
                              child: child,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Extract children from CustomScrollView slivers for use in Wrap widget.
  ///
  /// Note: Only handles [SliverToBoxAdapter] slivers. Other sliver types
  /// (e.g., SliverList, SliverGrid) are silently skipped. This is intentional
  /// as the toolbar only uses SliverToBoxAdapter for its items.
  List<Widget> _extractChildren(Widget child) {
    if (child is CustomScrollView) {
      final slivers = child.slivers;
      final children = <Widget>[];
      for (final sliver in slivers) {
        if (sliver is SliverToBoxAdapter) {
          if (sliver.child != null) {
            children.add(sliver.child!);
          }
        }
      }
      return children;
    }
    return [child];
  }
}
