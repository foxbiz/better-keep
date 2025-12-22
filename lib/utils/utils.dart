import 'package:better_keep/config.dart';
import 'package:flutter/material.dart';

bool isDark(Color? color) {
  if (color == null) return false;
  return color == Colors.transparent ||
      ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
}

Future<dynamic> showPage(BuildContext context, Widget page) {
  final isBigScreen =
      MediaQuery.of(context).size.width >= bigScreenWidthThreshold;

  if (isBigScreen) {
    // Check if we're already inside a dialog route to avoid stacking barriers
    final isNestedDialog = ModalRoute.of(context) is _DialogPageRoute;
    return Navigator.push(
      context,
      _DialogPageRoute(page: page, showBarrier: !isNestedDialog),
    );
  } else {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => page),
    );
  }
}

class _DialogPageRoute<T> extends PageRoute<T> {
  final Widget page;
  final bool showBarrier;

  _DialogPageRoute({required this.page, this.showBarrier = true});

  @override
  Color? get barrierColor => showBarrier ? Colors.black54 : Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive sizing: use 80% of screen with max bounds
        final width = (constraints.maxWidth * 0.8).clamp(400.0, 900.0);
        final height = (constraints.maxHeight * 0.85).clamp(400.0, 700.0);
        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: width,
              height: height,
              child: Material(child: page),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
      child: child,
    );
  }
}
