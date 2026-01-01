import 'package:flutter/material.dart';

/// Collection of modern dark themes for the app
class DarkThemes {
  static const String defaultId = 'dark_default';

  static final Map<String, ThemeData> themes = {
    'dark_default': _createDefaultDark(),
    'dark_midnight': _createMidnightDark(),
    'dark_ocean': _createOceanDark(),
    'dark_forest': _createForestDark(),
    'dark_rose': _createRoseDark(),
    'dark_amber': _createAmberDark(),
  };

  static final Map<String, String> themeNames = {
    'dark_default': 'Default Dark',
    'dark_midnight': 'Midnight',
    'dark_ocean': 'Ocean',
    'dark_forest': 'Forest',
    'dark_rose': 'Rose',
    'dark_amber': 'Amber',
  };

  static ThemeData _createDefaultDark() {
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: Colors.deepPurple.shade700,
        style: ListTileStyle.list,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) {
              return const Color.fromARGB(255, 100, 84, 247);
            }
            if (state.contains(WidgetState.disabled)) {
              return const Color.fromARGB(255, 99, 99, 99);
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.grey.shade900,
        textStyle: TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return TextStyle(color: const Color.fromARGB(76, 255, 255, 255));
          }
          return const TextStyle(color: Colors.white70);
        }),
      ),
    );
  }

  static ThemeData _createMidnightDark() {
    const seedColor = Color(0xFF6366F1); // Indigo
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
        surface: const Color(0xFF0F0F23),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF0F0F23),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1A2E),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: seedColor.withValues(alpha: 0.3),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.white24;
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF1A1A2E),
        textStyle: const TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createOceanDark() {
    const seedColor = Color(0xFF0EA5E9); // Sky blue
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
        surface: const Color(0xFF0C1929),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF0C1929),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF132F4C),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF132F4C),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: seedColor.withValues(alpha: 0.3),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.white24;
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF132F4C),
        textStyle: const TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createForestDark() {
    const seedColor = Color(0xFF22C55E); // Green
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
        surface: const Color(0xFF0D1F12),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF0D1F12),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1A3A21),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A3A21),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: seedColor.withValues(alpha: 0.3),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.white24;
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF1A3A21),
        textStyle: const TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createRoseDark() {
    const seedColor = Color(0xFFF43F5E); // Rose
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
        surface: const Color(0xFF1F0D14),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF1F0D14),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF3A1A24),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF3A1A24),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: seedColor.withValues(alpha: 0.3),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.white24;
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF3A1A24),
        textStyle: const TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  static ThemeData _createAmberDark() {
    const seedColor = Color(0xFFF59E0B); // Amber
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
        surface: const Color(0xFF1F1708),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF1F1708),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF3A2D14),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF3A2D14),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: Colors.white,
        selectedTileColor: seedColor.withValues(alpha: 0.3),
        textColor: Colors.white70,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          iconColor: WidgetStateProperty.resolveWith((state) {
            if (state.contains(WidgetState.selected)) return seedColor;
            if (state.contains(WidgetState.disabled)) {
              return Colors.white24;
            }
            return Colors.white70;
          }),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFF3A2D14),
        textStyle: const TextStyle(color: Colors.white70),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
