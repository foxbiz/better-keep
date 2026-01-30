import 'dart:ui';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class AdaptiveToolbar extends StatefulWidget {
  final Color parentColor;
  final List<Widget> children;
  final ScrollController? scrollController;
  final bool hideToggle;

  static double get iconSize {
    // Guard against Windows platform view issues during certain lifecycle states
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return 20.0;
      final width = views.first.display.size.width;
      return switch (width) {
        < 400 => 16.0,
        < 600 => 18.0,
        _ => 20.0,
      };
    } catch (_) {
      return 20.0; // Default fallback on Windows display access errors
    }
  }

  const AdaptiveToolbar({
    required super.key,
    required this.children,
    required this.parentColor,
    this.scrollController,
    this.hideToggle = false,
  });

  @override
  State<AdaptiveToolbar> createState() => _AdaptiveToolbarState();
}

class _AdaptiveToolbarState extends State<AdaptiveToolbar> {
  late final double iconSize;
  late Color backgroundColor;
  late Color foregroundColor;
  late Color disabledColor;

  late bool isGridMode;
  late final ScrollController _scrollController;

  bool showToggleLayout = false;
  Color selectedColor = Colors.amber;

  Widget get layoutToggleButton => IconButton(
    icon: Icon(
      isGridMode ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
    ),
    tooltip: isGridMode ? 'Collapse toolbar' : 'Expand toolbar',
    onPressed: () {
      AppState.setToolbarGridMode(widget.key.toString(), !isGridMode);
    },
  );

  @override
  void initState() {
    _scrollController = widget.scrollController ?? ScrollController();
    iconSize = AdaptiveToolbar.iconSize;
    isGridMode = AppState.getToolbarGridMode(widget.key.toString());

    if (isDark(widget.parentColor)) {
      backgroundColor = const Color.fromARGB(123, 255, 255, 255);
      foregroundColor = Colors.black;
      disabledColor = Colors.black38;
    } else {
      backgroundColor = const Color.fromARGB(123, 0, 0, 0);
      foregroundColor = Colors.white;
      disabledColor = Colors.white38;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        showToggleLayout = _scrollController.position.maxScrollExtent > 0;
      } else {
        showToggleLayout = isGridMode;
      }

      if (mounted) {
        setState(() {});
      }
    });

    AppState.subscribe("toolbar_grid_modes", _updateLayoutMode);
    super.initState();
  }

  @override
  void dispose() {
    AppState.unsubscribe("toolbar_grid_modes", _updateLayoutMode);
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double hPadding = isGridMode ? 0.0 : 16.0;
    double buttonSize = iconSize + 8.0 < 36.0 ? 36.0 : iconSize + 8.0;
    double rowHeight = buttonSize + 8.0;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isGridMode ? 16 : 100),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: hPadding),
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
              height: isGridMode ? null : rowHeight,
              constraints: isGridMode
                  ? BoxConstraints(
                      minHeight: rowHeight,
                      maxHeight: rowHeight * 3,
                    )
                  : BoxConstraints(minHeight: rowHeight, maxHeight: rowHeight),
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: ButtonStyle(
                    iconSize: WidgetStateProperty.all(iconSize),
                    minimumSize: WidgetStateProperty.all(
                      Size(buttonSize, buttonSize),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                  child: isGridMode
                      ? _buildGridLayout(buttonSize, rowHeight)
                      : _buildScrollLayout(buttonSize, rowHeight),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _updateLayoutMode(dynamic _) {
    setState(() {
      isGridMode = AppState.getToolbarGridMode(widget.key.toString());
    });
  }

  Widget _buildScrollLayout(double buttonSize, double rowHeight) {
    List<Widget> children = [];

    for (final child in widget.children) {
      children.add(SliverToBoxAdapter(child: child));
    }

    if (showToggleLayout && !widget.hideToggle) {
      children.add(SliverToBoxAdapter(child: layoutToggleButton));
    }

    return SizedBox(
      key: const ValueKey('scroll_layout'),
      height: rowHeight,
      child: CustomScrollView(
        scrollDirection: Axis.horizontal,
        controller: _scrollController,
        slivers: children,
        shrinkWrap: true,
      ),
    );
  }

  Widget _buildGridLayout(double buttonSize, double rowHeight) {
    return SingleChildScrollView(
      controller: _scrollController,
      key: const ValueKey('grid'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          spacing: 0,
          runSpacing: 0,
          alignment: WrapAlignment.start,
          verticalDirection: VerticalDirection.up,
          children: [
            ...widget.children,
            if (!widget.hideToggle) layoutToggleButton,
          ],
        ),
      ),
    );
  }
}
