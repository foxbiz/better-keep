import 'package:better_keep/services/e2ee/recovery_key.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'dart:async';
import 'dart:convert';

import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late OfflineFirebase backend;
  late _KeyStorage storage;
  late Database database;
  final e2ee = E2EEService.instance;

  setUp(() async {
    backend = OfflineFirebase()..configure();
    PackageInfo.setMockInitialValues(
      appName: 'Offline Test',
      packageName: 'test.offline',
      version: '1.3.3',
      buildNumber: '84',
      buildSignature: 'test',
    );
    storage = _KeyStorage({
      'e2ee_device_private_key': base64Encode(List.filled(32, 1)),
      'e2ee_device_public_key': base64Encode(List.filled(32, 2)),
      'e2ee_device_id': 'device-a',
      'e2ee_umk_cache': base64Encode(List.filled(32, 3)),
      'e2ee_device_status': 'approved',
    });
    FlutterSecureStoragePlatform.instance = storage;
    SharedPreferences.setMockInitialValues({
      'user_uid': 'account-a',
      'user_email': 'account-a@example.invalid',
    });
    final preferences = await SharedPreferences.getInstance();
    await AppState.init(prefs: preferences);
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await Note.createTable(database);
    await RemoteContentRetryLedger.createTable(database);
    await Label.createTable(database);
    await NoteSyncTrack.createTable(database);
    await LabelSyncTrack.createTable(database);
    e2ee.resetInitialization();
    e2ee.status.value = E2EEStatus.notInitialized;
    e2ee.deviceManager.setCachedUMKForTesting(null);
    AuthService.sessionInvalid.value = false;
    AuthService.cloudRecovery.stop();
    AuthService.setAppForeground(false);
    await AuthService.init(prefs: preferences);
  });

  tearDown(() async {
    Note.syncTriggerOverride = null;
    AuthService.cloudRecovery.stop();
    await e2ee.deviceManager.dispose();
    e2ee.resetInitialization();
    await NoteSyncService().dispose();
    await LabelSyncService().dispose();
    PlanService.instance.dispose();
    await backend.auth.changes.close();
    await database.close();
    FirebaseBackend.resetForTesting();
  });

  void allowPaidSync() {
    PlanService.instance.activateReviewSession(
      ReviewAuthorization.fromClaims(
        uid: 'account-a',
        claims: {
          'plan': 'pro',
          'planExpiresAt': DateTime.utc(2100).millisecondsSinceEpoch,
        },
      ),
    );
    AuthService.cloudRecovery.state.value = CloudSessionState.ready;
  }

  test(
    'returning startup opens local Home before a forced token refresh fails',
    () async {
      final user = backend.auth.currentUser! as OfflineUser;
      final keysBefore = Map.of(storage.data);
      expect(await e2ee.preloadCachedStatus(), isTrue);
      expect(user.tokenRequests, 0);
      expect(e2ee.isCryptoReady, isTrue);
      await AuthService.initializeCurrentUserServices();
      await AuthService.cloudRecovery.check();
      expect(AuthService.sessionInvalid.value, isFalse);
      expect(
        AuthService.cloudRecovery.state.value,
        CloudSessionState.unavailable,
      );
      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: AuthService.postSignInState.value,
          e2eeStatus: e2ee.status.value,
        ),
        AuthenticatedStartupRoute.home,
      );
      expect(e2ee.isVerifyingInBackground.value, isFalse);
      expect(storage.data, keysBefore);
      expect(backend.firestore.writes, isEmpty);
    },
  );

  test(
    'delayed authentication restoration reopens local Home without invalidation',
    () async {
      backend.auth.currentUser = null;
      backend.auth.changes.add(null);
      await pumpEventQueue();
      expect(AuthService.sessionInvalid.value, isFalse);
      backend.auth.currentUser = OfflineUser('account-a');
      backend.auth.changes.add(backend.auth.currentUser);
      await pumpEventQueue(times: 40);
      expect(AuthService.sessionInvalid.value, isFalse);
      expect(e2ee.isCryptoReady, isTrue);
      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: AuthService.postSignInState.value,
          e2eeStatus: e2ee.status.value,
        ),
        AuthenticatedStartupRoute.home,
      );
    },
  );

  test(
    'valid refreshed token with unavailable Firestore still keeps Home',
    () async {
      (backend.auth.currentUser! as OfflineUser).tokenResponse = () async =>
          OfflineToken();
      await AuthService.initializeCurrentUserServices();
      await AuthService.cloudRecovery.check();
      expect(
        AuthService.cloudRecovery.state.value,
        CloudSessionState.unavailable,
      );
      expect(e2ee.isCryptoReady, isTrue);
      expect(AuthService.sessionInvalid.value, isFalse);
      expect(storage.deletes, 0);
    },
  );

  testWidgets('slow Firebase times out while local keys and Home stay ready', (
    tester,
  ) async {
    final token = Completer<IdTokenResult>();
    (backend.auth.currentUser! as OfflineUser).tokenResponse = () =>
        token.future;
    await e2ee.preloadCachedStatus();
    await AuthService.initializeCurrentUserServices();
    await tester.pump(const Duration(seconds: 10));
    expect(
      AuthService.cloudRecovery.state.value,
      CloudSessionState.unavailable,
    );
    expect(e2ee.status.value, E2EEStatus.ready);
    token.complete(OfflineToken());
    await tester.pump();
    expect(backend.firestore.reads, isEmpty);
    expect(AuthService.sessionInvalid.value, isFalse);
  });

  test(
    'secure-storage errors and corrupt keys cannot register replacements',
    () async {
      for (final corrupt in [false, true]) {
        storage.failReads = !corrupt;
        if (corrupt) storage.data['e2ee_device_private_key'] = 'invalid-key';
        final before = Map.of(storage.data);
        e2ee.resetInitialization();
        expect(await e2ee.preloadCachedStatus(), isFalse);
        expect(
          e2ee.localState,
          corrupt
              ? LocalEncryptionState.corrupt
              : LocalEncryptionState.unavailable,
        );
        await expectLater(
          e2ee.initialize(),
          throwsA(
            anyOf(isA<SecureStorageUnavailable>(), isA<FormatException>()),
          ),
        );
        expect(storage.data, before);
        expect(storage.deletes, 0);
        expect(backend.firestore.writes, isEmpty);
      }
    },
  );

  test(
    'cached revocation survives offline startup and interrupted sign-in',
    () async {
      storage.data['e2ee_device_status'] = 'revoked';
      storage.data['e2ee_sign_in_progress'] = 'true';
      expect(await e2ee.preloadCachedStatus(), isFalse);
      await AuthService.initializeCurrentUserServices();
      await AuthService.cloudRecovery.check();
      expect(e2ee.status.value, E2EEStatus.revoked);
      expect(storage.data['e2ee_device_status'], 'revoked');
      expect(storage.deletes, 0);
    },
  );

  test(
    'cache-only absence preserves keys; confirmed server deletion restricts access',
    () async {
      await e2ee.preloadCachedStatus();
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(cached: true);
      expect(
        await e2ee.verifyLocalSessionAuthorization(),
        DeviceAuthorization.unavailable,
      );
      expect(e2ee.isCryptoReady, isTrue);
      expect(storage.deletes, 0);
      backend.firestore.response = (_, _) async => OfflineSnapshot();
      expect(
        await e2ee.verifyLocalSessionAuthorization(),
        DeviceAuthorization.deleted,
      );
      expect(e2ee.status.value, E2EEStatus.needsRecovery);
      expect(storage.data['e2ee_device_private_key'], isNotNull);
      expect(storage.data['e2ee_umk_cache'], isNull);
      expect(
        backend.firestore.reads.every((read) => read.$2 == Source.server),
        isTrue,
      );
    },
  );

  test('late server deletion cannot clear the next session keys', () async {
    await e2ee.preloadCachedStatus();
    final response = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    backend.firestore.response = (_, _) => response.future;
    final old = e2ee.verifyLocalSessionAuthorization();
    await pumpEventQueue();
    e2ee.resetInitialization();
    backend.auth.currentUser = OfflineUser('account-b');
    final before = Map.of(storage.data);
    response.complete(OfflineSnapshot());
    expect(await old, DeviceAuthorization.unavailable);
    expect(storage.data, before);
    expect(storage.deletes, 0);
  });

  test(
    'failed passphrase recovery preserves the existing keys and identity',
    () async {
      await e2ee.preloadCachedStatus();
      Map<String, dynamic>? recovery;
      backend.firestore.write = (path, data) async {
        if (path.endsWith('/recovery_key')) recovery = Map.of(data);
      };
      await RecoveryKeyService.instance.createRecoveryKey(
        'synthetic offline recovery phrase',
      );
      final before = Map.of(storage.data);
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(value: recovery);
      backend.firestore.write = (_, _) async =>
          throw TimeoutException('Offline during recovery');
      await expectLater(
        RecoveryKeyService.instance.recoverWithPassphrase(
          'synthetic offline recovery phrase',
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(storage.data, before);
      expect(storage.deletes, 0);
      expect(backend.firestore.writes.last, endsWith('/devices/device-a'));
    },
  );

  test(
    'a failed first registration retries with the persisted keys and device ID',
    () async {
      storage.data.clear();
      backend.firestore.write = (_, _) async =>
          throw TimeoutException('Offline');
      await expectLater(
        e2ee.deviceManager.registerFirstDevice(),
        throwsA(isA<TimeoutException>()),
      );
      final pendingKeys = Map.of(storage.data);
      expect(pendingKeys['e2ee_device_private_key'], isNotNull);
      expect(pendingKeys['e2ee_umk_cache'], isNotNull);
      expect(pendingKeys['e2ee_device_status'], isNull);
      expect(e2ee.isCryptoReady, isFalse);
      backend.firestore.write = null;
      await e2ee.deviceManager.registerFirstDevice();
      expect(storage.data, pendingKeys);
      expect(backend.firestore.writes.toSet().length, 1);
      expect(storage.deletes, 0);
    },
  );

  test('note service can retry a partially failed initialization', () async {
    final cache = _InitializingCache();
    NoteSyncService.remoteCacheOverride = cache;
    try {
      await expectLater(NoteSyncService().init(), throwsStateError);
      expect(cache.attempts, 1);
      cache.unavailable = false;
      await NoteSyncService().init();
      expect(cache.attempts, 2);
      await NoteSyncService().init();
      expect(cache.attempts, 2);
    } finally {
      await NoteSyncService().dispose();
      NoteSyncService.remoteCacheOverride = null;
    }
  });

  test(
    'missing local master key does not register a replacement offline',
    () async {
      storage.data.remove('e2ee_umk_cache');
      final before = Map.of(storage.data);
      expect(await e2ee.preloadCachedStatus(), isFalse);
      expect(e2ee.localState, LocalEncryptionState.missing);
      await expectLater(e2ee.initialize(), throwsA(isA<FirebaseException>()));
      expect(storage.data, before);
      expect(backend.firestore.writes, isEmpty);
      expect(storage.deletes, 0);
    },
  );

  test(
    'a different account cannot restore the previous account master key',
    () async {
      backend.auth.currentUser = OfflineUser('account-b');
      final before = Map.of(storage.data);
      expect(await e2ee.preloadCachedStatus(), isFalse);
      expect(e2ee.isCryptoReady, isFalse);
      await expectLater(e2ee.initialize(), throwsStateError);
      expect(storage.data, before);
      expect(backend.firestore.writes, isEmpty);
    },
  );

  test(
    'approval resumes the stored key and preserves its device identity',
    () async {
      storage.data['e2ee_device_status'] = 'pending';
      expect(await e2ee.preloadCachedStatus(), isFalse);
      expect(e2ee.status.value, E2EEStatus.pendingApproval);
      backend.firestore.response = (_, _) async => OfflineSnapshot(
        value: {
          'status': 'approved',
          'public_key': storage.data['e2ee_device_public_key'],
          'created_at': '2026-01-01T00:00:00.000Z',
        },
      );
      final privateKey = storage.data['e2ee_device_private_key'];
      expect(
        await e2ee.verifyLocalSessionAuthorization(),
        DeviceAuthorization.approved,
      );
      expect(e2ee.isCryptoReady, isTrue);
      expect(storage.data['e2ee_device_status'], 'approved');
      expect(storage.data['e2ee_device_id'], 'device-a');
      expect(storage.data['e2ee_device_private_key'], privateKey);
      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: AuthService.postSignInState.value,
          e2eeStatus: e2ee.status.value,
        ),
        AuthenticatedStartupRoute.home,
      );
    },
  );

  test(
    'reconnect while an old upload finishes retains a newer local edit',
    () async {
      await e2ee.preloadCachedStatus();
      allowPaidSync();
      final note = Note(
        id: 710,
        title: 'Before',
        content: '[{"insert":"text\\n"}]',
        plainText: 'text',
      );
      Note.syncTriggerOverride = () {};
      await note.save();
      final began = Completer<void>();
      final upload = Completer<void>();
      backend.firestore.commit = () {
        began.complete();
        return upload.future;
      };
      final refreshing = NoteSyncService().refreshWithOutcome();
      await began.future.timeout(const Duration(seconds: 5));
      AuthService.cloudRecovery.connectionLost();
      note.title = 'New offline edit';
      await note.save();
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      upload.complete();
      await refreshing;
      final pending = await NoteSyncTrack.getByLocalId(note.id!);
      expect(pending?.status, SyncStatus.pending);
      expect((await Note.findById(note.id!))?.title, 'New offline edit');
      Note.syncTriggerOverride = null;
    },
  );

  test(
    'note and label deletion queues survive a nonauthoritative remote miss',
    () async {
      await e2ee.preloadCachedStatus();
      PlanService.instance.activateReviewSession(
        ReviewAuthorization.fromClaims(
          uid: 'account-a',
          claims: {
            'plan': 'pro',
            'planExpiresAt': DateTime.utc(2100).millisecondsSinceEpoch,
          },
        ),
      );
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(cached: true);
      await NoteSyncTrack(
        localId: 101,
        remoteId: 'remote-note',
        action: SyncAction.delete,
      ).save();
      await LabelSyncTrack(
        localId: 202,
        remoteId: 'remote-label',
        action: LabelSyncAction.delete,
      ).save();
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      expect(
        await NoteSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.unavailable,
      );
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      expect(
        await LabelSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.unavailable,
      );
      expect(
        (await NoteSyncTrack.getByLocalId(101))?.action,
        SyncAction.delete,
      );
      expect(
        (await LabelSyncTrack.getByLocalId(202))?.action,
        LabelSyncAction.delete,
      );
      expect(NoteSyncService().isSyncing.value, isFalse);
      expect(LabelSyncService().isSyncing.value, isFalse);
      expect(backend.firestore.writes, isEmpty);
    },
  );
}

class _KeyStorage extends TestFlutterSecureStoragePlatform {
  _KeyStorage(super.data);
  bool failReads = false;
  int deletes = 0;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) {
    if (failReads) throw PlatformException(code: 'keychain-unavailable');
    return super.read(key: key, options: options);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) {
    deletes++;
    return super.delete(key: key, options: options);
  }
}

class _InitializingCache extends RemoteSyncCacheService {
  _InitializingCache() : super.forTesting(() => throw UnimplementedError());
  bool unavailable = true;
  int attempts = 0;
  @override
  Future<void> init() async {
    attempts++;
    if (unavailable) throw StateError('Local cache unavailable');
  }
}
