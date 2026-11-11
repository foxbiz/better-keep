import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:better_keep/services/local_notification_service.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/file_system_io.dart';
import 'package:better_keep/services/scoped_file_system.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/offline_firebase.dart';

class _SignOutAuth extends OfflineAuth {
  int signOuts = 0;
  int failures = 0;
  @override
  Future<void> signOut() async {
    signOuts++;
    if (signOuts <= failures) throw StateError('temporary sign-out failure');
    currentUser = null;
    changes.add(null);
  }
}

class _SignOutFirestore extends OfflineFirestore {
  Completer<void>? pendingWrites;

  @override
  Future<void> waitForPendingWrites() =>
      pendingWrites?.future ?? Future.value();
}

class _BlockedKeyStore extends TestFlutterSecureStoragePlatform {
  _BlockedKeyStore() : super({});
  final unblock = Completer<void>();
  int inFlight = 0;
  int maxInFlight = 0;
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await unblock.future;
      await super.delete(key: key, options: options);
    } finally {
      inFlight--;
    }
  }
}

class _StalledCheckpointStore extends InMemorySharedPreferencesStore {
  _StalledCheckpointStore() : super.withData({'flutter.user_uid': 'account-a'});
  final unblock = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('.note_cloud_sync_checkpoint_v2')) await unblock.future;
    return super.setValue(valueType, key, value);
  }
}

class _CountingPreferences extends Fake implements SharedPreferences {
  final data = <String, Object>{};
  int scans = 0;
  @override
  Object? get(String key) => data[key];
  @override
  bool containsKey(String key) => data.containsKey(key);
  @override
  Set<String> getKeys() {
    scans++;
    return data.keys.toSet();
  }

  @override
  Future<void> reload() async {}
}

class _FixtureFiles extends IoFileSystem {
  _FixtureFiles(this.root);
  final String root;
  @override
  Future<String> get documentDir async => root;
  @override
  Future<String> get cacheDir async => root;
}

enum _Scenario {
  normal,
  notificationUnavailable,
  stalledNotification,
  transientAuth,
  persistentAuth,
  stalledKey,
  stalledCheckpoint,
  slowFirestore,
  startup,
  damagedDirectory,
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'desktop logout rejects a surviving database or SQLite sidecar',
    () async {
      final root = await Directory.systemTemp.createTemp('logout-database-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/fixture.db';
      final database = await openDatabase(path);
      await database.close();
      await expectLater(verifySignedOutDatabaseRemoved(path), throwsStateError);
      await deleteSignedOutDatabase(path);
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final survivor = File('$path$suffix');
        await survivor.writeAsBytes([1]);
        await expectLater(
          verifySignedOutDatabaseRemoved(path),
          throwsStateError,
        );
        await survivor.delete();
      }
      await verifySignedOutDatabaseRemoved(path);
    },
  );

  test('interrupted cleanup resumes across two sign-outs without touching the active library', () async {
    final root = await Directory.systemTemp.createTemp('retired-library-');
    addTearDown(() => root.delete(recursive: true));
    final fs = _FixtureFiles(root.path);
    SharedPreferences.setMockInitialValues({
      'account_files.fixture.retired.legacy': true,
    });
    final prefs = await SharedPreferences.getInstance();
    final blocked = Completer<FileSystem>();
    final cleanup = AccountFileCleanup('fixture', () => blocked.future);
    const first = '00000000-0000-4000-8000-000000000001';
    const second = '00000000-0000-4000-8000-000000000002';
    final oldPath = '${root.path}/external_sync_media/file';
    await fs.writeString(oldPath, 'legacy');
    final legacyFiles = [
      'external_sync/object',
      'remote_sync_cache/p1',
      'audio/recording_123.wav',
      'audio_playback/file',
      'share_attachments/file',
      'profile_qa.jpg',
      '00000000-0000-4000-8000-000000000001.json',
      'better_keep_export_1.zip',
      'sketch_42_0.png',
      'sketch_null_-1.png',
      'log.txt',
      'note.md',
      'note.html',
    ];
    for (final file in legacyFiles) {
      await fs.writeString('${root.path}/$file', 'synthetic');
    }
    final unrelatedSketch = '${root.path}/sketch_family_0.png';
    await fs.writeString(unrelatedSketch, 'protected');
    final unrelated = '${root.path}/shared_preferences.json';
    await fs.writeString(unrelated, 'protected');
    // A crash between journaling and switching must keep the active root.
    await cleanup.resume(prefs);
    expect(await fs.readString(oldPath), 'legacy');
    await cleanup.retire(prefs, first);
    final worker = cleanup.resume(prefs);
    final firstFiles = cleanup.activeFiles(prefs, fs);
    final lazyHandle = ScopedFileSystem.resolving(
      fs,
      () async => cleanup.directoryName(prefs),
    );
    expect(await lazyHandle.documentDir, await firstFiles.documentDir);
    final middlePath =
        '${await firstFiles.documentDir}/external_sync_media/file';
    await firstFiles.writeString(middlePath, 'first');
    await cleanup.retire(prefs, second);
    expect(await lazyHandle.cacheDir, await firstFiles.cacheDir);
    // Replay of the same sign-out cannot retire its new root.
    await cleanup.retire(prefs, second);
    final active = cleanup.activeFiles(prefs, fs);
    final activePath = '${await active.documentDir}/external_sync_media/file';
    await active.writeString(activePath, 'second');
    expect(await fs.readString(oldPath), 'legacy');
    blocked.complete(fs);
    await worker;
    expect(await fs.readString(unrelatedSketch), 'protected');
    expect(await fs.exists(oldPath), isFalse);
    expect(await fs.exists(middlePath), isFalse);
    for (final file in legacyFiles) {
      expect(await fs.exists('${root.path}/$file'), isFalse, reason: file);
    }
    expect(await fs.readString(unrelated), 'protected');
    if (!Platform.isWindows) {
      final link = Link('${root.path}/linked');
      await link.create(await active.documentDir);
      expect(await fs.list(link.path), isNotEmpty);
      await expectLater(
        fs.deleteTrees(['${link.path}/external_sync_media']),
        throwsA(isA<FileSystemException>()),
      );
    }
    expect(await fs.readString(activePath), 'second');
    await prefs.setString('account_files.fixture.active', '../other');
    expect(
      await cleanup.activeFiles(prefs, fs).documentDir,
      await active.documentDir,
    );
    expect(
      prefs.getKeys().where(
        (k) => k.startsWith('account_files.fixture.retired.'),
      ),
      isEmpty,
    );
  });

  test(
    'Windows logout refuses an exclusively locked account database',
    () async {
      final root = await Directory.systemTemp.createTemp('logout-locked-db-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/fixture.db';
      final db = await openDatabase(path);
      await db.close();
      final arguments = [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"$ErrorActionPreference = 'Stop'; $f = [IO.File]::Open($env:QA_LOCKED_DB, 'Open', 'ReadWrite', 'None'); [Console]::WriteLine('locked'); [void][Console]::ReadLine(); $f.Dispose()",
      ];
      final environment = {'QA_LOCKED_DB': path};
      late final Process locker;
      try {
        locker = await Process.start(
          'pwsh.exe',
          arguments,
          environment: environment,
        );
      } on ProcessException catch (error) {
        if (error.errorCode != 2) rethrow; // ERROR_FILE_NOT_FOUND
        locker = await Process.start(
          'powershell.exe',
          arguments,
          environment: environment,
        );
      }
      try {
        final ready = await locker.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15));
        expect(ready, 'locked');
        await expectLater(deleteSignedOutDatabase(path), throwsA(anything));
        expect(await File(path).exists(), isTrue);
      } finally {
        locker.stdin.writeln();
        await locker.stdin.close();
        await locker.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            locker.kill();
            return -1;
          },
        );
      }
      await deleteSignedOutDatabase(path);
    },
    skip: !Platform.isWindows,
  );

  test('legacy hot-path scans once per preference snapshot and fails closed after reload', () async {
    final prefs = _CountingPreferences();
    final files = _FixtureFiles('/fixture');
    final cleanup = AccountFileCleanup('probe', () async => files);
    for (var i = 0; i < 100; i++) {
      expect(cleanup.activeFiles(prefs, files), same(files));
    }
    expect(prefs.scans, 1);
    prefs.data['account_files.probe.retired.00000000-0000-4000-8000-000000000001'] =
        false;
    await FirebaseScopedPreferences.reload(prefs);
    expect(
      () => cleanup.activeFiles(prefs, files),
      throwsA(isA<LocalLibraryUnavailable>()),
    );
    expect(prefs.scans, 2);
  });

  test(
    'gallery denial receives bytes and leaves no temporary sketch file',
    () async {
      final dir = await Directory.systemTemp.createTemp('gallery-denied-');
      addTearDown(() => dir.delete(recursive: true));
      final messenger = binding.defaultBinaryMessenger;
      const channel = MethodChannel('gal');
      final calls = <MethodCall>[];
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'requestAccess') return true;
        throw PlatformException(code: 'ACCESS_DENIED');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        await _FixtureFiles(dir.path)
            .saveToGallery(Uint8List.fromList([1, 2, 3]), 'sketch_8_0.png'),
        false,
      );
      expect(calls.map((call) => call.method), [
        'requestAccess',
        'putImageBytes',
      ]);
      expect(calls.last.arguments['bytes'], [1, 2, 3]);
      expect(
        calls.last.arguments['name'],
        Platform.isIOS || Platform.isMacOS ? 'sketch_8_0.png' : 'sketch_8_0',
      );
      expect(await dir.list().isEmpty, true);
    },
  );

  for (final scenario in _Scenario.values) {
    final failures = switch (scenario) {
      _Scenario.transientAuth => 1,
      _Scenario.persistentAuth => 2,
      _ => 0,
    };
    test('account isolation on sign-out: ${scenario.name}', () async {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const notifications = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final firstReply = Completer<void>();
      var cancellationAttempts = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
        call,
      ) async {
        expect(call.method, 'cancelAll');
        cancellationAttempts++;
        if (scenario == _Scenario.stalledNotification &&
            cancellationAttempts == 1) {
          await firstReply.future;
        }
        if (scenario == _Scenario.notificationUnavailable) {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notifications,
          null,
        ),
      );
      final fixture = await Directory.systemTemp.createTemp(
        'storage-logout-fixture-',
      );
      var failCacheLookup = true;
      final previousPath = await databaseFactory.getDatabasesPath();
      await databaseFactory.setDatabasesPath(fixture.path);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (failCacheLookup &&
              call.method == 'getApplicationCacheDirectory') {
            throw PlatformException(code: 'storage_unavailable');
          }
          return fixture.path;
        },
      );
      SharedPreferences.setMockInitialValues({
        'user_uid': 'account-a',
        'pending_reminder_navigation_note_id': 77,
        'reminder_navigation_last_activation': 'old-account',
      });
      final checkpoint = _StalledCheckpointStore();
      if (scenario == _Scenario.stalledCheckpoint) {
        final normal = SharedPreferencesStorePlatform.instance;
        SharedPreferencesStorePlatform.instance = checkpoint;
        addTearDown(() {
          if (!checkpoint.unblock.isCompleted) checkpoint.unblock.complete();
          SharedPreferencesStorePlatform.instance = normal;
        });
      }
      final originalStorage = FlutterSecureStoragePlatform.instance;
      addTearDown(
        () => FlutterSecureStoragePlatform.instance = originalStorage,
      );
      FlutterSecureStorage.setMockInitialValues({});
      final backend = OfflineFirebase()..configure();
      final previous = FirebaseBackend.active;
      final auth = _SignOutAuth()..failures = failures * 2;
      final firestore = _SignOutFirestore();
      addTearDown(firestore.events.close);
      if (scenario == _Scenario.slowFirestore) {
        firestore.pendingWrites = Completer<void>();
      }
      final stalled = _BlockedKeyStore();
      if (scenario == _Scenario.stalledKey) {
        FlutterSecureStoragePlatform.instance = stalled;
        final normalTimeout = AuthService.signOutKeyTimeout;
        AuthService.signOutKeyTimeout = const Duration(milliseconds: 100);
        addTearDown(() => AuthService.signOutKeyTimeout = normalTimeout);
      }
      FirebaseBackend.configureForTesting(
        FirebaseBackendConfiguration(
          environment: previous.environment,
          app: previous.app,
          auth: auth,
          firestore: firestore,
          functions: previous.functions,
          storage: previous.storage,
          databaseId: previous.databaseId,
          localDataScope: previous.localDataScope,
          googleAuthMode: previous.googleAuthMode,
        ),
      );
      addTearDown(() async {
        await NoteSortService().dispose();
        await AppState.db.close();
        await databaseFactory.setDatabasesPath(previousPath);
        await auth.changes.close();
        await backend.auth.changes.close();
        await backend.firestore.events.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await fixture.delete(recursive: true);
        FirebaseBackend.resetForTesting();
      });
      final prefs = await SharedPreferences.getInstance();
      await AppState.init(prefs: prefs);
      final db = await initDatabase(detectDataLoss: true);
      final recovery = LocalStorageRecovery(prefs);
      expect(recovery.pending, true);
      AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      AppState.labelCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      final media = await Directory('${fixture.path}/external_sync_media/qa')
          .create(recursive: true);
      final outside = await Directory.systemTemp.createTemp(
        'logout-link-target-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await File('${outside.path}/keep').writeAsString('other account');
      if (!Platform.isWindows) {
        await Link('${media.path}/link').create(outside.path);
      }
      final inactive = await Directory('${fixture.path}/firebase_emulator')
          .create();
      await File('${inactive.path}/keep').writeAsString('inactive environment');
      await File('${media.path}/image').writeAsString('synthetic');
      final ambiguous = scenario == _Scenario.damagedDirectory;
      if (ambiguous) {
        await prefs.setString('account_files.live.active', 'broken');
        await prefs.setString('account_files.live.active.backup', '../bad');
        await expectLater(
          AuthService.openDatabaseForStartup(),
          throwsA(isA<LocalLibraryUnavailable>()),
        );
      }
      if (scenario == _Scenario.startup) {
        await db.close();
        AppState.set('db', null);
        final next = await recovery.beginSignOut();
        // Reconstruct the preference cache at the startup boundary.
        await prefs.reload();
        expect(LocalStorageRecovery(prefs).signOutPending, isTrue);
        await AuthService.openDatabaseForStartup();
        expect(prefs.getString('account_files.live.active'), next);
        expect(db.isOpen, isFalse);
        expect(AppState.db.isOpen, isTrue);
      } else {
        if (failures == 0) await db.close();
        final finishing = Completer<void>();
        void observe() {
          if (AuthService.signOutStage.value == SignOutStage.finishing &&
              !finishing.isCompleted) {
            finishing.complete();
          }
        }

        AuthService.signOutStage.addListener(observe);
        addTearDown(() => AuthService.signOutStage.removeListener(observe));
        final first = AuthService.signOut();
        final second = AuthService.signOut();
        expect(identical(first, second), true);
        if (scenario == _Scenario.slowFirestore) {
          await finishing.future.timeout(const Duration(seconds: 2));
          expect(auth.currentUser, isNotNull);
          expect(db.isOpen, isFalse);
          expect(prefs.containsKey('user_uid'), isFalse);
          firestore.pendingWrites!.complete();
        }
        if (scenario == _Scenario.stalledNotification) {
          await first;
          expect(AuthService.signOutStage.value, isNull);
          expect(recovery.signOutPending, isFalse);
          final notifications = LocalNotificationService.instance;
          expect(await notifications.acceptsReminder({'noteId': 1}), isFalse);
          var repairs = 0;
          void repair() => repairs++;
          notifications.lateCancellation.addListener(repair);
          addTearDown(
            () => notifications.lateCancellation.removeListener(repair),
          );
          expect(await notifications.acceptsReminder({'noteId': 1}), isFalse);
          final generation = await notifications.prepareDeliveries();
          expect(generation, isNotNull);
          expect(await notifications.acceptsReminder({'noteId': 1}), isFalse);
          expect(
            await notifications.acceptsReminder({
              'deliveryGeneration': generation,
            }),
            isTrue,
          );
          firstReply.complete();
          await Future<void>.delayed(Duration.zero);
          expect(cancellationAttempts, 1);
          expect(repairs, 1);
        } else if (scenario == _Scenario.stalledKey) {
          await expectLater(first, throwsA(isA<TimeoutException>()));
          expect(AuthService.signOutStage.value, SignOutStage.retry);
          expect(AuthService.signOutProblem, SignOutProblem.secureStorage);
          await expectLater(
            AuthService.resumePendingSignOut(),
            throwsA(isA<TimeoutException>()),
          );
          expect(recovery.signOutPending, isTrue);
          expect(stalled.maxInFlight, 1);
          stalled.unblock.complete();
          await AuthService.resumePendingSignOut();
        } else if (scenario == _Scenario.stalledCheckpoint) {
          await expectLater(
            first.timeout(const Duration(seconds: 25)),
            throwsA(isA<TimeoutException>()),
          );
          expect(AuthService.signOutStage.value, SignOutStage.retry);
          expect(recovery.signOutPending, true);
          checkpoint.unblock.complete();
          await AuthService.resumePendingSignOut();
        } else if (failures == 2) {
          await expectLater(first, throwsStateError);
          expect(AuthService.signOutStage.value, SignOutStage.retry);
          await prefs.reload();
          expect(LocalStorageRecovery(prefs).signOutPending, isTrue);
          await AuthService.resumePendingSignOut();
        } else {
          await first;
        }
      }
      expect(AuthService.signOutStage.value, isNull);
      expect(recovery.signOutPending, isFalse);
      // The old cache is unavailable, but the next session is already usable.
      await resumeAccountFileCleanup(prefs);
      expect(await media.exists(), isTrue);
      final next = await fileSystem();
      final nextMedia =
          '${await next.documentDir}/external_sync_media/qa/image';
      await next.writeString(nextMedia, 'new account');
      failCacheLookup = false;
      await prefs.reload();
      await resumeAccountFileCleanup(prefs);
      expect(await media.exists(), ambiguous);
      expect(await next.readString(nextMedia), 'new account');
      expect(await File('${inactive.path}/keep').exists(), isTrue);
      expect(await File('${outside.path}/keep').exists(), isTrue);
      if (scenario != _Scenario.stalledKey &&
          scenario != _Scenario.stalledCheckpoint) {
        expect(auth.signOuts, 2 * failures + 1);
      }
      expect(auth.currentUser, null);
      expect(prefs.containsKey('pending_reminder_navigation_note_id'), isFalse);
      expect(prefs.containsKey('reminder_navigation_last_activation'), isFalse);
      expect(AppState.db.isOpen, true);
      expect(AppState.noteCloudSyncCheckpoint, null);
      expect(AppState.labelCloudSyncCheckpoint, null);
      expect(prefs.containsKey('note_cloud_sync_checkpoint_v2'), false);
      expect(prefs.containsKey('user_uid'), false);
      expect(recovery.pending, false);
      recovery.loadNotice();
      expect(LocalStorageRecovery.notice.value, 'cleared');
    });
  }
}
