import 'dart:ui';

import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class AdaptiveToolbar extends StatelessWidget {
  final Color parentColor;
  final Widget child;

  const AdaptiveToolbar({
    super.key,
    required this.parentColor,
    required this.child,
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
          borderRadius: BorderRadius.circular(100),
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
              height: 50,
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: ButtonStyle(
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
                  data: IconThemeData(color: foregroundColor),
                  child: DefaultTextStyle(
                    style: TextStyle(color: foregroundColor),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
