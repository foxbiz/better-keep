import 'package:flutter/material.dart';

/// Collection of modern light themes for the app
class LightThemes {
  static const String defaultId = 'light_default';

  static final Map<String, ThemeData> themes = {
    'light_default': _createDefaultLight(),
    'light_clean': _createCleanLight(),
    'light_ocean': _createOceanLight(),
    'light_forest': _createForestLight(),
    'light_rose': _createRoseLight(),
    'light_amber': _createAmberLight(),
  };

  static final Map<String, String> themeNames = {
    'light_default': 'Default Light',
    'light_clean': 'Clean',
    'light_ocean': 'Ocean',
    'light_forest': 'Forest',
    'light_rose': 'Rose',
    'light_amber': 'Amber',
  };

  static ThemeData _createDefaultLight() {
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: Brightness.light,
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: Colors.deepPurple.shade400,
        style: ListTileStyle.list,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        textColor: Colors.black87,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) {
              return const Color.fromARGB(255, 100, 84, 247);
            }
            if (state.contains(WidgetState.disabled)) {
              return const Color.fromARGB(255, 160, 160, 160);
            }
            return Colors.black87;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.grey.shade100,
        textStyle: TextStyle(color: Colors.black87),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return TextStyle(color: const Color.fromARGB(76, 0, 0, 0));
          }
          return const TextStyle(color: Colors.black87);
        }),
      ),
    );
  }

  static ThemeData _createCleanLight() {
    const seedColor = Color(0xFF6366F1); // Indigo
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
        surface: const Color(0xFFFAFAFC),
        onSurface: const Color(0xFF1A1A2E),
      ),
      scaffoldBackgroundColor: const Color(0xFFFAFAFC),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1A1A2E),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: Colors.black12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: seedColor,
        selectedTileColor: seedColor.withValues(alpha: 0.15),
        textColor: const Color(0xFF1A1A2E),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.black26;
            }
            return const Color(0xFF1A1A2E);
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        textStyle: const TextStyle(color: Color(0xFF1A1A2E)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createOceanLight() {
    const seedColor = Color(0xFF0EA5E9); // Sky blue
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
        surface: const Color(0xFFF0F9FF),
        onSurface: const Color(0xFF0C1929),
      ),
      scaffoldBackgroundColor: const Color(0xFFF0F9FF),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF0C1929),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: seedColor.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: seedColor,
        selectedTileColor: seedColor.withValues(alpha: 0.15),
        textColor: const Color(0xFF0C1929),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.black26;
            }
            return const Color(0xFF0C1929);
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        textStyle: const TextStyle(color: Color(0xFF0C1929)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createForestLight() {
    const seedColor = Color(0xFF22C55E); // Green
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
        surface: const Color(0xFFF0FDF4),
        onSurface: const Color(0xFF0D1F12),
      ),
      scaffoldBackgroundColor: const Color(0xFFF0FDF4),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF0D1F12),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: seedColor.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: seedColor,
        selectedTileColor: seedColor.withValues(alpha: 0.15),
        textColor: const Color(0xFF0D1F12),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.black26;
            }
            return const Color(0xFF0D1F12);
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        textStyle: const TextStyle(color: Color(0xFF0D1F12)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createRoseLight() {
    const seedColor = Color(0xFFF43F5E); // Rose
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
        surface: const Color(0xFFFFF1F2),
        onSurface: const Color(0xFF1F0D14),
      ),
      scaffoldBackgroundColor: const Color(0xFFFFF1F2),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1F0D14),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: seedColor.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: seedColor,
        selectedTileColor: seedColor.withValues(alpha: 0.15),
        textColor: const Color(0xFF1F0D14),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.black26;
            }
            return const Color(0xFF1F0D14);
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        textStyle: const TextStyle(color: Color(0xFF1F0D14)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createAmberLight() {
    const seedColor = Color(0xFFF59E0B); // Amber
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
        surface: const Color(0xFFFFFBEB),
        onSurface: const Color(0xFF1F1708),
      ),
      scaffoldBackgroundColor: const Color(0xFFFFFBEB),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1F1708),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shadowColor: seedColor.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: seedColor,
        selectedTileColor: seedColor.withValues(alpha: 0.15),
        textColor: const Color(0xFF1F1708),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.black26;
            }
            return const Color(0xFF1F1708);
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        textStyle: const TextStyle(color: Color(0xFF1F1708)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
