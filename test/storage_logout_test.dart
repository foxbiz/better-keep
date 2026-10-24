import 'dart:io';

import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_firebase.dart';

class _SignOutAuth extends OfflineAuth {
  int signOuts = 0;
  @override
  Future<void> signOut() async {
    signOuts++;
    currentUser = null;
    changes.add(null);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  for (final cacheFails in [false, true]) {
    test(
      'complete logout clears old checkpoints (cache failure: $cacheFails)',
      () async {
        final fixture = await Directory.systemTemp.createTemp(
          'storage-logout-fixture-',
        );
        final previousPath = await databaseFactory.getDatabasesPath();
        await databaseFactory.setDatabasesPath(fixture.path);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (cacheFails && call.method == 'getApplicationCacheDirectory') {
              throw PlatformException(code: 'storage_unavailable');
            }
            return fixture.path;
          },
        );
        SharedPreferences.setMockInitialValues({'user_uid': 'account-a'});
        FlutterSecureStorage.setMockInitialValues({});
        final backend = OfflineFirebase()..configure();
        final previous = FirebaseBackend.active;
        final auth = _SignOutAuth();
        FirebaseBackend.configureForTesting(
          FirebaseBackendConfiguration(
            environment: previous.environment,
            app: previous.app,
            auth: auth,
            firestore: previous.firestore,
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
        await db.close();
        final first = AuthService.signOut();
        final second = AuthService.signOut();
        expect(identical(first, second), true);
        await first;
        expect(auth.signOuts, 1);
        expect(auth.currentUser, null);
        expect(AppState.db.isOpen, true);
        expect(AppState.noteCloudSyncCheckpoint, null);
        expect(AppState.labelCloudSyncCheckpoint, null);
        expect(prefs.containsKey('note_cloud_sync_checkpoint_v2'), false);
        expect(prefs.containsKey('user_uid'), false);
        expect(recovery.pending, false);
        recovery.loadNotice();
        expect(LocalStorageRecovery.notice.value, 'cleared');
      },
    );
  }
}
