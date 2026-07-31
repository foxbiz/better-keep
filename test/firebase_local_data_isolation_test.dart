import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> preferences(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('Live sign-out preserves global and Emulator preferences', () async {
    final prefs = await preferences({
      'theme_mode': 'dark',
      'debug_firebase_emulator_host': '192.168.1.25',
      'user_uid': 'live-user',
      'subscription_cache': '{}',
      'last_synced_at': '2026-07-29T00:00:00.000Z',
      'share_key_live-share': 'secret',
      'firebase_emulator.user_uid': 'emulator-user',
      'firebase_emulator.subscription_cache': '{}',
      'firebase_emulator.last_synced_at': '2026-07-28T00:00:00.000Z',
    });

    await FirebaseScopedPreferences.clearActiveAccountPreferences(
      prefs,
      scopeOverride: FirebaseLocalDataScope.live,
    );

    expect(prefs.getString('theme_mode'), 'dark');
    expect(prefs.getString('debug_firebase_emulator_host'), '192.168.1.25');
    expect(prefs.getString('user_uid'), isNull);
    expect(prefs.getString('subscription_cache'), isNull);
    expect(prefs.getString('last_synced_at'), isNull);
    expect(prefs.getString('share_key_live-share'), isNull);
    expect(prefs.getString('firebase_emulator.user_uid'), 'emulator-user');
    expect(prefs.getString('firebase_emulator.subscription_cache'), '{}');
    expect(
      prefs.getString('firebase_emulator.last_synced_at'),
      '2026-07-28T00:00:00.000Z',
    );
  });

  test('Emulator sign-out clears only its namespace', () async {
    final prefs = await preferences({
      'follow_system_theme': true,
      'user_uid': 'live-user',
      'subscription_cache': '{}',
      'last_synced_at': '2026-07-29T00:00:00.000Z',
      'firebase_emulator.user_uid': 'emulator-user',
      'firebase_emulator.subscription_cache': '{}',
      'firebase_emulator.last_synced_at': '2026-07-28T00:00:00.000Z',
      'firebase_emulator.share_key_emulator-share': 'secret',
    });

    await FirebaseScopedPreferences.clearActiveAccountPreferences(
      prefs,
      scopeOverride: FirebaseLocalDataScope.emulator,
    );

    expect(prefs.getBool('follow_system_theme'), isTrue);
    expect(prefs.getString('user_uid'), 'live-user');
    expect(prefs.getString('subscription_cache'), '{}');
    expect(prefs.getString('last_synced_at'), '2026-07-29T00:00:00.000Z');
    expect(prefs.getString('firebase_emulator.user_uid'), isNull);
    expect(prefs.getString('firebase_emulator.subscription_cache'), isNull);
    expect(prefs.getString('firebase_emulator.last_synced_at'), isNull);
    expect(
      prefs.getString('firebase_emulator.share_key_emulator-share'),
      isNull,
    );
  });

  test('environment-scoped keys never collide', () {
    for (final key in [
      'user_uid',
      'subscription_cache',
      'pending_note_lock_transactions_v1',
      'share_key_abc',
    ]) {
      expect(
        FirebaseLocalDataScope.live.preferenceKey(key),
        isNot(FirebaseLocalDataScope.emulator.preferenceKey(key)),
      );
    }
  });

  test(
    'background local-data handlers reuse the last committed scope',
    () async {
      final prefs = await preferences({
        FirebaseScopedPreferences.activeScopePreferenceKey: 'emulator',
        'reminder_session_signed_in': true,
        'firebase_emulator.reminder_session_signed_in': false,
      });

      expect(
        FirebaseScopedPreferences.keyForPreferences(
          'reminder_session_signed_in',
          prefs,
        ),
        'firebase_emulator.reminder_session_signed_in',
      );
      expect(await activeDatabasePath(), 'better_keep_emulator.db');
    },
  );

  test('scoped encryption preference cache resets between accounts', () {
    LocalDataEncryption.primeScopedPreferenceCacheForTesting(
      notesEnabled: true,
      filesEnabled: false,
    );

    LocalDataEncryption.resetScopedPreferenceCache();

    expect(LocalDataEncryption.scopedPreferenceCacheForTesting, (null, null));
  });

  test('alarm initialization cannot retain a previous account map', () async {
    final first = await preferences({'alarm_id_map': '{"1":101,"2":202}'});
    await AlarmIdService.init(prefs: first);
    expect(AlarmIdService.alarmIdMapForTesting, {'1': 101, '2': 202});

    final second = await preferences({});
    await AlarmIdService.resetForScopeChange(prefs: second);

    expect(AlarmIdService.alarmIdMapForTesting, isEmpty);
  });
}
