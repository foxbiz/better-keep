import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_scoped_preferences.dart';
import 'file_system.dart'
    show canResumeFileRotation, currentAccountFileGeneration;
import 'storage_health_service.dart';

typedef SignOutSnapshot = ({String? library, String? journal, String? owner});

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

  bool get signOutPending => preferences.containsKey(_key('sign_out_pending'));

  SignOutSnapshot get signOutSnapshot {
    String? storedString(String key) {
      final value = preferences.get(key);
      return value is String ? value : null;
    }

    return (
      library: currentAccountFileGeneration(preferences),
      journal: storedString(_key('sign_out_pending')),
      owner: storedString(
        FirebaseScopedPreferences.keyForPreferences('user_uid', preferences),
      ),
    );
  }

  bool canContinueSignOut(SignOutSnapshot confirmed, {String? ownJournal}) {
    final current = signOutSnapshot;
    // The owner and library can change during our own interrupted cleanup.
    // Only that same, still-pending journal authorizes finishing it.
    return ownJournal == null
        ? current == confirmed
        : current.journal == ownJournal;
  }

  Future<String> beginSignOut() async {
    final key = _key('sign_out_pending');
    final existing = preferences.get(key);
    final id =
        existing is String && canResumeFileRotation(preferences, existing)
        ? existing
        : const Uuid().v4();
    if (!await preferences.setString(key, id)) {
      throw StateError('Could not record pending sign-out');
    }
    return id;
  }

  Future<void> finishSignOut() async {
    if (!await preferences.remove(_key('sign_out_pending'))) {
      throw StateError('Could not finish pending sign-out');
    }
  }

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
