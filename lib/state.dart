import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/themes/theme_registry.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

final _defaultState = {
  "db": null,
  "theme_id": ThemeRegistry.defaultDarkThemeId,
  "theme": ThemeRegistry.darkThemes[ThemeRegistry.defaultDarkThemeId],
  "follow_system_theme": false,
  "dark_theme_id": ThemeRegistry.defaultDarkThemeId,
  "light_theme_id": ThemeRegistry.defaultLightThemeId,
  "recent_colors": <Color>[],
  "show_notes": NoteType.all,
  "filter_labels": <String>[],
  "selected_notes": <Note>[],
  "alarm_sound": defaultAlarmSound,
  "last_synced_at": DateTime.fromMillisecondsSinceEpoch(0),
  "last_label_synced_at": DateTime.fromMillisecondsSinceEpoch(0),
  "scaffold_messenger_key": GlobalKey<ScaffoldMessengerState>(),
  "navigator_key": GlobalKey<NavigatorState>(),
  "morning_time": const TimeOfDay(hour: 6, minute: 0),
  "afternoon_time": const TimeOfDay(hour: 12, minute: 0),
  "evening_time": const TimeOfDay(hour: 18, minute: 0),
};

class AppState {
  static final Map<String, List<Function(Object?)>> _subscribers = {};
  static final Map<String, Object?> _state = Map.from(_defaultState);

  // Cached SharedPreferences instance for better performance
  static SharedPreferences? _prefs;

  /// Gets the cached SharedPreferences instance, initializing if needed
  static Future<SharedPreferences> get prefs async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Safely persist a value to SharedPreferences with error handling
  static void _persistToPrefs(
    Future<void> Function(SharedPreferences p) action,
  ) {
    prefs.then(action).catchError((e) {
      // Log error but don't crash - preference persistence is best-effort
      AppLogger.error('AppState: Failed to persist preference', e);
    });
  }

  static Future<void> reset() async {
    Database db = AppState.db;
    String themeId = AppState.themeId;
    String alarmSound = AppState.alarmSound;
    bool followSystemTheme = AppState.followSystemTheme;
    String darkThemeId = AppState.darkThemeId;
    String lightThemeId = AppState.lightThemeId;
    GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
        AppState.scaffoldMessengerKey;
    GlobalKey<NavigatorState> navigatorKey = AppState.navigatorKey;
    _state.clear();
    _state.addAll(_defaultState);
    _state["db"] = db;
    _state["theme_id"] = themeId;
    _state["theme"] =
        ThemeRegistry.getTheme(themeId) ??
        ThemeRegistry.darkThemes[ThemeRegistry.defaultDarkThemeId];
    _state["follow_system_theme"] = followSystemTheme;
    _state["dark_theme_id"] = darkThemeId;
    _state["light_theme_id"] = lightThemeId;
    _state["alarm_sound"] = alarmSound;
    _state["scaffold_messenger_key"] = scaffoldMessengerKey;
    _state["navigator_key"] = navigatorKey;
  }

  static Future<void> init({SharedPreferences? prefs}) async {
    // Use provided prefs or load fresh (caching for later use)
    _prefs = prefs ?? await SharedPreferences.getInstance();
    final prefsInstance = _prefs!;

    // Load theme settings
    final followSystemTheme =
        prefsInstance.getBool("follow_system_theme") ?? false;
    final darkThemeId =
        prefsInstance.getString("dark_theme_id") ??
        ThemeRegistry.defaultDarkThemeId;
    final lightThemeId =
        prefsInstance.getString("light_theme_id") ??
        ThemeRegistry.defaultLightThemeId;

    // Migrate from old theme_name if exists
    String themeId;
    final oldThemeName = prefsInstance.getString("theme_name");
    if (oldThemeName != null) {
      // Migrate old settings
      themeId = oldThemeName == "light"
          ? ThemeRegistry.defaultLightThemeId
          : ThemeRegistry.defaultDarkThemeId;
      prefsInstance.remove("theme_name");
      prefsInstance.setString("theme_id", themeId);
      prefsInstance.setString("dark_theme_id", darkThemeId);
      prefsInstance.setString("light_theme_id", lightThemeId);
    } else {
      themeId =
          prefsInstance.getString("theme_id") ??
          ThemeRegistry.defaultDarkThemeId;
    }

    // If following system theme, determine theme based on system brightness
    if (followSystemTheme) {
      final brightness =
          SchedulerBinding.instance.platformDispatcher.platformBrightness;
      themeId = brightness == Brightness.dark ? darkThemeId : lightThemeId;
    }

    var alarmSound =
        prefsInstance.getString("alarm_sound") ?? defaultAlarmSound;
    final lastSyncedAtString = prefsInstance.getString("last_synced_at");
    final lastLabelSyncedAtString = prefsInstance.getString(
      "last_label_synced_at",
    );
    final recentColors =
        prefsInstance
            .getStringList("recent_colors")
            ?.map((e) => Color(int.parse(e)))
            .toList() ??
        [
          Colors.black,
          Colors.white,
          Colors.red,
          Colors.blue,
          Colors.green,
          Colors.yellow,
        ].toList();

    if (alarmSound.startsWith("lib/")) {
      alarmSound = alarmSound.substring(4);
      prefsInstance.setString("alarm_sound", alarmSound);
    }

    _state["follow_system_theme"] = followSystemTheme;
    _state["dark_theme_id"] = darkThemeId;
    _state["light_theme_id"] = lightThemeId;
    _state["theme_id"] = themeId;
    _state["theme"] =
        ThemeRegistry.getTheme(themeId) ??
        ThemeRegistry.darkThemes[ThemeRegistry.defaultDarkThemeId];
    _state["alarm_sound"] = alarmSound;
    _state["recent_colors"] = recentColors;

    if (lastSyncedAtString != null) {
      _state["last_synced_at"] = DateTime.parse(lastSyncedAtString);
    }

    if (lastLabelSyncedAtString != null) {
      _state["last_label_synced_at"] = DateTime.parse(lastLabelSyncedAtString);
    }

    // Load time settings
    final morningHour = prefsInstance.getInt("morning_time_hour") ?? 6;
    final morningMinute = prefsInstance.getInt("morning_time_minute") ?? 0;
    final afternoonHour = prefsInstance.getInt("afternoon_time_hour") ?? 12;
    final afternoonMinute = prefsInstance.getInt("afternoon_time_minute") ?? 0;
    final eveningHour = prefsInstance.getInt("evening_time_hour") ?? 18;
    final eveningMinute = prefsInstance.getInt("evening_time_minute") ?? 0;

    _state["morning_time"] = TimeOfDay(
      hour: morningHour,
      minute: morningMinute,
    );
    _state["afternoon_time"] = TimeOfDay(
      hour: afternoonHour,
      minute: afternoonMinute,
    );
    _state["evening_time"] = TimeOfDay(
      hour: eveningHour,
      minute: eveningMinute,
    );

    // Load sync progress visibility setting
    _state["show_sync_progress"] =
        prefsInstance.getBool("show_sync_progress") ?? true;
  }

  static Object? get(String key) {
    return _state[key];
  }

  static void set(String key, Object? value) {
    _state[key] = value;
    notify(key, value);
  }

  static GlobalKey<ScaffoldMessengerState> get scaffoldMessengerKey {
    return _state["scaffold_messenger_key"]
        as GlobalKey<ScaffoldMessengerState>;
  }

  static set scaffoldMessengerKey(GlobalKey<ScaffoldMessengerState> key) {
    set("scaffold_messenger_key", key);
  }

  static GlobalKey<NavigatorState> get navigatorKey {
    return _state["navigator_key"] as GlobalKey<NavigatorState>;
  }

  static set navigatorKey(GlobalKey<NavigatorState> key) {
    set("navigator_key", key);
  }

  static ThemeData get theme {
    return _state["theme"] as ThemeData;
  }

  static String get themeId {
    return _state["theme_id"] as String;
  }

  static set themeId(String id) {
    set("theme_id", id);
    set(
      "theme",
      ThemeRegistry.getTheme(id) ??
          ThemeRegistry.darkThemes[ThemeRegistry.defaultDarkThemeId],
    );
    _persistToPrefs((p) async => p.setString("theme_id", id));
  }

  /// Whether the app is currently in dark mode
  static bool get isDarkMode {
    return ThemeRegistry.isDarkTheme(themeId);
  }

  /// Get/set whether to follow system theme
  static bool get followSystemTheme {
    return _state["follow_system_theme"] as bool? ?? false;
  }

  static set followSystemTheme(bool value) {
    set("follow_system_theme", value);
    _persistToPrefs((p) async => p.setBool("follow_system_theme", value));
    if (value) {
      // Apply system theme immediately when enabled
      // This only changes the current applied theme, not user's dark/light preference
      final brightness =
          SchedulerBinding.instance.platformDispatcher.platformBrightness;
      applySystemBrightness(brightness);
    }
  }

  /// The preferred dark theme ID
  static String get darkThemeId {
    return _state["dark_theme_id"] as String? ??
        ThemeRegistry.defaultDarkThemeId;
  }

  static set darkThemeId(String id) {
    set("dark_theme_id", id);
    _persistToPrefs((p) async => p.setString("dark_theme_id", id));
    // If currently in dark mode and following system or manually set to dark, apply
    if (isDarkMode ||
        (followSystemTheme &&
            SchedulerBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark)) {
      themeId = id;
    }
  }

  /// The preferred light theme ID
  static String get lightThemeId {
    return _state["light_theme_id"] as String? ??
        ThemeRegistry.defaultLightThemeId;
  }

  static set lightThemeId(String id) {
    set("light_theme_id", id);
    _persistToPrefs((p) async => p.setString("light_theme_id", id));
    // If currently in light mode and following system or manually set to light, apply
    if (!isDarkMode ||
        (followSystemTheme &&
            SchedulerBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.light)) {
      themeId = id;
    }
  }

  /// Apply the appropriate theme based on system brightness
  static void applySystemBrightness(Brightness brightness) {
    if (!followSystemTheme) return;
    final newThemeId = brightness == Brightness.dark
        ? darkThemeId
        : lightThemeId;
    themeId = newThemeId;
  }

  static String get alarmSound {
    return _state["alarm_sound"] as String;
  }

  static set alarmSound(String path) {
    set("alarm_sound", path);
    _persistToPrefs((p) async => p.setString("alarm_sound", path));
  }

  static bool get showSyncProgress {
    return _state["show_sync_progress"] as bool? ?? true;
  }

  static set showSyncProgress(bool value) {
    set("show_sync_progress", value);
    _persistToPrefs((p) async => p.setBool("show_sync_progress", value));
  }

  static List<Color> get recentColors {
    return _state["recent_colors"] as List<Color>;
  }

  static void addRecentColor(Color color) {
    final colors = recentColors;
    colors.remove(color);
    colors.insert(0, color);
    if (colors.length > 10) {
      colors.removeLast();
    }
    set("recent_colors", colors);
    _persistToPrefs(
      (p) async => p.setStringList(
        "recent_colors",
        colors.map((e) => e.toARGB32().toString()).toList(),
      ),
    );
  }

  static NoteType get showNotes {
    return _state["show_notes"] as NoteType;
  }

  static set showNotes(NoteType value) {
    set("show_notes", value);
  }

  static List<String> get filterLabels {
    return _state["filter_labels"] as List<String>;
  }

  static List<Note> get selectedNotes {
    return _state["selected_notes"] as List<Note>;
  }

  static set selectedNotes(List<Note> notes) {
    set("selected_notes", notes);
  }

  static set filterLabels(List<String> labels) {
    set("filter_labels", labels);
  }

  static Database get db {
    final database = _state["db"];
    if (database == null) {
      throw StateError(
        'Database not initialized. Ensure AppState.db is set during app startup.',
      );
    }
    return database as Database;
  }

  static set db(Database instance) {
    set("db", instance);
  }

  static DateTime? get lastSynced {
    return _state["last_synced_at"] as DateTime?;
  }

  static set lastSynced(DateTime? time) {
    set("last_synced_at", time);
    _persistToPrefs((p) async {
      if (time != null) {
        p.setString("last_synced_at", time.toIso8601String());
      } else {
        p.remove("last_synced_at");
      }
    });
  }

  static DateTime? get lastLabelSynced {
    return _state["last_label_synced_at"] as DateTime?;
  }

  static set lastLabelSynced(DateTime? time) {
    set("last_label_synced_at", time);
    _persistToPrefs((p) async {
      if (time != null) {
        p.setString("last_label_synced_at", time.toIso8601String());
      } else {
        p.remove("last_label_synced_at");
      }
    });
  }

  static TimeOfDay get morningTime {
    return _state["morning_time"] as TimeOfDay;
  }

  static set morningTime(TimeOfDay time) {
    set("morning_time", time);
    _persistToPrefs((p) async {
      p.setInt("morning_time_hour", time.hour);
      p.setInt("morning_time_minute", time.minute);
    });
  }

  static TimeOfDay get afternoonTime {
    return _state["afternoon_time"] as TimeOfDay;
  }

  static set afternoonTime(TimeOfDay time) {
    set("afternoon_time", time);
    _persistToPrefs((p) async {
      p.setInt("afternoon_time_hour", time.hour);
      p.setInt("afternoon_time_minute", time.minute);
    });
  }

  static TimeOfDay get eveningTime {
    return _state["evening_time"] as TimeOfDay;
  }

  static set eveningTime(TimeOfDay time) {
    set("evening_time", time);
    _persistToPrefs((p) async {
      p.setInt("evening_time_hour", time.hour);
      p.setInt("evening_time_minute", time.minute);
    });
  }

  static void subscribe(String key, void Function(dynamic) callback) {
    _subscribers.putIfAbsent(key, () => []).add(callback);
  }

  static void unsubscribe(String key, void Function(dynamic) callback) {
    if (_subscribers[key] == null) return;
    if (!_subscribers[key]!.contains(callback)) {
      return;
    }
    _subscribers[key]?.remove(callback);
  }

  static void notify(String key, Object? data) {
    List<Function(Object?)>? callbacks = List.from(_subscribers[key] ?? []);
    for (var callback in callbacks) {
      callback(data);
    }
  }
}
