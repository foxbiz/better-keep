import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_scoped_preferences.dart';
import 'storage_health_service.dart';

/// Records confirmed database recreation, independently of optional diagnostics.
class LocalStorageRecovery {
  LocalStorageRecovery(this.preferences);
  final SharedPreferences preferences;
  static final notice = ValueNotifier<String?>(null);
  static final Set<String> _pendingInMemory = {};
  static final Set<String> _completedInMemory = {};

  String _key(String name) => StorageHealthService.deviceKey(name, preferences);

  bool get pending =>
      !_completedInMemory.contains(_key('pending')) &&
      (_pendingInMemory.contains(_key('pending')) ||
          preferences.getBool(_key('pending')) == true);

  void loadNotice() => notice.value = preferences.getString(_key('notice'));

  bool get hasPreviousAccount =>
      preferences.getString(
            FirebaseScopedPreferences.keyForPreferences(
              'user_uid',
              preferences,
            ),
          ) !=
          null ||
      preferences.getString(
            FirebaseScopedPreferences.keyForPreferences(
              'last_synced_user_id',
              preferences,
            ),
          ) !=
          null;

  Future<void> databaseCreated() async {
    if (!hasPreviousAccount) return;
    _completedInMemory.remove(_key('pending'));
    _pendingInMemory.add(_key('pending'));
    final pressureAt = preferences.getInt(_key('pressure_at'));
    final age = pressureAt == null
        ? null
        : DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(pressureAt),
          );
    final underPressure =
        StorageHealthService.instance.isLow ||
        (age != null && !age.isNegative && age < const Duration(hours: 24));
    notice.value = underPressure ? 'pressure' : 'cleared';
    // This is deliberately best effort: inability to store an explanation
    // must not prevent logout after confirmed data loss.
    try {
      await preferences.setBool(_key('pending'), true);
      await preferences.setString(_key('notice'), notice.value!);
    } catch (_) {}
  }

  Future<void> completeLogout() async {
    // Even if persistence fails, don't repeatedly log out in this process.
    // A surviving marker is retried at the next launch.
    _pendingInMemory.remove(_key('pending'));
    _completedInMemory.add(_key('pending'));
    if (!await preferences.remove(_key('pending'))) {
      throw StateError('Could not finish local storage cleanup');
    }
  }

  Future<void> dismissNotice() async {
    notice.value = null;
    try {
      await preferences.remove(_key('notice'));
    } catch (_) {}
  }
}
