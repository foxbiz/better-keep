import 'package:better_keep/state.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

void snackbar(String message, [Color? color]) {
  // Use theme-appropriate default color if not specified
  final effectiveColor =
      color ?? (AppState.isDarkMode ? Colors.white70 : Colors.black87);
  final textColor = isDark(effectiveColor) ? Colors.white : Colors.black;
  final snackBar = SnackBar(
    content: Text(message, style: TextStyle(color: textColor)),
    backgroundColor: effectiveColor,
  );
  AppState.scaffoldMessengerKey.currentState?.showSnackBar(snackBar);
}
