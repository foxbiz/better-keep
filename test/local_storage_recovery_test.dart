import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/storage_health_service.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingRemovalStore extends InMemorySharedPreferencesStore {
  _FailingRemovalStore() : super.withData({});

  @override
  Future<bool> remove(String key) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
