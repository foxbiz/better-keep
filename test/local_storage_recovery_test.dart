import 'dart:async';

import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/storage_health_service.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _StalledSettingStore extends InMemorySharedPreferencesStore {
  _StalledSettingStore() : super.withData({});
  final unblock = Completer<void>();
  final entered = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.table_headers' && !entered.isCompleted) {
      entered.complete();
      await unblock.future;
    }
    return super.setValue(valueType, key, value);
  }
}

class _FailingRemovalStore extends InMemorySharedPreferencesStore {
  _FailingRemovalStore() : super.withData({});

  bool fail = true;
  @override
  Future<bool> remove(String key) async =>
      fail && (key == 'flutter.user_uid' || key.endsWith('.pending'))
      ? false
      : super.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a completed or replaced sign-out cannot authorize deleting the next library', () async {
    SharedPreferences.setMockInitialValues({'user_uid': 'old-owner'});
    final prefs = await SharedPreferences.getInstance();
    final recovery = LocalStorageRecovery(prefs);
    final confirmed = recovery.signOutSnapshot;
    expect(recovery.canContinueSignOut(confirmed), true);
    final id = await recovery.beginSignOut();
    expect(recovery.canContinueSignOut(confirmed), false);
    await prefs.setString('account_files.live.active', id);
    await prefs.remove('user_uid');
    expect(recovery.canContinueSignOut(confirmed, ownJournal: id), true);
    await recovery.finishSignOut();
    expect(recovery.canContinueSignOut(confirmed, ownJournal: id), false);
    expect(recovery.canContinueSignOut(confirmed), false);
    await recovery.beginSignOut();
    expect(recovery.canContinueSignOut(confirmed, ownJournal: id), false);
  });

  test(
    'a damaged rotation journal is repaired once and survives retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final recovery = LocalStorageRecovery(prefs);
      final key = StorageHealthService.deviceKey('sign_out_pending', prefs);
      const retired = '00000000-0000-4000-8000-000000000001';
      await prefs.setBool('account_files.live.retired.$retired', false);
      for (final invalid in ['../invalid', retired]) {
        await prefs.setString(key, invalid);
        final replacement = await recovery.beginSignOut();
        expect(replacement, isNot(invalid));
        await prefs.reload();
        expect(await recovery.beginSignOut(), replacement);
        expect(prefs.getBool('account_files.live.retired.$retired'), isFalse);
      }
    },
  );

  test(
    'a stalled device setting cannot block sign-out or other settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await AppState.init(prefs: prefs);
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _StalledSettingStore();
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      await prefs.setString('user_uid', 'departing');
      AppState.tableHeaders = true;
      await store.entered.future;
      await AppState.clearSignOutPreferences(
        timeout: const Duration(seconds: 2),
      );
      expect(prefs.getString('user_uid'), isNull);
      AppState.tableHeaders = true;
      AppState.tableHeaders = false;
      final otherSetting = !AppState.matchAllLabels;
      AppState.matchAllLabels = otherSetting;
      await pumpEventQueue();
      expect(prefs.getBool('match_all_labels'), otherSetting);
      store.unblock.complete();
      await pumpEventQueue();
      await prefs.reload();

      expect(prefs.getBool('table_headers'), false);
      expect(prefs.getString('user_uid'), isNull);
    },
  );

  test(
    'failed durable cleanup does not repeat logout in the same process',
    () async {
      SharedPreferences.setMockInitialValues({'user_uid': 'old-account'});
      final prefs = await SharedPreferences.getInstance();
      final previousStore = SharedPreferencesStorePlatform.instance;
      addTearDown(
        () => SharedPreferencesStorePlatform.instance = previousStore,
      );
      SharedPreferencesStorePlatform.instance = _FailingRemovalStore();
      final recovery = LocalStorageRecovery(prefs);
      await recovery.databaseCreated();
      expect(recovery.pending, true);
      await expectLater(recovery.completeLogout(), throwsStateError);
      await prefs.reload();
      expect(
        prefs.getBool(StorageHealthService.deviceKey('pending', prefs)),
        true,
      );
      expect(recovery.pending, false);

      // A later, separate loss must still be detected in this process.
      await prefs.setString('user_uid', 'old-account');
      await recovery.databaseCreated();
      expect(recovery.pending, true);
      SharedPreferencesStorePlatform.instance = previousStore;
      await recovery.completeLogout();
    },
  );

  test(
    'retry enumerates persisted account preferences after a failed removal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final previous = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
      final store = _FailingRemovalStore();
      SharedPreferencesStorePlatform.instance = store;
      await prefs.setString('user_uid', 'old');
      await expectLater(
        FirebaseScopedPreferences.clearActiveAccountPreferences(prefs),
        throwsStateError,
      );
      expect(prefs.containsKey('user_uid'), isFalse);
      store.fail = false;
      await FirebaseScopedPreferences.clearActiveAccountPreferences(prefs);
      await prefs.reload();
      expect(prefs.containsKey('user_uid'), isFalse);
    },
  );

  test(
    'first installation does not request logout or claim data loss',
    () async {
      SharedPreferences.setMockInitialValues({});
      final recovery = LocalStorageRecovery(
        await SharedPreferences.getInstance(),
      );
      recovery.loadNotice();
      await recovery.databaseCreated();
      expect(recovery.pending, false);
      expect(LocalStorageRecovery.notice.value, null);
    },
  );

  test('confirmed recreation retains reason through complete account cleanup', () async {
    SharedPreferences.setMockInitialValues({'user_uid': 'old-account'});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      StorageHealthService.deviceKey('pressure_at', prefs),
      DateTime.now().millisecondsSinceEpoch,
    );
    final recovery = LocalStorageRecovery(prefs);
    await recovery.databaseCreated();
    expect(recovery.pending, true);
    expect(LocalStorageRecovery.notice.value, 'pressure');
    await FirebaseScopedPreferences.clearActiveAccountPreferences(prefs);
    final restarted = LocalStorageRecovery(prefs)..loadNotice();
    expect(restarted.pending, true);
    expect(LocalStorageRecovery.notice.value, 'pressure');
    await restarted.completeLogout();
    expect(restarted.pending, false);
    // Logout's intentional database recreation must not trigger another logout.
    await restarted.databaseCreated();
    expect(restarted.pending, false);
    expect(LocalStorageRecovery.notice.value, 'pressure');
    await restarted.dismissNotice();
    restarted.loadNotice();
    expect(LocalStorageRecovery.notice.value, null);
  });

  test(
    'old pressure does not become a false explanation for cleared data',
    () async {
      SharedPreferences.setMockInitialValues({'user_uid': 'old-account'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        StorageHealthService.deviceKey('pressure_at', prefs),
        1,
      );
      final recovery = LocalStorageRecovery(prefs);
      await recovery.databaseCreated();
      expect(LocalStorageRecovery.notice.value, 'cleared');
      await recovery.completeLogout();
    },
  );

  test(
    'successful note and label restoration clears the retained notice',
    () async {
      SharedPreferences.setMockInitialValues({'user_uid': 'same-account'});
      final prefs = await SharedPreferences.getInstance();
      await AppState.init(prefs: prefs);
      await AppState.clearSyncCheckpoints();
      final recovery = LocalStorageRecovery(prefs);
      await recovery.databaseCreated();
      await recovery.completeLogout();
      AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      await pumpEventQueue();
      expect(LocalStorageRecovery.notice.value, 'cleared');
      AppState.labelCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      await pumpEventQueue();
      recovery.loadNotice();
      expect(LocalStorageRecovery.notice.value, null);
    },
  );

  test(
    'reset drains queued checkpoints and preserves unrelated preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'user_uid': 'same-account',
        'theme_id': 'test',
      });
      final prefs = await SharedPreferences.getInstance();
      await AppState.init(prefs: prefs);
      AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      AppState.labelCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      AppState.lastSynced = DateTime.now();
      AppState.lastLabelSynced = DateTime.now();
      await AppState.clearSyncCheckpoints();
      await prefs.reload();
      expect(AppState.noteCloudSyncCheckpoint, null);
      expect(AppState.labelCloudSyncCheckpoint, null);
      expect(prefs.containsKey('last_synced_at'), false);
      expect(prefs.getString('user_uid'), 'same-account');
      expect(prefs.getString('theme_id'), 'test');
    },
  );
}
