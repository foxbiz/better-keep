import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_backend.dart';

/// Namespaces account-owned preferences without moving existing Live values.
///
/// Live keys intentionally remain unchanged. Emulator keys receive a stable
/// prefix, while global UI and Firebase chooser preferences stay unscoped.
class FirebaseScopedPreferences {
  FirebaseScopedPreferences._();

  /// Process-independent pointer used only by background local-data handlers.
  ///
  /// It never selects or configures Firebase. The foreground startup still
  /// requires an explicit backend choice and overwrites this marker after that
  /// choice is committed.
  static const activeScopePreferenceKey =
      'debug_firebase_active_local_data_scope';

  static String key(String legacyKey) {
    if (!FirebaseBackend.isConfigured) return legacyKey;
    return FirebaseBackend.localDataScope.preferenceKey(legacyKey);
  }

  static String keyForPreferences(
    String legacyKey,
    SharedPreferences preferences,
  ) => scopeForPreferences(preferences).preferenceKey(legacyKey);

  static FirebaseLocalDataScope scopeForPreferences(
    SharedPreferences preferences,
  ) {
    if (FirebaseBackend.isConfigured) return FirebaseBackend.localDataScope;
    return preferences.getString(activeScopePreferenceKey) ==
            FirebaseLocalDataScope.emulator.name
        ? FirebaseLocalDataScope.emulator
        : FirebaseLocalDataScope.live;
  }

  static Future<void> rememberActiveScope(SharedPreferences preferences) async {
    await preferences.setString(
      activeScopePreferenceKey,
      FirebaseBackend.localDataScope.name,
    );
  }

  static bool get isEmulator =>
      FirebaseBackend.isConfigured && FirebaseBackend.localDataScope.isEmulator;

  /// Clears only account data for the selected environment.
  static Future<void> clearActiveAccountPreferences(
    SharedPreferences preferences, {
    FirebaseLocalDataScope? scopeOverride,
  }) async {
    // Old builds persisted the selection itself. It must never influence the
    // every-launch chooser, regardless of which account scope signs out.
    await preferences.remove('debug_firebase_environment');
    await preferences.remove('debug_firebase_use_emulators');

    final keys = preferences.getKeys().toList(growable: false);
    final scope =
        scopeOverride ??
        (isEmulator
            ? FirebaseLocalDataScope.emulator
            : FirebaseLocalDataScope.live);
    if (scope.isEmulator) {
      const prefix = 'firebase_emulator.';
      for (final storedKey in keys.where((value) => value.startsWith(prefix))) {
        await preferences.remove(storedKey);
      }
      return;
    }

    for (final storedKey in keys.where(isLiveAccountKey)) {
      await preferences.remove(storedKey);
    }
  }

  static bool isLiveAccountKey(String value) {
    if (_liveExactKeys.contains(value)) return true;
    return _livePrefixes.any(value.startsWith);
  }

  static const Set<String> _liveExactKeys = {
    'alarm_id_map',
    'last_synced_user_id',
    'last_synced_at',
    'last_label_synced_at',
    'note_cloud_sync_checkpoint_v2',
    'label_cloud_sync_checkpoint_v2',
    'local_encryption_notes_enabled',
    'local_encryption_files_enabled',
    'pending_attachment_source_cleanup_v1',
    'pending_legacy_sketch_migrations_v1',
    'pending_new_attachment_transactions_v1',
    'pending_note_lock_removal_transactions_v1',
    'pending_note_lock_transactions_v1',
    'pending_reminder_navigation_note_id',
    'pending_reminder_navigation_created_at',
    'reminder_navigation_last_activation',
    'reminder_navigation_last_activation_at',
    'reminder_session_signed_in',
    'sketch_preview_renderer_version',
    'sketch_preview_renderer_v4_repair_progress',
    'sketch_preview_renderer_v2_unlocked_note_ids',
    'subscription_cache',
    'user_email',
    'user_displayName',
    'user_local_photo',
    'user_photoURL',
    'user_photoURL_downloaded',
    'user_uid',
  };

  static const List<String> _livePrefixes = [
    'share_expires_',
    'share_key_',
    'share_url_',
    'subscription_verified_entitlement_v2_',
  ];
}
