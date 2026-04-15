import 'dart:io' show Platform;

import 'package:better_keep/config.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

bool isDark(Color? color) {
  if (color == null) return false;
  return color == Colors.transparent ||
      ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
}

bool _isMobilePlatform() {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

bool isBigScreen(BuildContext context) {
  return MediaQuery.of(context).size.width >= bigScreenWidthThreshold &&
      !_isMobilePlatform();
}

Future<dynamic> showPage(
  BuildContext context,
  Widget page, {
  bool allowFullScreen = false,
}) {
  final bigScreen = isBigScreen(context);

  if (bigScreen) {
    // Skip barrier only when stacking on a non-fullscreen dialog (to avoid double-dim).
    // A fullscreen dialog looks like a regular page, so nested dialogs should still dim.
    final parentRoute = ModalRoute.of(context);
    final parentIsWindowedDialog =
        parentRoute is _DialogPageRoute &&
        !(parentRoute.allowFullScreen && AppState.editorFullScreen);
    return Navigator.push(
      context,
      _DialogPageRoute(
        page: page,
        showBarrier: !parentIsWindowedDialog,
        allowFullScreen: allowFullScreen,
      ),
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
  final bool allowFullScreen;

  _DialogPageRoute({
    required this.page,
    this.showBarrier = true,
    this.allowFullScreen = false,
  });

  @override
  Color? get barrierColor => showBarrier ? Colors.black54 : Colors.transparent;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

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
    return ValueListenableBuilder<bool>(
      valueListenable: AppState.editorFullScreenNotifier,
      builder: (context, editorFullScreen, _) {
        final isFullScreen = allowFullScreen && editorFullScreen;
        return LayoutBuilder(
          builder: (context, constraints) {
            final double width;
            final double height;
            final double radius;
            if (isFullScreen) {
              width = constraints.maxWidth;
              height = constraints.maxHeight;
              radius = 0;
            } else {
              width = (constraints.maxWidth * 0.8).clamp(400.0, 900.0);
              height = (constraints.maxHeight * 0.85).clamp(400.0, 700.0);
              radius = 12;
            }
            return Stack(
              children: [
                if (!isFullScreen)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.maybePop(context),
                    ),
                  ),
                Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    width: width,
                    height: height,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: isFullScreen
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                            ],
                    ),
                    child: Material(child: page),
                  ),
                ),
              ],
            );
          },
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
