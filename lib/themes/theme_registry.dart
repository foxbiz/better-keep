import 'package:better_keep/themes/dark_themes.dart';
import 'package:better_keep/themes/light_themes.dart';
import 'package:flutter/material.dart';

/// Central registry for all app themes
class ThemeRegistry {
  /// Get all available dark themes
  static Map<String, ThemeData> get darkThemes => DarkThemes.themes;

  /// Get all available light themes
  static Map<String, ThemeData> get lightThemes => LightThemes.themes;

  /// Get dark theme names for display
  static Map<String, String> get darkThemeNames => DarkThemes.themeNames;

  /// Get light theme names for display
  static Map<String, String> get lightThemeNames => LightThemes.themeNames;

  /// Get the default dark theme ID
  static String get defaultDarkThemeId => DarkThemes.defaultId;

  /// Get the default light theme ID
  static String get defaultLightThemeId => LightThemes.defaultId;

  /// Get a theme by ID (works for both dark and light themes)
  static ThemeData? getTheme(String themeId) {
    return darkThemes[themeId] ?? lightThemes[themeId];
  }

  /// Get theme display name by ID
  static String getThemeName(String themeId) {
    return darkThemeNames[themeId] ?? lightThemeNames[themeId] ?? themeId;
  }

  /// Check if a theme ID is a dark theme
  static bool isDarkTheme(String themeId) {
    return darkThemes.containsKey(themeId);
  }

  /// Check if a theme ID is a light theme
  static bool isLightTheme(String themeId) {
    return lightThemes.containsKey(themeId);
  }

  /// Get themes for a specific brightness mode
  static Map<String, ThemeData> getThemesForBrightness(Brightness brightness) {
    return brightness == Brightness.dark ? darkThemes : lightThemes;
  }

  /// Get theme names for a specific brightness mode
  static Map<String, String> getThemeNamesForBrightness(Brightness brightness) {
    return brightness == Brightness.dark ? darkThemeNames : lightThemeNames;
  }

  /// Get the default theme ID for a brightness mode
  static String getDefaultThemeIdForBrightness(Brightness brightness) {
    return brightness == Brightness.dark
        ? defaultDarkThemeId
        : defaultLightThemeId;
  }

  /// Get theme preview color (primary seed color) for visual representation
  static Color getThemePreviewColor(String themeId) {
    final theme = getTheme(themeId);
    if (theme != null) {
      return theme.colorScheme.primary;
    }
    return Colors.deepPurple;
  }

  /// Get theme surface color for preview
  static Color getThemeSurfaceColor(String themeId) {
    final theme = getTheme(themeId);
    if (theme != null) {
      return theme.scaffoldBackgroundColor;
    }
    return Colors.grey;
  }
}
