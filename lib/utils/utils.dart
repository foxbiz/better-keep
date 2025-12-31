import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:flutter/material.dart';

bool isDark(Color? color) {
  if (color == null) return false;
  return color == Colors.transparent ||
      ThemeData.estimateBrightnessForColor(color) == Brightness.dark;
}

String uuid() {
  final uuid = const Uuid().v4();
  return uuid;
}
