import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/pages/home/home.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/attachment_repair_coordinator.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:better_keep/services/remote_document_revision.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/note_lock_transaction_service.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:better_keep/services/sync_identity_migration.dart';
import 'package:better_keep/state.dart';
import 'package:cloud_firestore/cloud_firestore.dart'
    show DocumentSnapshot, Source, Timestamp;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart' show IdTokenResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/offline_firebase.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory dir;
  late OfflineFirebase backend;
  final e2ee = E2EEService.instance;
  const remote = 'gs://offline-test.invalid/notes/file.bin';
  const secondRemote = 'gs://offline-test.invalid/notes/second.bin';
  final original = Uint8List.fromList([1, 2, 3]);
  final replacement = Uint8List.fromList([4, 5, 6]);
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII=',
  );
  late _Attachments attachments;
  setUpAll(sqfliteFfiInit);
  tearDownAll(() async {
    // Refresh/upload status resets outlive their futures by two seconds. Keep
    // the signed-out fake backend available until all guarded callbacks drain.
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    FirebaseBackend.resetForTesting();
  });
  setUp(() async {
    backend = OfflineFirebase()..configure();
    dir = await Directory.systemTemp.createTemp('offline-probe-data-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    SharedPreferences.setMockInitialValues({'user_uid': 'account-a'});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = db;
    await Note.createTable(db);
    await Label.createTable(db);
    await NoteSyncTrack.createTable(db);
    await LabelSyncTrack.createTable(db);
    await FileSyncTrack.createTable(db);
    await RemoteContentRetryLedger.createTable(db);
    await NoteSortService.createTable(db);
    Note.syncTriggerOverride = () {};
    e2ee.resetInitialization();
    e2ee.deviceManager.setCachedUMKForTesting(Uint8List(32));
    e2ee.status.value = E2EEStatus.ready;
    AuthService.sessionInvalid.value = false;
    AuthService.cloudRecovery.stop();
    AuthService.setAppForeground(false);
    AuthService.cloudRecovery.start('account-a');
    AuthService.cloudRecovery.state.value = CloudSessionState.ready;
    attachments = _Attachments();
    NoteSyncService.attachmentStorageOverride = attachments;
    PackageInfo.setMockInitialValues(
      appName: 'Probe',
      packageName: 'test.probe',
      version: '1.3.3',
      buildNumber: '84',
      buildSignature: '',
    );
    FlutterSecureStorage.setMockInitialValues({
      'e2ee_device_id': 'device-a',
      'e2ee_device_status': 'approved',
      'e2ee_device_private_key': base64Encode(Uint8List(32)),
      'e2ee_device_public_key': base64Encode(Uint8List(32)),
      'e2ee_umk_cache': base64Encode(Uint8List(32)),
    });
  });
  tearDown(() async {
    backend.firestore.emitAcknowledgements = false;
    AuthService.cloudRecovery.stop();
    await e2ee.deviceManager.dispose();
    e2ee.resetInitialization();
    await NoteSyncService().dispose();
    await LabelSyncService().dispose();
    await NoteSortService().dispose();
    PlanService.instance.dispose();
    NoteSortService.cloudRepositoryOverride = null;
    NoteSortService.canReceiveCloudOverride = null;
    NoteSortService.canPushCloudOverride = null;
    NoteSortService.e2eeReadyOverride = null;
    NoteSyncService.attachmentStorageOverride = null;
    Note.syncTriggerOverride = null;
    AppState.db = db;
    await db.close();
    await backend.firestore.events.close();
    for (final events in backend.firestore.documentEvents.values) {
      await events.close();
    }
    for (final events in backend.firestore.queryEvents.values) {
      await events.close();
    }
    backend.auth.currentUser = null;
    await AuthService.refreshLinkedProviders();
    await backend.auth.changes.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await dir.delete(recursive: true);
  });
  Future<Note> saved({List<NoteAttachment> items = const []}) async {
    final n = Note(
      id: 101,
      syncId: 'remote-note',
      title: 'Original',
      content: '[{"insert":"Original\\n"}]',
      plainText: 'Original',
      attachments: items,
    );
    await n.save(false);
    await NoteSyncTrack(
      localId: 101,
      remoteId: 'remote-note',
      action: SyncAction.upload,
      status: SyncStatus.synced,
    ).save();
    return n;
  }

  Map<String, dynamic> payload({
    List<NoteAttachment> items = const [],
    bool locked = false,
  }) => {
    'local_id': 101,
    'title': 'Remote',
    'content': '[{"insert":"Remote\\n"}]',
    'plain_text': 'Remote',
    'created_at': '2026-09-01T00:00:00.000Z',
    'updated_at': '2026-09-11T00:00:00.000Z',
    'attachments': items.map((a) => a.toJson()).toList(),
    'locked': locked ? 1 : 0,
  };
  Future<void> track(String local) => FileSyncTrack(
    noteId: 101,
    localPath: local,
    remotePath: remote,
    contentHash: FileSyncTrack.computeHash(original),
  ).save();
  void allowPaid() => PlanService.instance.activateReviewSession(
    ReviewAuthorization.fromClaims(
      uid: 'account-a',
      claims: {
        'plan': 'pro',
        'planExpiresAt': DateTime.now()
            .add(const Duration(days: 2))
            .millisecondsSinceEpoch,
      },
    ),
  );

  Future<void> seedLocalDependency() async {
    await saved();
    final data = payload();
    backend.firestore.response = (_, _) async => OfflineSnapshot(value: data);
    // The revision is behind the cursor, so a normal incremental pull is empty.
    backend.firestore.queryResponse = (_, _) async => OfflineQuerySnapshot({});
    AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
      bootstrapped: true,
    );
    await RemoteContentRetryLedger().recordDeferred(
      userId: 'account-a',
      remoteDocumentId: 'remote-note',
      revision: remoteDocumentRevision(data, 'remote-note'),
      localId: 101,
      category: RemoteNoteFailureCategory.localApply,
      errorCode: 'local-attachment-unavailable',
    );
  }

  group('empty cloud notes', () {
    for (final sample in [
      (name: 'blank', title: '', text: '', content: '[{"insert":"\\n"}]'),
      (
        name: 'whitespace',
        title: '  ',
        text: '\n ',
        content: '[{"insert":"  \\n"}]',
      ),
      (
        name: 'rich text without plain text',
        title: '',
        text: null,
        content:
            '[{"insert":"Preserved body","attributes":{"bold":true}},{"insert":"\\n"}]',
      ),
    ]) {
      test(
        '${sample.name} persists without duplicate notes or failed syncs',
        () async {
          final data = {
            ...payload(),
            'title': sample.title,
            'plain_text': sample.text,
            'content': sample.content,
          };
          final encrypted = await e2ee.noteEncryption.prepareNoteForUpload(
            data,
          );
          backend.firestore.response = (_, _) async =>
              OfflineSnapshot(value: encrypted);
          for (var attempt = 0; attempt < 2; attempt++) {
            expect(
              await NoteSyncService().retryFailedRemoteNote('remote-note'),
              isTrue,
            );
          }
          final note = (await Note.findById(101))!;
          expect(note.title, sample.title);
          expect(note.plainText, switch (sample.name) {
            'blank' => '\n',
            'whitespace' => '  \n',
            _ => 'Preserved body\n',
          });
          expect(note.content, sample.content);
          expect(note.syncId, 'remote-note');
          expect(await Note.count(NoteType.all), 1);
          expect(
            (await NoteSyncTrack.getByLocalId(101))!.status,
            SyncStatus.synced,
          );
          expect(
            await RemoteContentRetryLedger().get('account-a', 'remote-note'),
            isNull,
          );
          expect(NoteSyncService().syncFailed.value, isEmpty);
        },
      );
    }

    test(
      'saved empty notes support Trash, restore, and editing; drafts are discarded',
      () async {
        backend.firestore.response = (_, _) async => OfflineSnapshot(
          value: {
            ...payload(),
            'title': '',
            'plain_text': '',
            'content': '[{"insert":"\\n"}]',
          },
        );
        expect(
          await NoteSyncService().retryFailedRemoteNote('remote-note'),
          isTrue,
        );
        final note = (await Note.findById(101))!;
        await note.moveToTrash();
        expect((await Note.findById(101))!.trashed, isTrue);
        await note.restoreFromTrash();
        expect((await Note.findById(101))!.trashed, isFalse);
        expect(
          await note.saveEditorSnapshot(
            title: 'Edited',
            content: '[{"insert":"Body\\n"}]',
            plainText: 'Body',
          ),
          101,
        );
        expect((await Note.findById(101))!.plainText, 'Body\n');
        expect(
          await note.saveEditorSnapshot(
            title: '',
            content: '[{"insert":"\\n"}]',
            plainText: '',
          ),
          101,
        );
        expect((await Note.findById(101))!.isEmpty, isTrue);
        expect(
          (await NoteSyncTrack.getByLocalId(101))!.status,
          SyncStatus.pending,
        );
        for (final id in [null, 102]) {
          final draft = Note(id: id, title: ' ', plainText: '\n');
          expect(await draft.save(), -1);
        }
        expect(await Note.count(NoteType.all), 1);
        expect(await NoteSyncTrack.getByLocalId(102), isNull);
      },
    );
  });

  group('recovery callback lifetimes', () {
    late Map<String, dynamic> encrypted;
    final ledger = RemoteContentRetryLedger();

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      AppState.noteCloudSyncCheckpoint = null;
      AppState.labelCloudSyncCheckpoint = null;
      await RemoteSyncCacheService().clear();
      (backend.auth.currentUser! as OfflineUser).tokenResponse = () async =>
          OfflineToken();
      encrypted = await e2ee.noteEncryption.prepareNoteForUpload(payload());
      backend.firestore.response = (path, _) async => OfflineSnapshot(
        value: path.contains('/devices/')
            ? {
                'status': 'approved',
                'public_key': base64Encode(Uint8List(32)),
                'created_at': '2026-01-01T00:00:00Z',
              }
            : path.contains('/notes/')
            ? encrypted
            : {},
      );
      backend.firestore.queryResponse = (_, _) async =>
          OfflineQuerySnapshot({});
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    Future<void> seedEncryptionDependency() async {
      AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
        cursor: CloudSyncCursor(
          seconds: 2000000000,
          nanoseconds: 0,
          documentId: 'later-note',
        ),
      );
      final revision = remoteDocumentRevision(encrypted, 'remote-note');
      await ledger.recordAutomaticFailure(
        userId: 'account-a',
        remoteDocumentId: 'remote-note',
        revision: revision,
        localId: 101,
        category: RemoteNoteFailureCategory.decryption,
        errorCode: 'note-decryption-failed',
        permanent: false,
      );
      await ledger.recordDeferred(
        userId: 'account-a',
        remoteDocumentId: 'remote-note',
        revision: revision,
        localId: 101,
        category: RemoteNoteFailureCategory.decryption,
        errorCode: 'e2ee-not-ready',
      );
    }

    Future<void> drainRecovery() async {
      await NoteSyncService().init();
      await LabelSyncService().init();
      await NoteSyncService().refresh();
      await LabelSyncService().refresh();
    }

    for (final failWrite in [false, true]) {
      test(
        'manual refresh retries an exhausted local apply once (write failure: $failWrite)',
        () async {
          encrypted = await e2ee.noteEncryption.prepareNoteForUpload({
            ...payload(),
            'title': '',
            'plain_text': '',
            'content': '[{"insert":"\\n"}]',
          });
          AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
            bootstrapped: true,
          );
          await ledger.recordManualFailure(
            userId: 'account-a',
            remoteDocumentId: 'remote-note',
            revision: remoteDocumentRevision(encrypted, 'remote-note'),
            localId: 101,
            category: RemoteNoteFailureCategory.localApply,
            errorCode: 'local-note-apply-failed',
          );
          await drainRecovery();
          expect(await Note.findById(101), isNull);
          expect(
            (await ledger.get('account-a', 'remote-note'))!.isExhausted,
            isTrue,
          );
          if (failWrite) {
            await db.execute(
              "CREATE TEMP TRIGGER reject_empty_note BEFORE INSERT ON note BEGIN SELECT RAISE(FAIL, 'synthetic write failure'); END",
            );
          }
          backend.firestore.reads.clear();
          final outcome = await NoteSyncService().refreshWithOutcome(
            manual: true,
          );
          expect(
            backend.firestore.reads.where(
              (read) => read.$1.endsWith('/notes/remote-note'),
            ),
            hasLength(1),
          );
          if (failWrite) {
            expect(outcome, SyncRefreshOutcome.failed);
            expect(await Note.findById(101), isNull);
            expect(
              (await ledger.get('account-a', 'remote-note'))!.isExhausted,
              isTrue,
            );
            await NoteSyncService().refreshWithOutcome();
            expect(
              backend.firestore.reads.where(
                (read) => read.$1.endsWith('/notes/remote-note'),
              ),
              hasLength(1),
            );
          } else {
            expect(outcome, SyncRefreshOutcome.complete);
            expect((await Note.findById(101))!.isEmpty, isTrue);
            expect(await ledger.get('account-a', 'remote-note'), isNull);
            expect(NoteSyncService().syncFailed.value, isEmpty);
            await NoteSyncService().refreshWithOutcome(manual: true);
            expect(await Note.count(NoteType.all), 1);
          }
        },
      );
    }

    testWidgets(
      'refresh shows feedback while actual token verification waits',
      (tester) async {
        final token = Completer<IdTokenResult>();
        (backend.auth.currentUser! as OfflineUser).tokenResponse = () =>
            token.future;
        AuthService.cloudRecovery.state.value = CloudSessionState.unavailable;
        await tester.pumpWidget(
          MaterialApp(
            scaffoldMessengerKey: AppState.scaffoldMessengerKey,
            localizationsDelegates: betterKeepLocalizationDelegates,
            supportedLocales: betterKeepSupportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    SyncRefreshButton(
                      onRefresh: () => refreshSyncFromUser(context),
                    ),
                    const SyncProgressWidget(),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(
          tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNotNull,
        );
        await tester.tap(find.byType(IconButton));
        await tester.pump();
        expect((backend.auth.currentUser! as OfflineUser).tokenRequests, 1);
        expect(find.text('Checking connection…'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(NoteSyncService().isSyncing.value, isFalse);
        token.completeError(TimeoutException('synthetic offline verification'));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(SyncPresentation.instance.value.phase, SyncPhase.unavailable);
        await tester.pumpAndSettle();
        expect(find.text('No connection available.'), findsOneWidget);
        expect(find.byKey(const ValueKey('sync_progress')), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    test(
      'listener failure replaces manual completion and clears after recovery',
      () async {
        final events = StreamController<OfflineQuerySnapshot>.broadcast();
        backend.firestore.queryEvents['users/account-a/notes'] = events;
        await drainRecovery();
        final sync = NoteSyncService();
        final presentation = SyncPresentation.instance;
        final request = presentation.beginManual(
          AuthService.captureSessionIdentity(),
        );
        final outcome = await runManualSyncRefresh(
          notes: () => sync.refreshWithOutcome(manual: true),
          labels: () => LabelSyncService().refreshWithOutcome(),
        );
        presentation.finishManual(request, outcome);
        expect(outcome, SyncRefreshOutcome.complete);
        expect(presentation.value.phase, SyncPhase.complete);
        expect(events.hasListener, isTrue);

        // Real-time application reports content failures without a global
        // isSyncing transition to invalidate the previous manual result.
        events.add(
          OfflineQuerySnapshot({
            'remote-note': {
              ...encrypted,
              'updated_at': 'invalid timestamp',
              cloudSyncCommittedAtField: Timestamp(2000000000, 0),
            },
          }),
        );
        await waitUntil(() => sync.syncFailed.value.contains(101));
        expect(sync.isSyncing.value, isFalse);
        expect(presentation.value.phase, SyncPhase.failed);
        expect(presentation.value.failedCount, 1);

        events.add(
          OfflineQuerySnapshot({
            'remote-note': {
              ...encrypted,
              cloudSyncCommittedAtField: Timestamp(2000000001, 0),
            },
          }),
        );
        await waitUntil(() => sync.syncFailed.value.isEmpty);
        expect((await Note.findById(101))!.title, 'Remote');
        expect(await ledger.get('account-a', 'remote-note'), isNull);
        expect(await sync.refreshWithOutcome(), SyncRefreshOutcome.complete);
        expect(presentation.value.phase, SyncPhase.complete);
        expect(presentation.value.isActive, isFalse);
      },
    );

    test(
      'free refresh downloads but reports and preserves restricted local work',
      () async {
        await Note(
          id: 202,
          title: 'Local only',
          content: '[{"insert":"Local\\n"}]',
        ).save();
        final label = Label(name: 'Local label');
        await label.save();
        final pendingNote = (await db.query(NoteSyncTrack.model)).single;
        final pendingLabel = (await db.query(LabelSyncTrack.model)).single;
        backend.firestore.queryResponse = (path, _) async =>
            OfflineQuerySnapshot(
              path.endsWith('/notes')
                  ? {
                      'remote-note': {
                        ...encrypted,
                        cloudSyncCommittedAtField: Timestamp.fromDate(
                          DateTime.utc(2026, 9, 11),
                        ),
                      },
                    }
                  : {},
            );
        expect(PlanService.instance.isPaid, isFalse);
        expect(
          await NoteSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.uploadRestricted,
        );
        expect(
          await LabelSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.uploadRestricted,
        );
        expect((await Note.findById(101))!.title, 'Remote');
        expect(await Note.count(NoteType.all), 2);
        expect(
          (await db.query(
            NoteSyncTrack.model,
            where: 'local_id = ?',
            whereArgs: [202],
          )).single,
          pendingNote,
        );
        expect((await db.query(LabelSyncTrack.model)).single, pendingLabel);
        expect(
          backend.firestore.writes.where(
            (path) => path.contains('/notes/') || path.contains('/labels/'),
          ),
          isEmpty,
        );
        expect(
          NoteSyncService().syncStatus.value.phase,
          SyncPhase.uploadRestricted,
        );
        expect(
          LabelSyncService().syncStatus.value.phase,
          SyncPhase.uploadRestricted,
        );
      },
    );

    test(
      'device callbacks survive verification and reject account switches',
      () async {
        final events = StreamController<OfflineQuerySnapshot>.broadcast();
        backend.firestore.queryEvents['users/account-a/devices'] = events;
        final reads = <Future<bool>>[];
        final callbackCurrent = <bool>[];
        void changed() {
          callbackCurrent.add(cloudOperationIsCurrent());
          reads.add(e2ee.deviceManager.isFirstDevice());
        }

        e2ee.deviceManager.pendingApprovals.addListener(changed);
        try {
          expect(
            await AuthService.cloudRecovery.check(),
            CloudSessionState.ready,
          );
          await drainRecovery();
          events.add(OfflineQuerySnapshot({}));
          await pumpEventQueue();
          expect(callbackCurrent, [true]);
          expect(await Future.wait(reads), [true]);
          backend.auth.currentUser = OfflineUser('account-b');
          events.add(OfflineQuerySnapshot({}));
          await pumpEventQueue();
          expect(reads, hasLength(1));
        } finally {
          e2ee.deviceManager.pendingApprovals.removeListener(changed);
        }
      },
    );

    test(
      'pause during subscription callbacks is handled and recovery resumes',
      () async {
        AuthService.cloudRecovery.state.value = CloudSessionState.pending;
        AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
          bootstrapped: true,
        );
        AppState.labelCloudSyncCheckpoint = const CloudSyncCheckpoint(
          bootstrapped: true,
        );
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await NoteSyncService().init();
          await LabelSyncService().init();
          AuthService.cloudRecovery.state.value = CloudSessionState.ready;
          allowPaid();
          AuthService.cloudRecovery.connectionLost();
          await pumpEventQueue();
          expect(
            await AuthService.cloudRecovery.check(),
            CloudSessionState.ready,
          );
          await drainRecovery();
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
        expect(NoteSyncService().isSyncing.value, isFalse);
        expect(LabelSyncService().isSyncing.value, isFalse);
      },
    );

    test(
      'actual free-account recovery downloads notes automatically',
      () async {
        backend.firestore.queryResponse = (path, _) async =>
            OfflineQuerySnapshot(
              path.endsWith('/notes')
                  ? {
                      'remote-note': {
                        ...encrypted,
                        cloudSyncCommittedAtField: Timestamp.fromDate(
                          DateTime.utc(2026, 9, 11),
                        ),
                      },
                    }
                  : {},
            );
        expect(PlanService.instance.isPaid, isFalse);
        expect(
          await AuthService.cloudRecovery.check(),
          CloudSessionState.ready,
        );
        await NoteSyncService().init();
        await waitUntil(
          () => AppState.noteCloudSyncCheckpoint?.bootstrapped == true,
        );
        expect((await Note.findById(101))!.title, 'Remote');
        await drainRecovery();
        expect(await Note.count(NoteType.all), 1);
        expect(
          await NoteSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.complete,
        );
      },
    );

    test(
      'approval recovers deferred encryption work after verification ends',
      () async {
        await seedEncryptionDependency();
        e2ee.status.value = E2EEStatus.pendingApproval;
        AuthService.cloudRecovery.state.value = CloudSessionState.pending;
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await NoteSyncService().init();
          await LabelSyncService().init();
          expect(
            await AuthService.cloudRecovery.check(),
            CloudSessionState.ready,
          );
          await drainRecovery();
          for (var retry = 0; retry < 3; retry++) {
            expect(
              await NoteSyncService().refreshWithOutcome(manual: true),
              SyncRefreshOutcome.complete,
            );
          }
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
        expect(await ledger.get('account-a', 'remote-note'), isNull);
        expect((await Note.findById(101))!.title, 'Remote');
        expect(await Note.count(NoteType.all), 1);
      },
    );

    for (final trigger in ['refresh', 'foreground', 'restart']) {
      test(
        '$trigger recovers encryption deferrals behind the cursor',
        () async {
          await seedEncryptionDependency();
          switch (trigger) {
            case 'refresh':
              expect(
                await NoteSyncService().refreshWithOutcome(),
                SyncRefreshOutcome.complete,
              );
            case 'foreground':
              AuthService.setAppForeground(true);
              await AuthService.cloudRecovery.check();
              await drainRecovery();
            case 'restart':
              await NoteSyncService().dispose();
              await NoteSyncService().init();
              await NoteSyncService().refresh();
          }
          expect(await ledger.get('account-a', 'remote-note'), isNull);
          expect((await Note.findById(101))!.title, 'Remote');
          expect(await Note.count(NoteType.all), 1);
        },
      );
    }

    test(
      'pending edits and deletions keep encryption deferrals truthful',
      () async {
        await seedEncryptionDependency();
        final local = await saved();
        local.title = 'Newer local work';
        await local.save();
        for (final action in [SyncAction.upload, SyncAction.delete]) {
          final track = (await NoteSyncTrack.getByLocalId(101))!;
          track.action = action;
          await track.save();
          final before = (await db.query(NoteSyncTrack.model)).single;
          expect(
            await NoteSyncService().refreshWithOutcome(),
            SyncRefreshOutcome.deferred,
          );
          expect((await db.query(NoteSyncTrack.model)).single, before);
          expect((await ledger.get('account-a', 'remote-note'))!.attempts, 1);
          expect((await Note.findById(101))!.title, 'Newer local work');
        }
        expect(
          backend.firestore.reads.where((r) => r.$1.contains('/notes/')),
          isEmpty,
        );
      },
    );

    test(
      'dependency reads coalesce and ignore late account completions',
      () async {
        await seedEncryptionDependency();
        final entered = Completer<void>(), release = Completer<void>();
        backend.firestore.response = (_, _) async {
          entered.complete();
          await release.future;
          return OfflineSnapshot(value: encrypted);
        };
        final first = NoteSyncService().recheckReadyDependencies();
        await entered.future;
        final second = NoteSyncService().recheckReadyDependencies();
        expect(identical(first, second), isTrue);
        backend.auth.currentUser = OfflineUser('account-b');
        release.complete();
        await Future.wait([first, second]);
        expect(backend.firestore.reads, hasLength(1));
        expect(await Note.count(NoteType.all), 0);
        final entry = (await ledger.get('account-a', 'remote-note'))!;
        expect(entry.state, RemoteContentRetryState.deferred);
        expect(entry.attempts, 1);
      },
    );

    test('transport loss retains deferred budgets until recovery', () async {
      await seedEncryptionDependency();
      final response = backend.firestore.response;
      backend.firestore.response = (_, _) async =>
          throw TimeoutException('offline');
      expect(
        await NoteSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.unavailable,
      );
      final entry = (await ledger.get('account-a', 'remote-note'))!;
      expect(entry.state, RemoteContentRetryState.deferred);
      expect(entry.attempts, 1);
      backend.firestore.response = response;
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      expect(
        await NoteSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.complete,
      );
      expect(await ledger.get('account-a', 'remote-note'), isNull);
    });

    test(
      'missing keys and exhausted content failures keep their retry budgets',
      () async {
        await seedEncryptionDependency();
        e2ee.deviceManager.setCachedUMKForTesting(null);
        for (var retry = 0; retry < 3; retry++) {
          expect(
            await NoteSyncService().refreshWithOutcome(),
            SyncRefreshOutcome.deferred,
          );
        }
        final deferred = (await ledger.get('account-a', 'remote-note'))!;
        expect(deferred.attempts, 1);
        expect(deferred.state, RemoteContentRetryState.deferred);
        e2ee.deviceManager.setCachedUMKForTesting(Uint8List(32));
        final exhausted = await ledger.recordManualFailure(
          userId: deferred.userId,
          remoteDocumentId: deferred.remoteDocumentId,
          revision: deferred.revision,
          localId: deferred.localId,
          category: RemoteNoteFailureCategory.decryption,
          errorCode: 'note-decryption-failed',
        );
        expect(
          await NoteSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.failed,
        );
        expect(
          (await ledger.get('account-a', 'remote-note'))!.toRow(),
          exhausted.toRow(),
        );
        expect(backend.firestore.reads, isEmpty);
      },
    );

    testWidgets('Home handles approval read cancellation and late disposal', (
      tester,
    ) async {
      late StreamController<OfflineQuerySnapshot> events;
      late Completer<void> cancelledRead;
      late Completer<OfflineQuerySnapshot> lateRead;
      await tester.runAsync(() async {
        events = StreamController<OfflineQuerySnapshot>.broadcast();
        cancelledRead = Completer<void>();
        lateRead = Completer<OfflineQuerySnapshot>();
        backend.firestore.queryEvents['users/account-a/devices'] = events;
        expect(
          await AuthService.cloudRecovery.check(),
          CloudSessionState.ready,
        );
        await drainRecovery();
      });
      // This widget regression owns approval callbacks; startup and actual
      // refresh I/O are covered above without Flutter's fake widget clock.
      NoteSyncService.refreshOperationOverride = () async {};
      addTearDown(() => NoteSyncService.refreshOperationOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: const Home(),
        ),
      );
      var approvalReads = 0;
      backend.firestore.queryResponse = (path, _) async {
        if (path.endsWith('/devices')) {
          approvalReads++;
          if (approvalReads == 1) {
            cancelledRead.complete();
            throw const CloudOperationCancelled();
          }
          return lateRead.future;
        }
        return OfflineQuerySnapshot({});
      };
      final pending = OfflineQuerySnapshot({
        'pending-device': {
          'status': 'pending',
          'public_key': base64Encode(Uint8List(32)),
          'created_at': '2026-01-01T00:00:00Z',
        },
      });
      await tester.runAsync(() async {
        events.add(pending);
        await cancelledRead.future;
        await pumpEventQueue();
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(AuthService.cloudRecovery.state.value, CloudSessionState.ready);
      await tester.runAsync(() async {
        events.add(pending);
        await waitUntil(() => approvalReads == 2);
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        lateRead.complete(OfflineQuerySnapshot({}));
        await pumpEventQueue();
      });
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('login recovery provider metadata', () {
    late StreamController<DocumentSnapshot<Map<String, dynamic>>> userEvents;
    final originalProviders = {
      'provider': 'email',
      'linkedProviders': {'google': <String, dynamic>{}},
    };
    final changedProviders = {
      'provider': 'github',
      'linkedProviders': {
        'facebook': <String, dynamic>{},
        'apple.com': <String, dynamic>{},
      },
    };

    setUp(() async {
      // Native notification plugins are outside these in-process sync tests.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      userEvents = StreamController.broadcast();
      backend.firestore.documentEvents['users/account-a'] = userEvents;
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(value: originalProviders);
      await AuthService.refreshLinkedProviders();
      backend.firestore.queryResponse = (path, _) async => OfflineQuerySnapshot(
        path.endsWith('/notes')
            ? {
                'remote-note': {
                  ...payload(),
                  cloudSyncCommittedAtField: Timestamp.fromDate(
                    DateTime.utc(2026, 9, 11),
                  ),
                },
              }
            : {},
      );
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final cached in [false, true]) {
      test(
        '${cached ? 'cached' : 'pending'} profile reads keep recovery ready until acknowledgement',
        () async {
          backend.firestore.response = (path, options) async {
            expect(options?.source, Source.server);
            expect(path, 'users/account-a');
            await waitUntil(() => backend.firestore.writes.contains(path));
            return OfflineSnapshot(
              value: changedProviders,
              cached: cached,
              pending: !cached,
            );
          };
          for (var attempt = 0; attempt < 3; attempt++) {
            await AuthService.cloudRecovery.onReady(
              AuthService.captureSession(),
            );
            expect(
              AuthService.cloudRecovery.state.value,
              CloudSessionState.ready,
            );
            expect(e2ee.isCryptoReady, isTrue);
            expect(AuthService.sessionInvalid.value, isFalse);
            expect(AppState.noteCloudSyncCheckpoint?.bootstrapped, isTrue);
            expect(await Note.count(NoteType.all), 1);
            expect(
              AuthService.getLinkedProviderIds(),
              unorderedEquals(['google.com', 'password']),
            );
          }
          final readsBeforeAcknowledgement = backend.firestore.reads.length;
          for (final snapshot in [
            OfflineSnapshot(value: changedProviders, pending: true),
            OfflineSnapshot(value: changedProviders, cached: true),
            OfflineSnapshot(value: {'provider': 123, 'linkedProviders': {}}),
          ]) {
            userEvents.add(snapshot);
            await pumpEventQueue();
            expect(
              AuthService.getLinkedProviderIds(),
              unorderedEquals(['google.com', 'password']),
            );
          }
          userEvents.add(OfflineSnapshot(value: changedProviders));
          await pumpEventQueue();
          expect(
            AuthService.getLinkedProviderIds(),
            unorderedEquals(['github.com', 'facebook.com', 'apple.com']),
          );
          expect(backend.firestore.reads.length, readsBeforeAcknowledgement);
          expect(
            AuthService.cloudRecovery.state.value,
            CloudSessionState.ready,
          );
        },
      );
    }

    test(
      'transport failures still pause recovery and retain providers',
      () async {
        await AuthService.cloudRecovery.onReady(AuthService.captureSession());
        backend.firestore.response = (_, _) async =>
            throw TimeoutException('offline');
        await AuthService.refreshLinkedProviders();
        expect(
          AuthService.cloudRecovery.state.value,
          CloudSessionState.unavailable,
        );
        expect(
          AuthService.getLinkedProviderIds(),
          unorderedEquals(['google.com', 'password']),
        );
        expect(e2ee.isCryptoReady, isTrue);
        expect(AuthService.sessionInvalid.value, isFalse);
      },
    );

    test(
      'late reads and listener events cannot update another account',
      () async {
        await AuthService.cloudRecovery.onReady(AuthService.captureSession());
        final pending = Completer<DocumentSnapshot<Map<String, dynamic>>>();
        backend.firestore.response = (_, _) => pending.future;
        final oldRefresh = AuthService.refreshLinkedProviders();
        backend.auth.currentUser = OfflineUser('account-b');
        backend.firestore.response = (_, _) async =>
            OfflineSnapshot(value: changedProviders);
        await AuthService.refreshLinkedProviders();
        pending.complete(OfflineSnapshot(value: originalProviders));
        await oldRefresh;
        userEvents.add(OfflineSnapshot(value: originalProviders));
        userEvents.addError(TimeoutException('old account listener'));
        await pumpEventQueue();
        expect(
          AuthService.getLinkedProviderIds(),
          unorderedEquals(['github.com', 'facebook.com', 'apple.com']),
        );
        expect(AuthService.cloudRecovery.state.value, CloudSessionState.ready);
      },
    );
  });

  test(
    'upgraded note identities survive repeated bootstrap refreshes',
    () async {
      final originals = <Note>[];
      for (var i = 1; i <= 3; i++) {
        final note = Note(
          id: i,
          syncId: 'remote-$i',
          title: 'Note $i',
          content: '[{"insert":"Body\\n"}]',
        );
        await note.save(false);
        await NoteSyncTrack(
          localId: i,
          remoteId: 'remote-$i',
          action: SyncAction.upload,
          status: SyncStatus.synced,
        ).save();
        originals.add(note);
      }
      // A pre-stable-ID database still has its historical remote track IDs.
      await db.update(Note.model, {'sync_id': null});
      await SyncIdentityMigration.migrate(db);
      final remoteNotes = {
        for (final note in originals)
          note.syncId!: {
            ...payload(),
            'local_id': note.id,
            'title': note.title,
          },
      };
      for (var pass = 0; pass < 3; pass++) {
        AppState.noteCloudSyncCheckpoint = null;
        var queries = 0;
        backend.firestore.queryResponse = (_, _) async =>
            OfflineQuerySnapshot(queries++ == 0 ? {} : remoteNotes);
        expect(
          await NoteSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.complete,
        );
        expect(await Note.count(NoteType.all), 3);
        expect(await NoteSyncTrack.count(), 3);
        for (final note in originals) {
          expect((await Note.findById(note.id!))!.syncId, note.syncId);
        }
      }
    },
  );

  test(
    'lost upload acknowledgement retries the same remote document',
    () async {
      allowPaid();
      final note = Note(
        id: 101,
        title: 'Offline',
        content: '[{"insert":"Offline\\n"}]',
      );
      await note.save();
      final remoteId = note.syncId!;
      backend.firestore.commit = () async {
        backend.firestore.documents['users/account-a/notes/$remoteId'] = {
          ...payload(),
          'title': 'Offline',
        };
        throw TimeoutException('acknowledgement lost after server commit');
      };
      await NoteSyncService().sync(true);
      expect((await NoteSyncTrack.getByLocalId(101))!.remoteId, remoteId);
      expect(
        (await NoteSyncTrack.getByLocalId(101))!.status,
        SyncStatus.pending,
      );
      await NoteSyncService().dispose();
      backend.firestore.commit = null;
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      await NoteSyncService().sync(true);
      expect(
        backend.firestore.documents.keys.where(
          (key) => key.contains('/notes/'),
        ),
        hasLength(1),
      );
      expect(await Note.count(NoteType.all), 1);
      expect(
        (await NoteSyncTrack.getByLocalId(101))!.status,
        SyncStatus.synced,
      );
    },
  );

  testWidgets(
    'Home keeps one current card when loading precedes a creation event',
    (tester) async {
      final proxy = _TransactionBarrierDatabase(db);
      late Completer<void> entered, release;
      late Future<bool> remoteApply;
      await tester.runAsync(() async {
        AppState.db = proxy;
        NoteSortService.canReceiveCloudOverride = false;
        NoteSortService.canPushCloudOverride = false;
        entered = Completer<void>();
        release = Completer<void>();
        proxy.afterTransaction = () async {
          if ((await db.query(Note.model)).isNotEmpty) {
            proxy.afterTransaction = null;
            entered.complete();
            await release.future;
          }
        };
        backend.firestore.response = (_, _) async =>
            OfflineSnapshot(value: payload());
        remoteApply = NoteSyncService().retryFailedRemoteNote('remote-note');
        await entered.future;
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: const Scaffold(body: Notes()),
        ),
      );
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(NoteCard), findsOneWidget);
      late Note newer;
      await tester.runAsync(() async {
        newer = (await Note.findById(101))!;
        newer.title = 'Newer local edit';
        newer.pinned = true;
        await newer.save();
        release.complete();
        expect(await remoteApply, isTrue);
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(NoteCard), findsOneWidget);
      expect(tester.widget<NoteCard>(find.byType(NoteCard)).note, same(newer));
      final stale = Note(id: 101, title: 'Old creation', archived: true);
      stale.notify('created', false);
      stale.notify('created', false);
      await tester.pump();
      expect(find.byType(NoteCard), findsOneWidget);
      expect(
        tester.widget<NoteCard>(find.byType(NoteCard)).note.title,
        'Newer local edit',
      );
      await tester.runAsync(() async {
        expect(await Note.count(NoteType.all), 1);
        expect(
          (await NoteSyncTrack.getByLocalId(101))!.status,
          SyncStatus.pending,
        );
        // Equal content in a genuinely different note must remain separate.
        await Note(id: 102, title: newer.title, content: newer.content).save();
      });
      await tester.pump();
      expect(find.byType(NoteCard), findsNWidgets(2));
      await tester.runAsync(() => newer.delete());
      await tester.pump();
      expect(find.byType(NoteCard), findsOneWidget);
      expect(tester.widget<NoteCard>(find.byType(NoteCard)).note.id, 102);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    },
  );

  test('stale editor models adopt chained repairs before saving', () async {
    final old = '${dir.path}/missing.png';
    final editor = await saved(items: [imageAttachment(old)]);
    await track(old);
    attachments.response = (_) async => png;
    final first = await NoteSyncService().redownloadFile(old);
    final second = await NoteSyncService().redownloadFile(first!);
    expect(second, isNotNull);
    expect(second, isNot(first));
    // No editor listener is present, as with a disposed editor's queued save.
    expect(editor.attachments.single.image!.src, old);
    await editor.saveEditorSnapshot(
      title: 'Newer title',
      content: '[{"insert":"Newer body\\n"}]',
      plainText: 'Newer body',
    );
    final restored = (await Note.findById(101))!;
    expect(restored.title, 'Newer title');
    expect(restored.attachments.single.image!.src, second);
    expect((await FileSyncTrack.getByRemotePath(remote))!.localPath, second);
    expect(await File(second!).exists(), isTrue);
    expect((await NoteSyncTrack.getByLocalId(101))!.status, SyncStatus.pending);
  });

  test(
    'repair does not resurrect an attachment removed from a stale model',
    () async {
      final old = '${dir.path}/old.png';
      final local = await saved(items: [imageAttachment(old)]);
      await track(old);
      final released = Completer<Uint8List>();
      attachments.response = (_) => released.future;
      final repairing = NoteSyncService().redownloadFile(old);
      await waitUntil(() => attachments.calls == 1);
      local.attachments = [imageAttachment('${dir.path}/user-added.png')];
      released.complete(png);
      expect(await repairing, isNotNull);
      await local.save();
      expect(
        (await Note.findById(101))!.attachments.single.image!.src,
        '${dir.path}/user-added.png',
      );
    },
  );

  test(
    'save queued during a repair commit uses its committed reference',
    () async {
      final proxy = _TransactionBarrierDatabase(db);
      AppState.db = proxy;
      final old = '${dir.path}/queued.png';
      final local = await saved(items: [imageAttachment(old)]);
      await track(old);
      attachments.response = (_) async => png;
      final entered = Completer<void>(), release = Completer<void>();
      proxy.beforeTransaction = () async {
        entered.complete();
        await release.future;
      };
      final repair = NoteSyncService().redownloadFile(old);
      await entered.future;
      local.title = 'Queued edit';
      final save = local.save();
      release.complete();
      final repaired = await repair;
      expect(repaired, isNotNull);
      await save;
      final restored = (await Note.findById(101))!;
      expect(restored.title, 'Queued edit');
      expect(restored.attachments.single.image!.src, repaired);
    },
  );

  test('a running save finishes before a prepared repair can commit', () async {
    final proxy = _TransactionBarrierDatabase(db);
    AppState.db = proxy;
    final old = '${dir.path}/running.png';
    final local = await saved(items: [imageAttachment(old)]);
    await track(old);
    attachments.response = (_) async => png;
    final entered = Completer<void>(), release = Completer<void>();
    proxy.beforeTransaction = () async {
      entered.complete();
      await release.future;
    };
    local.title = 'Save in flight';
    final save = local.save();
    await entered.future;
    final repair = NoteSyncService().redownloadFile(old);
    await waitUntil(() => attachments.calls == 1);
    release.complete();
    await save;
    expect(await repair, isNull);
    expect((await Note.findById(101))!.title, 'Save in flight');
    expect((await FileSyncTrack.getByRemotePath(remote))!.localPath, old);
  });

  testWidgets(
    'open editor keeps unsaved text and autosaves repaired image paths',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Note local;
      late String old;
      await tester.runAsync(() async {
        old = '${dir.path}/editor.png';
        await File(old).writeAsBytes(png);
        local = await saved(items: [imageAttachment(old)]);
        await track(old);
        attachments.response = (_) async => png;
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: NoteEditor(note: local),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Unsaved editor title',
      );
      String? repaired;
      await tester.runAsync(() async {
        repaired = await NoteSyncService().redownloadFile(old);
      });
      expect(repaired, isNotNull);
      expect(local.attachments.single.image!.src, repaired);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Unsaved editor title',
      );
      await tester.pump(const Duration(seconds: 1));
      Note? restored;
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          restored = await Note.findById(101);
        });
        if (restored?.title == 'Unsaved editor title') break;
      }
      expect(restored!.title, 'Unsaved editor title');
      expect(restored!.attachments.single.image!.src, repaired);
      await tester.pump();
      AttachmentRepairCoordinator.instance.reset();
      AttachmentRepairCoordinator.instance.capture(db).committed(101, {
        repaired!: 'different-session-path',
      });
      expect(local.attachments.single.image!.src, repaired);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  test(
    'dependency retries coalesce and skip revisions already behind the cursor',
    () async {
      await seedLocalDependency();
      final entered = Completer<void>(), release = Completer<void>();
      final data = payload();
      backend.firestore.response = (_, _) async {
        entered.complete();
        await release.future;
        return OfflineSnapshot(value: data);
      };
      final first = NoteSyncService().recheckLocalAttachmentDependencies();
      await entered.future;
      final second = NoteSyncService().recheckLocalAttachmentDependencies();
      expect(identical(first, second), isTrue);
      release.complete();
      await Future.wait([first, second]);
      expect(backend.firestore.reads, hasLength(1));
      expect((await Note.findById(101))!.title, 'Remote');
      expect(
        await RemoteContentRetryLedger().get('account-a', 'remote-note'),
        isNull,
      );
    },
  );

  testWidgets(
    'disposed editor queued autosave still adopts a committed repair',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final proxy = _TransactionBarrierDatabase(db);
      AppState.db = proxy;
      late Note local;
      final old = '${dir.path}/disposed.png';
      await tester.runAsync(() async {
        await File(old).writeAsBytes(png);
        local = await saved(items: [imageAttachment(old)]);
        await track(old);
        attachments.response = (_) async => png;
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          home: NoteEditor(note: local),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Save after disposal',
      );
      late Future<String?> repair;
      late Completer<void> release;
      await tester.runAsync(() async {
        final entered = Completer<void>();
        release = Completer<void>();
        proxy.beforeTransaction = () async {
          entered.complete();
          await release.future;
        };
        repair = NoteSyncService().redownloadFile(old);
        await entered.future;
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      String? repaired;
      await tester.runAsync(() async {
        release.complete();
        repaired = await repair;
      });
      expect(repaired, isNotNull);
      Note? restored;
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          restored = await Note.findById(101);
        });
        if (restored?.title == 'Save after disposal') break;
      }
      expect(restored!.title, 'Save after disposal');
      expect(restored!.attachments.single.image!.src, repaired);
    },
  );

  test(
    'recovery skips pending local work and retries after acknowledgement',
    () async {
      await seedLocalDependency();
      final local = (await Note.findById(101))!;
      local.title = 'Pending local edit';
      await local.save();
      await NoteSyncService().recheckLocalAttachmentDependencies();
      expect(backend.firestore.reads, isEmpty);
      expect((await Note.findById(101))!.title, 'Pending local edit');
      final pending = (await NoteSyncTrack.getByLocalId(101))!;
      expect(await pending.markSyncedIfUnchanged(DateTime.now()), isTrue);
      await NoteSyncService().recheckLocalAttachmentDependencies();
      expect(
        await RemoteContentRetryLedger().get('account-a', 'remote-note'),
        isNull,
      );
    },
  );

  test(
    'restart refresh retries durable dependencies without an encryption transition',
    () async {
      await seedLocalDependency();
      await NoteSyncService().dispose();
      expect(
        await NoteSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.complete,
      );
      expect((await Note.findById(101))!.title, 'Remote');
      expect(e2ee.status.value, E2EEStatus.ready);
      expect(backend.firestore.queryReads, isNotEmpty);
    },
  );

  test(
    'foreground resume rechecks local dependencies while encryption stays ready',
    () async {
      await seedLocalDependency();
      final token = Completer<IdTokenResult>();
      (backend.auth.currentUser as OfflineUser).tokenResponse = () =>
          token.future;
      AuthService.setAppForeground(true);
      await NoteSyncService().recheckLocalAttachmentDependencies();
      expect((await Note.findById(101))!.title, 'Remote');
      expect(e2ee.status.value, E2EEStatus.ready);
      AuthService.setAppForeground(false);
      AuthService.cloudRecovery.stop();
      token.complete(OfflineToken());
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'pending deletion is never downloaded by a dependency recheck',
    () async {
      await seedLocalDependency();
      final pending = (await NoteSyncTrack.getByLocalId(101))!;
      await pending.setAction(SyncAction.delete);
      await NoteSyncService().recheckLocalAttachmentDependencies();
      expect(backend.firestore.reads, isEmpty);
      expect(
        (await NoteSyncTrack.getByLocalId(101))!.action,
        SyncAction.delete,
      );
      expect(
        await RemoteContentRetryLedger().get('account-a', 'remote-note'),
        isNotNull,
      );
    },
  );

  test('late dependency read cannot apply after account switching', () async {
    await seedLocalDependency();
    final entered = Completer<void>(), release = Completer<void>();
    backend.firestore.response = (_, _) async {
      entered.complete();
      await release.future;
      return OfflineSnapshot(value: payload());
    };
    final retry = NoteSyncService().recheckLocalAttachmentDependencies();
    await entered.future;
    backend.auth.currentUser = OfflineUser('account-b');
    release.complete();
    await retry;
    expect((await Note.findById(101))!.title, 'Original');
    expect(
      (await RemoteContentRetryLedger().get('account-a', 'remote-note'))!.state,
      RemoteContentRetryState.deferred,
    );
  });

  test(
    'transport failure retains dependency work and reports unavailable',
    () async {
      await seedLocalDependency();
      backend.firestore.response = (_, _) async =>
          throw TimeoutException('offline');
      expect(
        await NoteSyncService().refreshWithOutcome(),
        SyncRefreshOutcome.unavailable,
      );
      expect(
        AuthService.cloudRecovery.state.value,
        CloudSessionState.unavailable,
      );
      expect(
        (await RemoteContentRetryLedger().get(
          'account-a',
          'remote-note',
        ))!.attempts,
        0,
      );
      expect(NoteSyncService().isSyncing.value, isFalse);
    },
  );
  test('verification acknowledgements do not republish capabilities', () async {
    backend.firestore.documents['users/account-a/devices/device-a'] = {
      'status': 'approved',
      'public_key': base64Encode(Uint8List(32)),
      'created_at': '2026-01-01T00:00:00Z',
    };
    backend.firestore.emitAcknowledgements = true;
    await e2ee.verifyLocalSessionAuthorization();
    await waitUntil(() => backend.firestore.acknowledgements >= 1);
    backend.firestore.emitAcknowledgements = false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(backend.firestore.writes, hasLength(1));
  });
  test('failed capability publication retries once after recovery', () async {
    backend.firestore.documents['users/account-a/devices/device-a'] = {
      'status': 'approved',
      'public_key': base64Encode(Uint8List(32)),
      'created_at': '2026-01-01T00:00:00Z',
    };
    backend.firestore.write = (_, _) async {
      throw TimeoutException('offline');
    };
    await e2ee.verifyLocalSessionAuthorization();
    await waitUntil(() => backend.firestore.writes.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    backend.firestore.write = null;
    backend.firestore.emitAcknowledgements = true;
    AuthService.cloudRecovery.state.value = CloudSessionState.ready;
    await e2ee.verifyLocalSessionAuthorization();
    await waitUntil(() => backend.firestore.acknowledgements == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await e2ee.verifyLocalSessionAuthorization();
    expect(backend.firestore.writes, hasLength(2));
  });

  test(
    'late capability publication does not suppress the next account',
    () async {
      final pending = Completer<void>();
      backend.firestore.documents['users/account-a/devices/device-a'] = {
        'status': 'approved',
        'public_key': base64Encode(Uint8List(32)),
        'created_at': '2026-01-01T00:00:00Z',
      };
      backend.firestore.write = (_, _) => pending.future;
      await e2ee.verifyLocalSessionAuthorization();
      await waitUntil(() => backend.firestore.writes.length == 1);
      backend.auth.currentUser = OfflineUser('account-b');
      backend.firestore.documents['users/account-b/devices/device-a'] = {
        ...backend.firestore.documents['users/account-a/devices/device-a']!,
      };
      backend.firestore.write = null;
      await e2ee.verifyLocalSessionAuthorization();
      await waitUntil(() => backend.firestore.writes.length == 2);
      pending.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await e2ee.verifyLocalSessionAuthorization();
      expect(backend.firestore.writes, [
        'users/account-a/devices/device-a',
        'users/account-b/devices/device-a',
      ]);
    },
  );

  test(
    'local edit at remote commit remains pending and retains its content',
    () async {
      final local = await saved();
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(value: payload());
      final proxy = _TransactionBarrierDatabase(db);
      proxy.beforeTransaction = () async {
        AppState.db = db;
        local.title = 'New LOCAL edit';
        local.content = '[{"insert":"New LOCAL edit\\n"}]';
        local.plainText = 'New LOCAL edit';
        await local.save();
        AppState.db = proxy;
      };
      AppState.db = proxy;
      final applied = await NoteSyncService().retryFailedRemoteNote(
        'remote-note',
      );
      AppState.db = db;
      final stored = await Note.findById(101);
      final pending = await NoteSyncTrack.getByLocalId(101);
      expect(proxy.interceptions, 1);
      expect(applied, isFalse);
      expect(stored!.title, 'New LOCAL edit');
      expect(pending!.status, SyncStatus.pending);
    },
  );
  test('local deletion at remote commit cannot resurrect the note', () async {
    final local = await saved();
    backend.firestore.response = (_, _) async =>
        OfflineSnapshot(value: payload());
    final proxy = _TransactionBarrierDatabase(db);
    proxy.beforeTransaction = () async {
      AppState.db = db;
      await local.delete();
      AppState.db = proxy;
    };
    AppState.db = proxy;
    await NoteSyncService().retryFailedRemoteNote('remote-note');
    AppState.db = db;
    expect(proxy.interceptions, 1);
    expect(await Note.findById(101), isNull);
    expect((await NoteSyncTrack.getByLocalId(101))!.action, SyncAction.delete);
  });

  test(
    'account switch during attachment download leaves the old note intact',
    () async {
      final old = '${dir.path}/original.bin';
      await File(old).writeAsBytes(original);
      await saved(items: [imageAttachment(old)]);
      await track(old);
      final started = Completer<void>(), release = Completer<Uint8List?>();
      attachments.response = (_) {
        started.complete();
        return release.future;
      };
      final repair = NoteSyncService().redownloadFile(old);
      await started.future;
      backend.auth.currentUser = OfflineUser('account-b');
      release.complete(replacement);
      expect(await repair, isNull);
      expect((await Note.findById(101))!.attachments.single.image!.src, old);
      expect((await FileSyncTrack.getByRemotePath(remote))!.localPath, old);
      expect(await File(old).readAsBytes(), original);
    },
  );

  test(
    'PIN attachment repair persists across restart without changing pending work',
    () async {
      final old = '${dir.path}/protected.bin';
      final protectedBytes = await encryptBytesWithPassword(original, '1234');
      await File(old).writeAsBytes(protectedBytes);
      final local = Note(
        id: 101,
        syncId: 'remote-note',
        title: 'Protected',
        locked: true,
        content: await encryptAsync('secret', '1234'),
        attachments: [imageAttachment(old)],
      );
      await local.save();
      await track(old);
      final before = (await db.query(Note.model)).single;
      final pendingBefore = (await NoteSyncTrack.getByLocalId(101))!.toJson();
      attachments.response = (_) async => protectedBytes;
      final repaired = await NoteSyncService().redownloadFile(old);
      expect(repaired, isNotNull);
      expect(await File(old).exists(), isFalse);
      await NewAttachmentTransactionRecoveryService.recoverPending(
        database: db,
        operations: await NoteLockFileOperations.platform(),
        journal: NewAttachmentTransactionJournal(await AppState.prefs),
      );
      final after = (await db.query(Note.model)).single;
      expect(after['content'], before['content']);
      expect(after['updated_at'], before['updated_at']);
      expect(after['locked'], 1);
      expect((await NoteSyncTrack.getByLocalId(101))!.toJson(), pendingBefore);
      expect(
        (await Note.findById(101))!.attachments.single.image!.src,
        repaired,
      );
      expect(await File(repaired!).readAsBytes(), protectedBytes);
      local.pinned = true;
      await local.save();
      final afterSave = (await Note.findById(101))!;
      expect(afterSave.attachments.single.image!.src, repaired);
      expect(afterSave.locked, isTrue);
      expect(afterSave.pinned, isTrue);
    },
  );

  test(
    'database failure rolls back replacement mapping and staged files',
    () async {
      var notifications = 0;
      final subscription = AttachmentRepairCoordinator.instance.repairs.listen(
        (_) => notifications++,
      );
      addTearDown(subscription.cancel);
      final old = '${dir.path}/original.bin';
      await File(old).writeAsBytes(original);
      await saved(items: [imageAttachment(old)]);
      await track(old);
      attachments.response = (_) async => replacement;
      await db.execute(
        "CREATE TRIGGER reject_repair BEFORE UPDATE ON note BEGIN SELECT RAISE(FAIL, 'synthetic failure'); END",
      );
      expect(await NoteSyncService().redownloadFile(old), isNull);
      expect(notifications, 0);
      expect((await Note.findById(101))!.attachments.single.image!.src, old);
      expect((await FileSyncTrack.getByRemotePath(remote))!.localPath, old);
      expect(await File(old).readAsBytes(), original);
      expect(
        await NewAttachmentTransactionJournal(await AppState.prefs).load(),
        isEmpty,
      );
    },
  );

  testWidgets('image loader reads the committed replacement path', (
    tester,
  ) async {
    late String old;
    await tester.runAsync(() async {
      old = '${dir.path}/missing.png';
      await saved(items: [imageAttachment(old)]);
      await track(old);
      attachments.response = (_) async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1sAAAAASUVORK5CYII=',
      );
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: UniversalImage(
            path: old,
            errorBuilder: (_, _, _) => const Text('REPAIR FAILED'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 20 && attachments.calls == 0; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
    expect(find.text('REPAIR FAILED'), findsNothing);
    await tester.runAsync(() async {
      final row = await FileSyncTrack.getByRemotePath(remote);
      expect(row!.localPath, isNot(old));
      expect(await File(row.localPath).exists(), isTrue);
      expect(await File(old).exists(), isFalse);
      expect(
        (await Note.findById(101))!.attachments.single.image!.src,
        row.localPath,
      );
    });
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'later attachment failure retains original references and tracking',
    () async {
      final old = '${dir.path}/original.bin';
      await File(old).writeAsBytes(original);
      await saved(items: [imageAttachment(old)]);
      await track(old);
      final incoming = [
        NoteAttachment.sketch(
          SketchData(
            strokesFilePath: remote,
            strokesContentHash: FileSyncTrack.computeHash(replacement),
          ),
        ),
        imageAttachment(secondRemote),
      ];
      backend.firestore.response = (_, _) async =>
          OfflineSnapshot(value: payload(items: incoming, locked: true));
      attachments.response = (src) async {
        if (src == secondRemote) {
          throw TimeoutException('synthetic transfer failure');
        }
        return replacement;
      };
      expect(
        await NoteSyncService().retryFailedRemoteNote('remote-note'),
        isFalse,
      );
      expect((await Note.findById(101))!.attachments.single.image!.src, old);
      expect(await File(old).readAsBytes(), original);
      expect(await FileSyncTrack.getByLocalPath(old), isNotNull);
      expect((await FileSyncTrack.getByRemotePath(remote))!.localPath, old);
    },
  );
  test('background local read failure defers the entire apply', () async {
    final old = '${dir.path}/unreadable.bin';
    await File(old).writeAsBytes(original);
    final local = await saved(
      items: [NoteAttachment.sketch(SketchData(backgroundImage: old))],
    );
    await track(old);
    final strokes = local.attachments.single.sketch!.strokesFilePath!;
    await FileSyncTrack(
      noteId: 101,
      localPath: strokes,
      remotePath: secondRemote,
    ).save();
    final chmod = await Process.run('/bin/chmod', ['000', old]);
    expect(chmod.exitCode, 0);
    try {
      backend.firestore.response = (_, _) async => OfflineSnapshot(
        value: payload(
          items: [
            NoteAttachment.sketch(
              SketchData(
                strokesFilePath: secondRemote,
                backgroundImage: remote,
              ),
            ),
          ],
        ),
      );
      final applied = await NoteSyncService().retryFailedRemoteNote(
        'remote-note',
      );
      expect(applied, isFalse);
      expect(attachments.calls, 0);
      expect(
        (await Note.findById(101))!.attachments.single.sketch!.backgroundImage,
        old,
      );
      backend.firestore.queryResponse = (_, _) async =>
          OfflineQuerySnapshot({});
      AppState.noteCloudSyncCheckpoint = const CloudSyncCheckpoint(
        bootstrapped: true,
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        expect(
          await NoteSyncService().refreshWithOutcome(),
          SyncRefreshOutcome.failed,
        );
        final deferred = (await RemoteContentRetryLedger().get(
          'account-a',
          'remote-note',
        ))!;
        expect(deferred.attempts, 0);
        expect(deferred.state, RemoteContentRetryState.deferred);
        expect(deferred.nextRetryAt, isNull);
        expect(NoteSyncService().isSyncing.value, isFalse);
      }
    } finally {
      await Process.run('/bin/chmod', ['600', old]);
    }
    expect(
      await NoteSyncService().refreshWithOutcome(),
      SyncRefreshOutcome.complete,
    );
    expect((await Note.findById(101))!.title, 'Remote');
    expect(
      await RemoteContentRetryLedger().get('account-a', 'remote-note'),
      isNull,
    );
  });
  test(
    'deletion retries Storage cleanup after the tombstone committed',
    () async {
      allowPaid();
      backend.storage.failList = true;
      backend.firestore.documents['users/account-a/notes/remote-note'] = {
        'local_id': 101,
        'updated_at': '2026-09-01T00:00:00Z',
        'deleted': false,
      };
      await NoteSyncTrack(
        localId: 101,
        remoteId: 'remote-note',
        action: SyncAction.delete,
      ).save();
      await NoteSyncService().sync(true);
      expect(backend.storage.lists, 1);
      expect(await NoteSyncTrack.getByLocalId(101), isNotNull);
      expect(
        backend
            .firestore
            .documents['users/account-a/notes/remote-note']!['deleted'],
        isTrue,
      );
      backend.storage.failList = false;
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      await NoteSyncService().sync(true);
      expect(backend.storage.lists, 2);
      expect(await NoteSyncTrack.getByLocalId(101), isNull);
    },
  );
  test(
    'partial Storage deletion retries remaining files after service restart',
    () async {
      allowPaid();
      backend.firestore.documents['users/account-a/notes/remote-note'] = {
        'deleted': true,
      };
      backend.storage.objects.addAll(['first', 'second']);
      backend.storage.delete = (value) async {
        if (value == 'second') throw TimeoutException('offline');
      };
      await NoteSyncTrack(
        localId: 101,
        remoteId: 'remote-note',
        action: SyncAction.delete,
      ).save();
      await NoteSyncService().sync(true);
      expect(backend.storage.objects, {'second'});
      expect(await NoteSyncTrack.getByLocalId(101), isNotNull);
      await NoteSyncService().dispose();
      backend.storage.delete = null;
      AuthService.cloudRecovery.state.value = CloudSessionState.ready;
      await NoteSyncService().sync(true);
      expect(backend.storage.objects, isEmpty);
      expect(await NoteSyncTrack.getByLocalId(101), isNull);
    },
  );

  test(
    'authoritative document absence still requires Storage cleanup',
    () async {
      allowPaid();
      backend.firestore.response = (_, _) async => OfflineSnapshot(value: null);
      backend.storage.objects.add('orphan');
      await NoteSyncTrack(
        localId: 101,
        remoteId: 'remote-note',
        action: SyncAction.delete,
      ).save();
      await NoteSyncService().sync(true);
      expect(backend.storage.lists, 1);
      expect(backend.storage.objects, isEmpty);
      expect(await NoteSyncTrack.getByLocalId(101), isNull);
    },
  );

  test(
    'newly queued deletion survives an older cleanup acknowledgement',
    () async {
      allowPaid();
      backend.firestore.documents['users/account-a/notes/remote-note'] = {
        'deleted': true,
      };
      backend.storage.objects.add('file');
      backend.storage.delete = (_) async {
        final pending = await NoteSyncTrack.getByLocalId(101);
        await pending!.setAction(SyncAction.delete);
      };
      await NoteSyncTrack(
        localId: 101,
        remoteId: 'remote-note',
        action: SyncAction.delete,
      ).save();
      await NoteSyncService().sync(true);
      expect(await NoteSyncTrack.getByLocalId(101), isNotNull);
    },
  );

  test(
    'ordering manifest completion after pause leaves local work pending',
    () async {
      allowPaid();
      final sort = NoteSortService(), cloud = _PausedSortRepository();
      final started = Completer<void>(), released = Completer<void>();
      cloud.release.complete();
      cloud.beforeCommit = () async {
        started.complete();
        await released.future;
      };
      NoteSortService.cloudRepositoryOverride = cloud;
      await sort.init();
      final snapshot = NoteOrderSnapshot(
        context: const NoteOrderContext.mainGrid(),
        mode: NoteSortMode.custom,
        orderedNoteIds: ['note-a'],
        revision: 'manifest-pause',
        updatedAt: DateTime.now(),
        dirty: true,
      );
      final upload = sort.uploadSnapshotWithRetryForTesting(snapshot);
      await started.future;
      AuthService.cloudRecovery.connectionLost();
      released.complete();
      await upload;
      expect(sort.snapshots.value[snapshot.context.key]!.dirty, isTrue);
      expect(
        (await db.query(
          NoteSortService.tableName,
          where: 'context_key = ?',
          whereArgs: [snapshot.context.key],
        )).single['dirty'],
        1,
      );
    },
  );

  test(
    'ordering pause at SQLite acknowledgement rolls back the clean state',
    () async {
      allowPaid();
      final sort = NoteSortService(), cloud = _PausedSortRepository();
      final proxy = _TransactionBarrierDatabase(db);
      cloud.release.complete();
      cloud.beforeCommit = () async {
        proxy.beforeTransaction = () async {
          AuthService.cloudRecovery.connectionLost();
        };
      };
      AppState.db = proxy;
      NoteSortService.cloudRepositoryOverride = cloud;
      await sort.init();
      final snapshot = NoteOrderSnapshot(
        context: const NoteOrderContext.mainGrid(),
        mode: NoteSortMode.custom,
        orderedNoteIds: ['note-a'],
        revision: 'ack-pause',
        updatedAt: DateTime.now(),
        dirty: true,
      );
      await sort.uploadSnapshotWithRetryForTesting(snapshot);
      AppState.db = db;
      expect(proxy.interceptions, 1);
      expect(sort.snapshots.value[snapshot.context.key]!.dirty, isTrue);
      expect(
        (await db.query(
          NoteSortService.tableName,
          where: 'context_key = ?',
          whereArgs: [snapshot.context.key],
        )).single['dirty'],
        1,
      );
    },
  );

  test('ordering upload keeps pending work when recovery pauses', () async {
    allowPaid();
    final sort = NoteSortService();
    final cloud = _PausedSortRepository();
    NoteSortService.cloudRepositoryOverride = cloud;
    await sort.init();
    final snapshot = NoteOrderSnapshot(
      context: const NoteOrderContext.mainGrid(),
      mode: NoteSortMode.custom,
      orderedNoteIds: ['note-a'],
      revision: 'probe-revision',
      updatedAt: DateTime.now(),
      dirty: true,
    );
    final operation = sort.uploadSnapshotWithRetryForTesting(snapshot);
    await cloud.started.future;
    AuthService.cloudRecovery.connectionLost();
    expect(sort.canReceiveCloudForTesting, isFalse);
    cloud.release.complete();
    await operation;
    expect(cloud.commits, 0);
    expect(sort.snapshots.value[snapshot.context.key]!.dirty, isTrue);
    expect(await db.query(NoteSortService.cleanupTableName), isNotEmpty);
    AuthService.cloudRecovery.state.value = CloudSessionState.ready;
    await sort.uploadSnapshotWithRetryForTesting(snapshot);
    expect(cloud.commits, 1);
    expect(sort.snapshots.value[snapshot.context.key]!.dirty, isFalse);
    expect(await db.query(NoteSortService.cleanupTableName), isEmpty);
  });
}

NoteAttachment imageAttachment(String path) => NoteAttachment.image(
  NoteImage(
    src: path,
    size: 3,
    index: 0,
    aspectRatio: '1:1',
    lastModified: '2026-01-01',
  ),
);
Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Probe condition timed out');
}

class _Attachments extends AttachmentStorageRepository {
  int calls = 0;
  Future<Uint8List?> Function(String)? response;
  @override
  StorageObjectLocator parse(String s) => StorageObjectLocator.parse(
    s,
    configuredBucket: 'offline-test.invalid',
    emulatorMode: false,
  );
  @override
  Future<Uint8List?> download(String s) {
    calls++;
    return response!(s);
  }
}

class _TransactionBarrierDatabase implements Database {
  _TransactionBarrierDatabase(this.db);
  final Database db;
  Future<void> Function()? beforeTransaction;
  Future<void> Function()? afterTransaction;
  int interceptions = 0;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) async {
    final hook = beforeTransaction;
    beforeTransaction = null;
    if (hook != null) {
      interceptions++;
      await hook();
    }
    final result = await db.transaction(action, exclusive: exclusive);
    await afterTransaction?.call();
    return result;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => db.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => db.rawQuery(sql, arguments);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      db.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<void> execute(String sql, [List<Object?>? args]) =>
      db.execute(sql, args);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? args]) =>
      db.rawInsert(sql, args);
  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => db.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: conflictAlgorithm,
  );
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _PausedSortRepository implements NoteSortCloudRepository {
  final started = Completer<void>(), release = Completer<void>();
  int commits = 0;
  Future<void> Function()? beforeCommit;
  @override
  int get schemaVersion => NoteSortService.cloudSchemaVersion;
  @override
  Future<void> writeChunks(String revision, List<List<String>> chunks) async {
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<NoteSortCloudCommitResult> commitManifest({
    required String contextKey,
    required String sortMode,
    required String revision,
    required String? baseRevision,
    required int chunkCount,
    required int noteCount,
  }) async {
    await beforeCommit?.call();
    commits++;
    return const NoteSortCloudCommitResult.committed(
      previousRevision: null,
      previousChunkCount: 0,
    );
  }

  @override
  Future<void> deleteRevision(String revision, int count) async {}
  @override
  Future<Map<String, dynamic>?> readManifest(String contextKey) async => null;
  @override
  Future<List<Map<String, dynamic>>?> readChunks(
    String revision,
    int chunkCount,
  ) async => null;
}
