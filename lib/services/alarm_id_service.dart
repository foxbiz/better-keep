import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class AlarmIdService {
  static const String _storageKey = 'alarm_id_map';
  static Map<String, int> _alarmIdMap = {};

  /// Cached SharedPreferences instance for reuse
  static SharedPreferences? _prefs;

  /// Initialize with optional pre-loaded SharedPreferences for faster startup
  static Future<void> init({SharedPreferences? prefs}) async {
    _prefs = prefs ?? await SharedPreferences.getInstance();
    final String? storedMap = _prefs!.getString(_storageKey);
    if (storedMap != null) {
      try {
        _alarmIdMap = Map<String, int>.from(json.decode(storedMap));
      } catch (e) {
        _alarmIdMap = {};
      }
    }
  }

  static Future<int> getAlarmId(int noteId) async {
    final String key = noteId.toString();
    if (_alarmIdMap.containsKey(key)) {
      return _alarmIdMap[key]!;
    }

    int candidateId;
    final random = Random();
    do {
      // Generate a random 31-bit integer (positive int32)
      candidateId = random.nextInt(2147483647);
    } while (_alarmIdMap.containsValue(candidateId));

    _alarmIdMap[key] = candidateId;
    await _saveMap();
    return candidateId;
  }

  static Future<void> removeAlarmId(int noteId) async {
    final String key = noteId.toString();
    if (_alarmIdMap.containsKey(key)) {
      _alarmIdMap.remove(key);
      await _saveMap();
    }
  }

  static Future<void> _saveMap() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_storageKey, json.encode(_alarmIdMap));
  }
}
