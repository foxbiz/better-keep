import 'dart:async';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/firebase_emulator_google_auth.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/db_init.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Database? database;

  setUpAll(() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    final preferences = await SharedPreferences.getInstance();
    FirebaseEmulatorConfig.init(preferences);
    await FirebaseEmulatorConfig.initDeviceInfo();
    await FirebaseEmulatorConfig.connectToEmulators(
      physicalDeviceHost: const String.fromEnvironment('EMULATOR_HOST'),
    );
    await AppState.initializeFirebaseScope(preferences: preferences);
    initializeDb();
    await AppState.init(prefs: preferences);
    await AuthService.init(prefs: preferences);

    final credential = await FirebaseBackend.auth.signInWithCredential(
      FirebaseEmulatorGoogleAuth.credential(),
    );
    expect(credential.user, isNotNull);
    final claimsResult = await FirebaseBackend.functions()
        .httpsCallable('setEmulatorTestClaims')
        .call<Map<String, dynamic>>();
    expect(claimsResult.data['success'], isTrue);
    await credential.user!.getIdToken(true);

    database = await initDatabase();
  });

  tearDownAll(() async {
    await LabelSyncService().dispose();
    PlanService.instance.dispose();
    if (FirebaseBackend.isConfigured) {
      await FirebaseBackend.auth.signOut().catchError((_) {});
    }
    await database?.close();
  });

  testWidgets(
    'label refresh waits for crypto readiness and still pulls for free users',
    (tester) async {
      final sync = LabelSyncService();
      final e2ee = E2EEService.instance;
      final originalStatus = e2ee.status.value;
      final originalUMK = e2ee.deviceManager.getUMK();
      final originalCheckpoint = AppState.labelCloudSyncCheckpoint;
      final originalLastSynced = AppState.lastLabelSynced;
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final remoteId = 'label-readiness-$suffix';
      final labelName = 'Label readiness $suffix';
      final remote = FirebaseBackend.firestore
          .collection('users')
          .doc(AuthService.currentUser!.uid)
          .collection('labels')
          .doc(remoteId);

      try {
        await sync.dispose();
        PlanService.instance.dispose();
        expect(PlanService.instance.isPaid, isFalse);

        e2ee.status.value = E2EEStatus.notInitialized;
        e2ee.deviceManager.setCachedUMKForTesting(null);
        AppState.labelCloudSyncCheckpoint = null;

        final now = DateTime.now().toUtc();
        await remote.set({
          'local_id': suffix,
          'name': labelName,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
          cloudSyncCommittedAtField: FieldValue.serverTimestamp(),
        });
        expect(
          (await remote.get(const GetOptions(source: Source.server))).exists,
          isTrue,
        );

        await sync.refresh();

        expect(await Label.findBySyncId(remoteId), isNull);
        expect(AppState.labelCloudSyncCheckpoint, isNull);
        expect(sync.syncStatus.value.phase, SyncPhase.idle);

        e2ee.deviceManager.setCachedUMKForTesting(
          Uint8List.fromList(List<int>.generate(32, (index) => index)),
        );
        e2ee.status.value = E2EEStatus.ready;
        expect(e2ee.isCryptoReady, isTrue);
        expect(PlanService.instance.isPaid, isFalse);

        await sync.refresh();

        expect((await Label.findBySyncId(remoteId))?.name, labelName);
        expect(AppState.labelCloudSyncCheckpoint?.bootstrapped, isTrue);
        expect(sync.syncStatus.value.phase, SyncPhase.complete);
        debugPrint(
          'LABEL READINESS VERIFIED: blocked without UMK, then imported for '
          'a crypto-ready free user',
        );
      } finally {
        await sync.dispose();
        await remote.delete().catchError((_) {});
        final imported = await Label.findBySyncId(remoteId);
        await imported?.delete(sync: false);
        await (await LabelSyncTrack.getByRemoteId(remoteId))?.delete();
        e2ee.deviceManager.setCachedUMKForTesting(originalUMK);
        e2ee.status.value = originalStatus;
        AppState.labelCloudSyncCheckpoint = originalCheckpoint;
        AppState.lastLabelSynced = originalLastSynced;
      }
    },
  );

  testWidgets('manual refresh waits for an in-progress startup refresh', (
    tester,
  ) async {
    final releaseStartup = Completer<void>();
    final releaseManual = Completer<void>();
    final events = <String>[];
    var invocation = 0;
    NoteSyncService.refreshOperationOverride = () async {
      final current = invocation++;
      events.add('start-$current');
      await [releaseStartup, releaseManual][current].future;
      events.add('end-$current');
    };

    try {
      final startup = NoteSyncService().refresh();
      await tester.pump();
      final manual = NoteSyncService().refresh();
      await tester.pump();

      expect(events, ['start-0']);
      releaseStartup.complete();
      await startup;
      await tester.pump();
      expect(events, ['start-0', 'end-0', 'start-1']);

      releaseManual.complete();
      await manual;
      expect(events, ['start-0', 'end-0', 'start-1', 'end-1']);
    } finally {
      NoteSyncService.refreshOperationOverride = null;
      if (!releaseStartup.isCompleted) releaseStartup.complete();
      if (!releaseManual.isCompleted) releaseManual.complete();
    }
  });

  testWidgets('note-order manifest conflict returns without throwing', (
    tester,
  ) async {
    final userId = AuthService.currentUser!.uid;
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final contextKey = 'folder:label:conflict-$suffix';
    final firstRevision = 'order-first-$suffix';
    final conflictingRevision = 'order-conflict-$suffix';
    final finalRevision = 'order-final-$suffix';
    final repository = FirestoreNoteSortCloudRepository(
      firestore: FirebaseBackend.firestore,
      userId: userId,
      schemaVersion: 2,
    );
    final manifest = FirebaseBackend.firestore
        .collection('users')
        .doc(userId)
        .collection('note_order_contexts')
        .doc(contextKey);

    try {
      await manifest.delete().catchError((_) {});
      final first = await repository.commitManifest(
        contextKey: contextKey,
        sortMode: 'custom',
        revision: firstRevision,
        baseRevision: null,
        chunkCount: 0,
        noteCount: 0,
      );
      expect(first.outcome, NoteSortCloudCommitOutcome.committed);

      final conflict = await repository.commitManifest(
        contextKey: contextKey,
        sortMode: 'custom',
        revision: conflictingRevision,
        baseRevision: 'stale-base-$suffix',
        chunkCount: 0,
        noteCount: 0,
      );
      expect(conflict.outcome, NoteSortCloudCommitOutcome.conflict);
      expect(conflict.previousRevision, firstRevision);
      expect(
        (await manifest.get(
          const GetOptions(source: Source.server),
        )).data()?['revision'],
        firstRevision,
      );

      final committed = await repository.commitManifest(
        contextKey: contextKey,
        sortMode: 'custom',
        revision: finalRevision,
        baseRevision: firstRevision,
        chunkCount: 0,
        noteCount: 0,
      );
      expect(committed.outcome, NoteSortCloudCommitOutcome.committed);
      expect(
        (await manifest.get(
          const GetOptions(source: Source.server),
        )).data()?['revision'],
        finalRevision,
      );
    } finally {
      await manifest.delete().catchError((_) {});
    }
  });
}
