import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/sync_identity_migration.dart';
import 'package:better_keep/state.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  final service = NoteSortService();
  const grid = NoteOrderContext.mainGrid();
  const list = NoteOrderContext.mainList();
  late E2EEStatus originalE2EEStatus;
  late Uint8List? originalUMK;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    await service.dispose();
    originalE2EEStatus = E2EEService.instance.status.value;
    originalUMK = E2EEService.instance.deviceManager.getUMK();
    E2EEService.instance.status.value = E2EEStatus.notInitialized;
    NoteSortService.canReceiveCloudOverride = null;
    NoteSortService.canPushCloudOverride = null;
    NoteSortService.e2eeReadyOverride = true;
    NoteSortService.cloudStartOverride = null;
    NoteSortService.cloudRepositoryOverride = null;
    NoteSortService.uploadRetryDelayOverride = null;
    NoteSortService.disposeTimeoutOverride = null;
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await Note.createTable(database);
    await Label.createTable(database);
    await NoteSyncTrack.createTable(database);
    await LabelSyncTrack.createTable(database);
    await NoteSortService.createTable(database);
    await service.init();
  });

  tearDown(() async {
    await service.dispose();
    NoteSortService.canReceiveCloudOverride = null;
    NoteSortService.canPushCloudOverride = null;
    NoteSortService.e2eeReadyOverride = null;
    NoteSortService.cloudStartOverride = null;
    NoteSortService.cloudRepositoryOverride = null;
    NoteSortService.uploadRetryDelayOverride = null;
    NoteSortService.disposeTimeoutOverride = null;
    E2EEService.instance.status.value = originalE2EEStatus;
    E2EEService.instance.deviceManager.setCachedUMKForTesting(originalUMK);
    await database.close();
  });

  test('cloud startup requires a ready E2EE state and UMK', () async {
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.e2eeReadyOverride = null;
    E2EEService.instance.deviceManager.setCachedUMKForTesting(null);
    var starts = 0;
    NoteSortService.cloudStartOverride = () async {
      starts++;
    };

    for (final status in const [
      E2EEStatus.notInitialized,
      E2EEStatus.notSetUp,
      E2EEStatus.pendingApproval,
      E2EEStatus.needsRecovery,
      E2EEStatus.revoked,
      E2EEStatus.error,
    ]) {
      E2EEService.instance.status.value = status;
      expect(
        service.canReceiveCloudForTesting,
        isFalse,
        reason: '$status must not permit cloud access',
      );
      await service.startCloudSync();
    }

    expect(starts, 0);
    E2EEService.instance.status.value = E2EEStatus.ready;
    expect(service.canReceiveCloudForTesting, isFalse);
    await service.dispose();
    E2EEService.instance.deviceManager.setCachedUMK(
      Uint8List.fromList(List<int>.filled(32, 1)),
    );
    for (final status in const [
      E2EEStatus.ready,
      E2EEStatus.verifyingInBackground,
    ]) {
      E2EEService.instance.status.value = status;
      expect(
        service.canReceiveCloudForTesting,
        isTrue,
        reason: '$status must permit cloud access',
      );
    }
  });

  test('E2EE readiness starts Note Sort cloud sync only once', () async {
    final cloud = _FakeNoteSortCloudRepository();
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.e2eeReadyOverride = null;
    E2EEService.instance.deviceManager.setCachedUMK(
      Uint8List.fromList(List<int>.filled(32, 1)),
    );
    var starts = 0;
    NoteSortService.cloudStartOverride = () async {
      starts++;
      service.activateCloudRunForTesting();
    };
    E2EEService.instance.status.value = E2EEStatus.error;

    E2EEService.instance.status.value = E2EEStatus.ready;
    await _waitUntil(() => service.hasActiveCloudRunForTesting);
    E2EEService.instance.status.value = E2EEStatus.verifyingInBackground;
    await Future<void>.delayed(Duration.zero);

    expect(starts, 1);
    expect(service.hasActiveCloudRunForTesting, isTrue);
  });

  test(
    'losing E2EE readiness invalidates cloud work but keeps local state',
    () async {
      final cloud = _FakeNoteSortCloudRepository();
      NoteSortService.cloudRepositoryOverride = cloud;
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.e2eeReadyOverride = null;
      E2EEService.instance.deviceManager.setCachedUMK(
        Uint8List.fromList(List<int>.filled(32, 1)),
      );
      await service.setMode(grid, NoteSortMode.custom);
      service.activateCloudRunForTesting();
      final generation = service.cloudGenerationForTesting;
      final localSnapshot = service.snapshotFor(grid);

      E2EEService.instance.status.value = E2EEStatus.ready;
      E2EEService.instance.status.value = E2EEStatus.error;
      await _waitUntil(() => !service.hasActiveCloudRunForTesting);

      expect(service.cloudGenerationForTesting, greaterThan(generation));
      expect(service.snapshotFor(grid), localSnapshot);

      service.activateCloudRunForTesting();
      E2EEService.instance.status.value = E2EEStatus.ready;
      E2EEService.instance.status.value = E2EEStatus.revoked;
      await _waitUntil(() => !service.hasActiveCloudRunForTesting);

      expect(service.snapshotFor(grid), localSnapshot);
    },
  );

  test(
    'E2EE retry resumes Note Sort cloud sync without reinitializing',
    () async {
      final cloud = _FakeNoteSortCloudRepository();
      NoteSortService.cloudRepositoryOverride = cloud;
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.e2eeReadyOverride = null;
      E2EEService.instance.deviceManager.setCachedUMK(
        Uint8List.fromList(List<int>.filled(32, 1)),
      );
      var starts = 0;
      NoteSortService.cloudStartOverride = () async {
        starts++;
        service.activateCloudRunForTesting();
      };
      E2EEService.instance.status.value = E2EEStatus.error;

      E2EEService.instance.status.value = E2EEStatus.ready;
      await _waitUntil(() => service.hasActiveCloudRunForTesting);
      E2EEService.instance.status.value = E2EEStatus.error;
      await _waitUntil(() => !service.hasActiveCloudRunForTesting);
      E2EEService.instance.status.value = E2EEStatus.ready;
      await _waitUntil(() => starts == 2);

      expect(service.hasActiveCloudRunForTesting, isTrue);
    },
  );

  test('disposal removes the E2EE lifecycle listener', () async {
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.e2eeReadyOverride = null;
    E2EEService.instance.deviceManager.setCachedUMK(
      Uint8List.fromList(List<int>.filled(32, 1)),
    );
    var starts = 0;
    NoteSortService.cloudStartOverride = () async {
      starts++;
    };
    E2EEService.instance.status.value = E2EEStatus.error;

    // A callback queued just before disposal must not reopen cloud activity.
    E2EEService.instance.status.value = E2EEStatus.ready;
    await service.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(starts, 0);
    expect(service.hasActiveCloudRunForTesting, isFalse);

    // Disposal must also remove the listener for later status changes.
    E2EEService.instance.status.value = E2EEStatus.error;
    E2EEService.instance.status.value = E2EEStatus.ready;
    await Future<void>.delayed(Duration.zero);
    expect(starts, 0);
  });

  test('creates independent default main contexts', () async {
    expect(service.snapshotFor(grid).mode, NoteSortMode.custom);
    expect(service.snapshotFor(list).mode, NoteSortMode.custom);

    final rows = await database.query(NoteSortService.tableName);
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['context_key']).toSet(), {
      'main:grid',
      'main:list',
    });
  });

  test('missing in-memory contexts use their context defaults', () {
    service.snapshots.value = const {};

    expect(service.snapshotFor(grid).mode, NoteSortMode.custom);
    expect(service.snapshotFor(list).mode, NoteSortMode.custom);
    expect(
      service.snapshotFor(const NoteOrderContext.pinned()).mode,
      NoteSortMode.updatedNewest,
    );
    expect(
      service.snapshotFor(NoteOrderContext.system('archived')).mode,
      NoteSortMode.updatedNewest,
    );
  });

  test('missing persisted Home context is created as custom', () async {
    await database.delete(
      NoteSortService.positionTableName,
      where: 'context_key = ?',
      whereArgs: [grid.key],
    );
    await database.delete(
      NoteSortService.operationTableName,
      where: 'context_key = ?',
      whereArgs: [grid.key],
    );
    await database.delete(
      NoteSortService.tableName,
      where: 'context_key = ?',
      whereArgs: [grid.key],
    );
    service.snapshots.value = Map.unmodifiable({
      for (final entry in service.snapshots.value.entries)
        if (entry.key != grid.key) entry.key: entry.value,
    });

    final created = await service.ensureContext(grid, visibleNotes: const []);

    expect(created.mode, NoteSortMode.custom);
    final rows = await database.query(
      NoteSortService.tableName,
      columns: ['sort_mode'],
      where: 'context_key = ?',
      whereArgs: [grid.key],
    );
    expect(rows.single['sort_mode'], NoteSortMode.custom.name);
  });

  test('saved Home sort mode overrides the default', () async {
    await service.setMode(grid, NoteSortMode.updatedNewest);
    await service.dispose();
    await service.init();

    expect(service.snapshotFor(grid).mode, NoteSortMode.updatedNewest);
  });

  test('context keys round-trip and label names are not identities', () {
    final contexts = <NoteOrderContext>[
      grid,
      list,
      const NoteOrderContext.pinned(),
      NoteOrderContext.label('remote-label/id'),
      NoteOrderContext.color(0xff123456),
      NoteOrderContext.system('archived'),
    ];

    for (final context in contexts) {
      expect(NoteOrderContext.tryParse(context.key), context);
    }
  });

  test('context snapshot decoder rejects duplicate stable IDs', () {
    final row = <String, Object?>{
      'context_key': grid.key,
      'sort_mode': 'custom',
      'revision': 'revision',
      'base_revision': null,
      'updated_at': DateTime.utc(2026, 7, 24).toIso8601String(),
      'dirty': 0,
      'hydrated': 1,
    };

    expect(
      NoteOrderSnapshot.tryFromDatabaseJson(
        row,
        orderedNoteIds: const ['note-a', 'note-a'],
      ),
      isNull,
    );
    expect(
      NoteOrderSnapshot.tryFromDatabaseJson(
        row,
        orderedNoteIds: const ['note-a', 'note-b'],
      )?.orderedNoteIds,
      ['note-a', 'note-b'],
    );
  });

  test('cloud snapshots are chunked without losing stable identity order', () {
    final ids = List<String>.generate(4001, (index) => 'note-$index');
    final chunks = NoteSortService.chunkNoteIds(ids);

    expect(chunks.map((chunk) => chunk.length), [2000, 2000, 1]);
    expect(chunks.expand((chunk) => chunk), ids);
  });

  test('cloud chunk validation rejects partial and duplicate snapshots', () {
    final validChunk = <String, dynamic>{
      'schema_version': NoteSortService.cloudSchemaVersion,
      'revision': 'revision',
      'note_ids': ['note-a', 'note-b'],
    };

    expect(
      NoteSortService.decodeCloudChunks(
        revision: 'revision',
        noteCount: 2,
        chunkCount: 1,
        chunks: [validChunk],
      ),
      ['note-a', 'note-b'],
    );
    expect(
      NoteSortService.decodeCloudChunks(
        revision: 'revision',
        noteCount: 2,
        chunkCount: 2,
        chunks: [validChunk],
      ),
      isNull,
    );
    expect(
      NoteSortService.decodeCloudChunks(
        revision: 'revision',
        noteCount: 3,
        chunkCount: 2,
        chunks: [
          validChunk,
          {
            'schema_version': NoteSortService.cloudSchemaVersion,
            'revision': 'revision',
            'note_ids': ['note-b'],
          },
        ],
      ),
      isNull,
    );
  });

  test('remote sync cache pages use stable document IDs as identity', () {
    final first = PendingRemoteSync(
      localId: 42,
      remoteDocId: 'remote-a',
      remoteData: const {'local_id': 42},
      fetchedAt: DateTime.utc(2026, 7, 24),
    );
    final second = PendingRemoteSync(
      localId: 42,
      remoteDocId: 'remote-b',
      remoteData: const {'local_id': 42},
      fetchedAt: DateTime.utc(2026, 7, 24),
    );
    final legacyJson = <String, dynamic>{
      'page_index': 0,
      'syncs': {'42': first.toJson(), '43': second.toJson()},
      'has_more': false,
      'fetched_at': DateTime.utc(2026, 7, 24).toIso8601String(),
    };

    final restored = PendingRemoteSyncPage.fromJson(legacyJson);

    expect(restored.syncs.keys.toSet(), {'remote-a', 'remote-b'});
    expect(restored.toJson()['syncs'], containsPair('remote-a', isA<Map>()));
    expect(restored.toJson()['syncs'], containsPair('remote-b', isA<Map>()));
  });

  test(
    'date comparators keep pinned notes first with deterministic ties',
    () async {
      final older = DateTime.utc(2026, 7, 20);
      final newer = DateTime.utc(2026, 7, 21);
      final notes = [
        Note(id: 1, syncId: 'a', createdAt: older, updatedAt: newer),
        Note(id: 2, syncId: 'b', createdAt: newer, updatedAt: older),
        Note(
          id: 3,
          syncId: 'c',
          pinned: true,
          createdAt: older,
          updatedAt: older,
        ),
        Note(id: 4, syncId: 'd', createdAt: newer, updatedAt: newer),
      ];

      expect(service.sortNotes(grid, notes).map((note) => note.id), [
        3,
        4,
        1,
        2,
      ]);
      await service.setMode(grid, NoteSortMode.createdNewest);
      expect(service.sortNotes(grid, notes).map((note) => note.id), [
        3,
        4,
        2,
        1,
      ]);
    },
  );

  test('custom mode seeds from updated-first order using stable IDs', () async {
    await service.setMode(grid, NoteSortMode.updatedNewest);
    await _insertNote(database, id: 1, updatedAt: DateTime.utc(2026, 7, 20));
    await _insertNote(database, id: 2, updatedAt: DateTime.utc(2026, 7, 22));
    await _insertNote(
      database,
      id: 3,
      updatedAt: DateTime.utc(2026, 7, 19),
      pinned: true,
    );

    await service.setMode(grid, NoteSortMode.custom);

    expect(service.snapshotFor(grid).mode, NoteSortMode.custom);
    expect(service.snapshotFor(grid).orderedNoteIds, [
      'note-3',
      'note-2',
      'note-1',
    ]);
    expect(service.snapshotFor(grid).dirty, isTrue);
  });

  test('main grid and list retain independent orders and modes', () async {
    for (var id = 1; id <= 3; id++) {
      await _insertNote(
        database,
        id: id,
        updatedAt: DateTime.utc(2026, 7, 25 - id),
      );
    }
    final notes = await Note.get(NoteType.all);
    await service.setMode(grid, NoteSortMode.custom);
    await service.reorderVisibleNotes(
      context: grid,
      draggedId: 3,
      targetId: 1,
      placeAfter: false,
      visibleNotes: notes,
    );

    expect(service.snapshotFor(grid).orderedNoteIds, [
      'note-3',
      'note-1',
      'note-2',
    ]);
    expect(service.snapshotFor(list).mode, NoteSortMode.custom);
    expect(service.snapshotFor(list).orderedNoteIds, isEmpty);
  });

  test(
    'folder reorder changes only that folder and preserves hidden IDs',
    () async {
      for (var id = 1; id <= 4; id++) {
        await _insertNote(
          database,
          id: id,
          updatedAt: DateTime.utc(2026, 7, 25 - id),
        );
      }
      final all = await Note.get(NoteType.all);
      final folder = NoteOrderContext.label('label-remote-id');
      await service.ensureContext(folder, visibleNotes: all);
      await service.setMode(folder, NoteSortMode.custom);

      final visible = all.where((note) => note.id != 2).toList();
      final changed = await service.reorderVisibleNotes(
        context: folder,
        draggedId: 4,
        targetId: 1,
        placeAfter: false,
        visibleNotes: visible,
      );

      expect(changed, isTrue);
      expect(service.snapshotFor(folder).orderedNoteIds, [
        'note-4',
        'note-1',
        'note-2',
        'note-3',
      ]);
      expect(service.snapshotFor(grid).orderedNoteIds, isEmpty);
    },
  );

  test('pinned and unpinned notes cannot cross sections', () async {
    await _insertNote(
      database,
      id: 1,
      updatedAt: DateTime.utc(2026, 7, 24),
      pinned: true,
    );
    await _insertNote(database, id: 2, updatedAt: DateTime.utc(2026, 7, 23));
    final notes = await Note.get(NoteType.all);
    await service.setMode(grid, NoteSortMode.custom);

    await expectLater(
      service.reorderVisibleNotes(
        context: grid,
        draggedId: 1,
        targetId: 2,
        placeAfter: true,
        visibleNotes: notes,
      ),
      throwsA(isA<PinnedSectionReorderException>()),
    );
  });

  test(
    'remote snapshot preserves IDs for notes not hydrated locally',
    () async {
      final remote = NoteOrderSnapshot(
        context: grid,
        mode: NoteSortMode.custom,
        orderedNoteIds: const ['remote-a', 'remote-b', 'remote-c'],
        revision: 'remote-revision',
        baseRevision: 'remote-revision',
        updatedAt: DateTime.utc(2026, 7, 24),
        hydrated: true,
      );

      await service.applyRemoteSnapshotForTesting(remote);

      expect(service.snapshotFor(grid).orderedNoteIds, [
        'remote-a',
        'remote-b',
        'remote-c',
      ]);
      expect(service.snapshotFor(grid).dirty, isFalse);
    },
  );

  test('remote note imports never dirty or rebuild an order', () async {
    final remote = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['remote-a', 'remote-b'],
      revision: 'remote-revision',
      baseRevision: 'remote-revision',
      updatedAt: DateTime.utc(2026, 7, 24),
      hydrated: true,
    );
    await service.applyRemoteSnapshotForTesting(remote);

    final imported = Note(
      syncId: 'remote-a',
      title: 'Downloaded',
      content: '[]',
    );
    await imported.save(false, ModelChangeOrigin.remoteSync);
    await Future<void>.delayed(Duration.zero);

    expect(service.snapshotFor(grid).orderedNoteIds, ['remote-a', 'remote-b']);
    expect(service.snapshotFor(grid).dirty, isFalse);
    expect(await database.query(NoteSortService.operationTableName), isEmpty);
  });

  test('local folder membership changes are added to that context', () async {
    final label = Label(name: 'Work', syncId: 'label-work');
    await label.save(sync: false);
    await _insertNote(database, id: 1, updatedAt: DateTime.utc(2026, 7, 24));
    final folder = NoteOrderContext.label(label.syncId!);
    await service.ensureContext(folder, visibleNotes: const []);
    await service.setMode(folder, NoteSortMode.custom);

    final note = (await Note.get(NoteType.all)).single;
    note.labels = label.name;
    await note.save(false);
    await _waitUntil(
      () => service.snapshotFor(folder).orderedNoteIds.contains('note-1'),
    );

    expect(service.snapshotFor(folder).orderedNoteIds, ['note-1']);
  });

  test('rapid lifecycle events always mutate the latest snapshot', () async {
    await service.setMode(grid, NoteSortMode.custom);
    final first = Note(id: 1, syncId: 'note-1');
    final second = Note(id: 2, syncId: 'note-2');

    await Future.wait([
      service.applyNoteEventForTesting(
        ModelEvent('created', first, origin: ModelChangeOrigin.local),
      ),
      service.applyNoteEventForTesting(
        ModelEvent('created', second, origin: ModelChangeOrigin.local),
      ),
    ]);

    expect(service.snapshotFor(grid).orderedNoteIds.toSet(), {
      'note-1',
      'note-2',
    });
    expect(service.snapshotFor(grid).mode, NoteSortMode.custom);

    await Future.wait([
      service.applyNoteEventForTesting(
        ModelEvent('deleted', first, origin: ModelChangeOrigin.local),
      ),
      service.applyNoteEventForTesting(
        ModelEvent('created', first, origin: ModelChangeOrigin.local),
      ),
    ]);
    expect(service.snapshotFor(grid).orderedNoteIds.toSet(), {
      'note-1',
      'note-2',
    });
  });

  test('label renames retain the same folder context identity', () async {
    final label = Label(name: 'Before', syncId: 'stable-label-id');
    await label.save(sync: false);
    final before = NoteOrderContext.label(label.syncId!);
    await service.ensureContext(before, visibleNotes: const []);

    label.name = 'After';
    await label.save(sync: false);
    final after = NoteOrderContext.label(label.syncId!);

    expect(after, before);
    expect(
      service.snapshotFor(after).revision,
      service.snapshotFor(before).revision,
    );
  });

  test('pending local move rebases onto a newer remote context', () async {
    for (var id = 1; id <= 3; id++) {
      await _insertNote(
        database,
        id: id,
        updatedAt: DateTime.utc(2026, 7, 25 - id),
      );
    }
    final firstRemote = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['note-1', 'note-2', 'note-3'],
      revision: 'remote-1',
      baseRevision: 'remote-1',
      updatedAt: DateTime.utc(2026, 7, 23),
      hydrated: true,
    );
    await service.applyRemoteSnapshotForTesting(firstRemote);
    final notes = await Note.get(NoteType.all);
    await service.reorderVisibleNotes(
      context: grid,
      draggedId: 3,
      targetId: 1,
      placeAfter: false,
      visibleNotes: notes,
    );

    final concurrentRemote = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['note-1', 'remote-unknown', 'note-2', 'note-3'],
      revision: 'remote-2',
      baseRevision: 'remote-2',
      updatedAt: DateTime.utc(2026, 7, 24),
      hydrated: true,
    );
    await service.applyRemoteSnapshotForTesting(concurrentRemote);

    final rebased = service.snapshotFor(grid);
    expect(rebased.orderedNoteIds, [
      'note-3',
      'note-1',
      'remote-unknown',
      'note-2',
    ]);
    expect(rebased.baseRevision, 'remote-2');
    expect(rebased.dirty, isTrue);
  });

  test('remote events are applied in listener delivery order', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final older = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['older'],
      revision: 'remote-older',
      baseRevision: 'remote-older',
      updatedAt: DateTime.utc(2026, 7, 23),
      hydrated: true,
    );
    final newer = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['newer'],
      revision: 'remote-newer',
      baseRevision: 'remote-newer',
      updatedAt: DateTime.utc(2026, 7, 24),
      hydrated: true,
    );

    final first = service.enqueueRemoteDecodeForTesting(1, () async {
      firstStarted.complete();
      await releaseFirst.future;
      return older;
    });
    await firstStarted.future;
    final second = service.enqueueRemoteDecodeForTesting(1, () async => newer);

    releaseFirst.complete();
    await Future.wait([first, second]);

    expect(service.snapshotFor(grid).revision, 'remote-newer');
    expect(service.snapshotFor(grid).orderedNoteIds, ['newer']);
  });

  test('committed drag rebases its move over deferred remote state', () async {
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.canPushCloudOverride = false;
    for (var id = 1; id <= 3; id++) {
      await _insertNote(
        database,
        id: id,
        updatedAt: DateTime.utc(2026, 7, 25 - id),
      );
    }
    await service.applyRemoteSnapshotForTesting(
      NoteOrderSnapshot(
        context: grid,
        mode: NoteSortMode.custom,
        orderedNoteIds: const ['note-1', 'note-2', 'note-3'],
        revision: 'drag-base',
        baseRevision: 'drag-base',
        updatedAt: DateTime.utc(2026, 7, 23),
        hydrated: true,
      ),
    );

    service.beginDrag(grid);
    await service.receiveRemoteSnapshotForTesting(
      NoteOrderSnapshot(
        context: grid,
        mode: NoteSortMode.custom,
        orderedNoteIds: const [
          'note-1',
          'remote-during-drag',
          'note-2',
          'note-3',
        ],
        revision: 'drag-remote',
        baseRevision: 'drag-remote',
        updatedAt: DateTime.utc(2026, 7, 24),
        hydrated: true,
      ),
    );
    await service.reorderVisibleNotes(
      context: grid,
      draggedId: 3,
      targetId: 1,
      placeAfter: false,
      visibleNotes: await Note.get(NoteType.all),
    );
    await service.endDrag(grid, committed: true);

    final rebased = service.snapshotFor(grid);
    expect(rebased.orderedNoteIds, [
      'note-3',
      'note-1',
      'remote-during-drag',
      'note-2',
    ]);
    expect(rebased.baseRevision, 'drag-remote');
    expect(rebased.dirty, isTrue);
  });

  test('cancelled drag applies deferred remote state directly', () async {
    await service.applyRemoteSnapshotForTesting(
      NoteOrderSnapshot(
        context: list,
        mode: NoteSortMode.custom,
        orderedNoteIds: const ['before'],
        revision: 'cancel-base',
        baseRevision: 'cancel-base',
        updatedAt: DateTime.utc(2026, 7, 23),
        hydrated: true,
      ),
    );

    service.beginDrag(list);
    await service.receiveRemoteSnapshotForTesting(
      NoteOrderSnapshot(
        context: list,
        mode: NoteSortMode.custom,
        orderedNoteIds: const ['after'],
        revision: 'cancel-remote',
        baseRevision: 'cancel-remote',
        updatedAt: DateTime.utc(2026, 7, 24),
        hydrated: true,
      ),
    );
    await service.endDrag(list, committed: false);

    final applied = service.snapshotFor(list);
    expect(applied.revision, 'cancel-remote');
    expect(applied.orderedNoteIds, ['after']);
    expect(applied.dirty, isFalse);
  });

  test('failed chunk upload is journaled and cleaned safely', () async {
    final cloud = _FakeNoteSortCloudRepository()..failWrites = true;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    final snapshot = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['note-a'],
      revision: 'candidate-revision',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
    );

    await service.uploadSnapshotForTesting(snapshot);

    expect(cloud.deletedRevisions, ['candidate-revision']);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test('manifest conflict removes candidate chunks before rebase', () async {
    final cloud = _FakeNoteSortCloudRepository()..conflictOnCommit = true;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    final snapshot = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['note-a'],
      revision: 'conflicting-revision',
      baseRevision: 'old-revision',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
    );

    await service.uploadSnapshotForTesting(snapshot);

    expect(cloud.deletedRevisions, ['conflicting-revision']);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test(
    'manifest conflict rebases once and commits the local operation',
    () async {
      final cloud = _FakeNoteSortCloudRepository()..conflictCount = 1;
      cloud.manifests[grid.key] = {
        'schema_version': NoteSortService.cloudSchemaVersion,
        'context_key': grid.key,
        'sort_mode': NoteSortMode.updatedNewest.name,
        'revision': 'remote-2',
        'chunk_count': 1,
        'note_count': 1,
      };
      cloud.chunks['remote-2'] = [
        {
          'schema_version': NoteSortService.cloudSchemaVersion,
          'revision': 'remote-2',
          'note_ids': ['remote-note'],
        },
      ];
      NoteSortService.cloudRepositoryOverride = cloud;
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.canPushCloudOverride = true;

      await service.applyRemoteSnapshotForTesting(
        NoteOrderSnapshot(
          context: grid,
          mode: NoteSortMode.updatedNewest,
          orderedNoteIds: const ['remote-note'],
          revision: 'remote-1',
          baseRevision: 'remote-1',
          updatedAt: DateTime.utc(2026, 7, 24),
          hydrated: true,
        ),
      );
      await service.setMode(grid, NoteSortMode.custom);
      final conflicting = service.snapshotFor(grid);

      await service.uploadSnapshotWithRetryForTesting(conflicting);
      await _waitUntil(
        () =>
            cloud.commitCalls >= 2 && service.snapshotFor(grid).dirty == false,
      );

      final committed = service.snapshotFor(grid);
      expect(cloud.commitCalls, 2);
      expect(cloud.deletedRevisions, contains(conflicting.revision));
      expect(committed.mode, NoteSortMode.custom);
      expect(committed.orderedNoteIds, ['remote-note']);
      expect(committed.baseRevision, committed.revision);
      expect(cloud.manifests[grid.key]?['revision'], committed.revision);
      expect(await database.query(NoteSortService.operationTableName), isEmpty);
    },
  );

  test('snapshot superseded during chunk upload never commits', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final cloud = _FakeNoteSortCloudRepository()
      ..writeStarted = writeStarted
      ..writeBarrier = releaseWrite;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.canPushCloudOverride = true;
    final candidate = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['candidate-note'],
      revision: 'superseded-candidate',
      baseRevision: 'remote-1',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
      hydrated: true,
    );

    final upload = service.uploadSnapshotWithRetryForTesting(candidate);
    await writeStarted.future;
    await service.applyRemoteSnapshotForTesting(
      NoteOrderSnapshot(
        context: grid,
        mode: NoteSortMode.updatedNewest,
        orderedNoteIds: const ['newer-remote-note'],
        revision: 'remote-2',
        baseRevision: 'remote-2',
        updatedAt: DateTime.utc(2026, 7, 25),
        hydrated: true,
      ),
    );
    releaseWrite.complete();
    await upload;

    expect(cloud.commitCalls, 0);
    expect(cloud.deletedRevisions, ['superseded-candidate']);
    expect(service.snapshotFor(grid).revision, 'remote-2');
    expect(service.snapshotFor(grid).dirty, isFalse);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test('cleanup journal never deletes a referenced revision', () async {
    final cloud = _FakeNoteSortCloudRepository();
    cloud.manifests[grid.key] = {'revision': 'active-revision'};
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    await _insertCleanup(
      database,
      contextKey: grid.key,
      revision: 'active-revision',
      chunkCount: 2,
    );

    await service.drainCloudCleanupForTesting();

    expect(cloud.deletedRevisions, isEmpty);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test('failed cleanup remains durable with retry metadata', () async {
    final cloud = _FakeNoteSortCloudRepository()..failDeletes = true;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    await _insertCleanup(
      database,
      contextKey: grid.key,
      revision: 'orphan-revision',
      chunkCount: 2,
    );

    await service.drainCloudCleanupForTesting();

    final rows = await database.query(NoteSortService.cleanupTableName);
    expect(rows, hasLength(1));
    expect(rows.single['revision'], 'orphan-revision');
    expect(rows.single['retry_count'], 1);
    expect(rows.single['next_retry_at'], isNotNull);
  });

  test('cleanup requested during a drain runs another pass', () async {
    final deleteStarted = Completer<void>();
    final releaseDelete = Completer<void>();
    final cloud = _FakeNoteSortCloudRepository()
      ..deleteStarted = deleteStarted
      ..deleteBarrier = releaseDelete;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    await _insertCleanup(
      database,
      contextKey: grid.key,
      revision: 'cleanup-first',
      chunkCount: 1,
    );

    final firstDrain = service.drainCloudCleanupForTesting();
    await deleteStarted.future;
    await _insertCleanup(
      database,
      contextKey: grid.key,
      revision: 'cleanup-second',
      chunkCount: 1,
    );
    await service.drainCloudCleanupForTesting();

    releaseDelete.complete();
    await firstDrain;
    await _waitUntil(
      () => cloud.deletedRevisions.toSet().containsAll({
        'cleanup-first',
        'cleanup-second',
      }),
    );

    expect(cloud.deletedRevisions, ['cleanup-first', 'cleanup-second']);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test('dirty snapshot retries automatically after upload failure', () async {
    final cloud = _FakeNoteSortCloudRepository()..failWriteCount = 1;
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.canPushCloudOverride = true;
    NoteSortService.uploadRetryDelayOverride = (_) => Duration.zero;
    final snapshot = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['retry-note'],
      revision: 'retry-revision',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
      hydrated: true,
    );

    await service.uploadSnapshotWithRetryForTesting(snapshot);
    await _waitUntil(
      () =>
          cloud.writeCalls >= 2 &&
          cloud.manifests[grid.key]?['revision'] == 'retry-revision' &&
          service.snapshotFor(grid).dirty == false,
    );

    expect(cloud.writeCalls, 2);
    expect(service.snapshotFor(grid).dirty, isFalse);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test('conflict recovery failure retries without another mutation', () async {
    final cloud = _FakeNoteSortCloudRepository()
      ..conflictCount = 1
      ..failReadManifestCalls.add(2);
    NoteSortService.cloudRepositoryOverride = cloud;
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.canPushCloudOverride = true;
    NoteSortService.uploadRetryDelayOverride = (_) => Duration.zero;
    final snapshot = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['conflict-note'],
      revision: 'conflict-retry',
      baseRevision: 'remote-before-conflict',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
      hydrated: true,
    );

    await service.uploadSnapshotWithRetryForTesting(snapshot);
    await _waitUntil(
      () =>
          cloud.commitCalls >= 2 &&
          cloud.manifests[grid.key]?['revision'] == 'conflict-retry' &&
          service.snapshotFor(grid).dirty == false,
    );

    expect(cloud.commitCalls, 2);
    expect(service.snapshotFor(grid).dirty, isFalse);
  });

  test(
    'authorization failure retains dirty state without retry loop',
    () async {
      final cloud = _FakeNoteSortCloudRepository()
        ..writeError = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
      NoteSortService.cloudRepositoryOverride = cloud;
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.canPushCloudOverride = true;
      NoteSortService.uploadRetryDelayOverride = (_) => Duration.zero;
      final snapshot = NoteOrderSnapshot(
        context: grid,
        mode: NoteSortMode.custom,
        orderedNoteIds: const ['denied-note'],
        revision: 'denied-revision',
        updatedAt: DateTime.utc(2026, 7, 24),
        dirty: true,
        hydrated: true,
      );

      await service.uploadSnapshotWithRetryForTesting(snapshot);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cloud.writeCalls, 1);
      expect(service.snapshotFor(grid).dirty, isTrue);
    },
  );

  test('timed-out upload cannot cross into a new cloud session', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final oldCloud = _FakeNoteSortCloudRepository()
      ..writeStarted = writeStarted
      ..writeBarrier = releaseWrite;
    NoteSortService.cloudRepositoryOverride = oldCloud;
    NoteSortService.canReceiveCloudOverride = true;
    NoteSortService.disposeTimeoutOverride = Duration.zero;
    final snapshot = NoteOrderSnapshot(
      context: grid,
      mode: NoteSortMode.custom,
      orderedNoteIds: const ['old-user-note'],
      revision: 'old-user-revision',
      updatedAt: DateTime.utc(2026, 7, 24),
      dirty: true,
      hydrated: true,
    );

    final oldUpload = service.uploadSnapshotForTesting(snapshot);
    await writeStarted.future;
    await service.dispose();

    await database.close();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await Note.createTable(database);
    await Label.createTable(database);
    await NoteSyncTrack.createTable(database);
    await LabelSyncTrack.createTable(database);
    await NoteSortService.createTable(database);

    final newCloud = _FakeNoteSortCloudRepository();
    NoteSortService.cloudRepositoryOverride = newCloud;
    await service.drainCloudCleanupForTesting();

    releaseWrite.complete();
    await oldUpload;

    expect(oldCloud.deletedRevisions, ['old-user-revision']);
    expect(newCloud.writeCalls, 0);
    expect(newCloud.commitCalls, 0);
    expect(newCloud.readManifestCalls, 0);
    expect(newCloud.deletedRevisions, isEmpty);
    expect(await database.query(NoteSortService.cleanupTableName), isEmpty);
  });

  test(
    'version 9 repairs duplicate sync identities without data loss',
    () async {
      final migrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(migrationDb.close);
      await migrationDb.execute(
        'CREATE TABLE note (id INTEGER PRIMARY KEY, sync_id TEXT)',
      );
      await migrationDb.execute('''CREATE TABLE sync_track (
        id INTEGER PRIMARY KEY,
        local_id INTEGER NOT NULL,
        remote_id TEXT,
        action TEXT NOT NULL,
        status TEXT,
        created_at TEXT,
        updated_at TEXT
      )''');
      await migrationDb.execute(
        'CREATE TABLE label '
        '(id INTEGER PRIMARY KEY, sync_id TEXT, name TEXT NOT NULL)',
      );
      await migrationDb.execute('''CREATE TABLE label_sync_track (
        id INTEGER PRIMARY KEY,
        local_id INTEGER NOT NULL,
        remote_id TEXT,
        action TEXT NOT NULL,
        status TEXT,
        created_at TEXT,
        updated_at TEXT
      )''');
      await NoteSortService.createTable(migrationDb);
      await migrationDb.insert('note', {
        'id': 1,
        'sync_id': 'shared-remote-id',
      });
      await migrationDb.insert('note', {'id': 2});
      await migrationDb.insert('note', {'id': 3, 'sync_id': 'local-only'});
      await migrationDb.insert('note', {'id': 4, 'sync_id': 'v8-random-id'});
      await migrationDb.insert('sync_track', {
        'local_id': 1,
        'remote_id': 'shared-remote-id',
        'action': 'upload',
        'status': 'synced',
      });
      await migrationDb.insert('sync_track', {
        'local_id': 1,
        'remote_id': 'stale-remote-id',
        'action': 'delete',
        'status': 'pending',
      });
      await migrationDb.insert('sync_track', {
        'local_id': 2,
        'remote_id': 'shared-remote-id',
        'action': 'upload',
        'status': 'synced',
      });
      await migrationDb.insert('sync_track', {
        'local_id': 4,
        'remote_id': 'canonical-remote-id',
        'action': 'upload',
        'status': 'synced',
      });
      await migrationDb.insert('sync_track', {
        'local_id': 4,
        'remote_id': 'stale-fourth-remote',
        'action': 'upload',
        'status': 'synced',
      });
      await migrationDb.insert('label', {'id': 1, 'name': 'One'});
      await migrationDb.insert('label', {'id': 2, 'name': 'Two'});
      await migrationDb.insert('label_sync_track', {
        'local_id': 1,
        'remote_id': 'shared-label-id',
        'action': 'upload',
        'status': 'synced',
      });
      await migrationDb.insert('label_sync_track', {
        'local_id': 2,
        'remote_id': 'shared-label-id',
        'action': 'upload',
        'status': 'failed',
      });
      await migrationDb.insert(NoteSortService.tableName, {
        'context_key': grid.key,
        'sort_mode': NoteSortMode.custom.name,
        'revision': 'local-revision',
        'updated_at': DateTime.utc(2026, 7, 24).toIso8601String(),
      });
      await migrationDb.insert(NoteSortService.positionTableName, {
        'context_key': grid.key,
        'note_sync_id': 'v8-random-id',
        'position': 0,
      });
      await migrationDb.insert(NoteSortService.positionTableName, {
        'context_key': grid.key,
        'note_sync_id': 'canonical-remote-id',
        'position': 1,
      });
      await migrationDb.insert(NoteSortService.operationTableName, {
        'id': 'pending-operation',
        'context_key': grid.key,
        'operation_type': NoteOrderOperationType.moveNote.name,
        'payload': '{"note_id":"v8-random-id"}',
        'created_at': DateTime.utc(2026, 7, 24).toIso8601String(),
      });

      await migrationDb.transaction(SyncIdentityMigration.migrate);
      await migrationDb.transaction(SyncIdentityMigration.migrate);

      final noteRows = await migrationDb.query('note', orderBy: 'id');
      final noteIds = noteRows
          .map((row) => row['sync_id'])
          .whereType<String>()
          .toList();
      final labelIds = (await migrationDb.query(
        'label',
        orderBy: 'id',
      )).map((row) => row['sync_id']).whereType<String>().toList();
      final noteTracks = await migrationDb.query(
        NoteSyncTrack.model,
        orderBy: 'local_id',
      );
      final labelTracks = await migrationDb.query(
        LabelSyncTrack.model,
        orderBy: 'local_id',
      );

      expect(noteRows, hasLength(4));
      expect(noteIds.toSet(), hasLength(4));
      expect(noteIds.first, 'shared-remote-id');
      expect(noteIds[1], isNot('shared-remote-id'));
      expect(noteIds[2], 'local-only');
      expect(noteIds[3], 'canonical-remote-id');
      expect(noteTracks, hasLength(3));
      expect(noteTracks.first, containsPair('remote_id', 'shared-remote-id'));
      expect(noteTracks.first, containsPair('action', 'delete'));
      expect(noteTracks.first, containsPair('status', 'pending'));
      expect(noteTracks[1], containsPair('remote_id', isNull));
      expect(noteTracks[1], containsPair('action', 'upload'));
      expect(noteTracks[1], containsPair('status', 'pending'));
      expect(noteTracks.last, containsPair('remote_id', 'canonical-remote-id'));

      expect(labelIds, hasLength(2));
      expect(labelIds.toSet(), hasLength(2));
      expect(labelIds, contains('shared-label-id'));
      expect(labelTracks, hasLength(2));
      expect(
        labelTracks.where((row) => row['remote_id'] == 'shared-label-id'),
        hasLength(1),
      );

      final noteIndexes = await migrationDb.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name IN ('note', 'sync_track')",
      );
      expect(
        noteIndexes.map((row) => row['name']),
        containsAll({
          'idx_note_sync_id',
          'idx_sync_track_local_id',
          'idx_sync_track_remote_id',
        }),
      );
      final positions = await migrationDb.query(
        NoteSortService.positionTableName,
        orderBy: 'position',
      );
      expect(positions.map((row) => row['note_sync_id']), [
        'canonical-remote-id',
      ]);
      final operations = await migrationDb.query(
        NoteSortService.operationTableName,
      );
      expect(operations.single['payload'], '{"note_id":"canonical-remote-id"}');
    },
  );

  test(
    'version 7 schema upgrade is reconciled by version 9 migration',
    () async {
      final migrationDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(migrationDb.close);
      await migrationDb.execute('CREATE TABLE note (id INTEGER PRIMARY KEY)');
      await migrationDb.execute('''CREATE TABLE sync_track (
        id INTEGER PRIMARY KEY,
        remote_id TEXT,
        action TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        status TEXT DEFAULT 'pending',
        created_at TEXT,
        updated_at TEXT
      )''');
      await migrationDb.execute(
        'CREATE TABLE label '
        '(id INTEGER PRIMARY KEY, name TEXT NOT NULL, is_system INTEGER)',
      );
      await migrationDb.execute('''CREATE TABLE label_sync_track (
        id INTEGER PRIMARY KEY,
        remote_id TEXT,
        action TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        status TEXT DEFAULT 'pending',
        created_at TEXT,
        updated_at TEXT
      )''');
      await migrationDb.insert('note', {'id': 1});
      await migrationDb.insert('label', {'id': 1, 'name': 'One'});

      await Note.upgradeTable(migrationDb, 7, 9);
      await Label.upgradeTable(migrationDb, 7, 9);
      await migrationDb.transaction(SyncIdentityMigration.migrate);

      final noteIds = (await migrationDb.query(
        'note',
      )).map((row) => row['sync_id']).whereType<String>().toList();
      final labelIds = (await migrationDb.query(
        'label',
      )).map((row) => row['sync_id']).whereType<String>().toList();
      expect(noteIds.single, isNotEmpty);
      expect(labelIds.single, isNotEmpty);
    },
  );

  test('version 7 migration creates normalized context tables', () async {
    await database.delete(NoteSortService.positionTableName);
    await database.delete(NoteSortService.operationTableName);
    await database.delete(NoteSortService.tableName);
    await database.insert(
      NoteSortService.legacyTableName,
      {
        'id': 1,
        'sort_mode': NoteSortMode.custom.name,
        'ordered_note_ids': '[2,1]',
        'revision': 'legacy-revision',
        'updated_at': DateTime.utc(2026, 7, 24).toIso8601String(),
        'dirty': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _insertNote(database, id: 1, updatedAt: DateTime.utc(2026, 7, 20));
    await _insertNote(database, id: 2, updatedAt: DateTime.utc(2026, 7, 21));

    await NoteSortService.upgradeTable(database, 7, 8);

    final contexts = await database.query(NoteSortService.tableName);
    expect(contexts, hasLength(2));
    final positions = await database.query(
      NoteSortService.positionTableName,
      where: 'context_key = ?',
      whereArgs: [grid.key],
      orderBy: 'position',
    );
    expect(positions.map((row) => row['note_sync_id']), ['note-2', 'note-1']);
  });
}

Future<void> _insertNote(
  Database database, {
  required int id,
  required DateTime updatedAt,
  bool pinned = false,
}) async {
  await database.insert('note', {
    'id': id,
    'sync_id': 'note-$id',
    'title': 'Note $id',
    'content': '[]',
    'pinned': pinned ? 1 : 0,
    'created_at': updatedAt.subtract(const Duration(days: 1)).toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _insertCleanup(
  Database database, {
  required String contextKey,
  required String revision,
  required int chunkCount,
}) async {
  await database.insert(NoteSortService.cleanupTableName, {
    'revision': revision,
    'context_key': contextKey,
    'chunk_count': chunkCount,
    'retry_count': 0,
    'created_at': DateTime.utc(2026, 7, 24).toIso8601String(),
  });
}

class _FakeNoteSortCloudRepository implements NoteSortCloudRepository {
  @override
  int get schemaVersion => NoteSortService.cloudSchemaVersion;

  final Map<String, Map<String, dynamic>> manifests = {};
  final Map<String, List<Map<String, dynamic>>> chunks = {};
  final List<String> deletedRevisions = [];
  bool failWrites = false;
  bool failDeletes = false;
  bool conflictOnCommit = false;
  int failWriteCount = 0;
  int conflictCount = 0;
  int writeCalls = 0;
  int commitCalls = 0;
  int readManifestCalls = 0;
  Object? writeError;
  Completer<void>? writeStarted;
  Completer<void>? writeBarrier;
  Completer<void>? deleteStarted;
  Completer<void>? deleteBarrier;
  final Set<int> failReadManifestCalls = {};

  @override
  Future<NoteSortCloudCommitResult> commitManifest({
    required String contextKey,
    required String sortMode,
    required String revision,
    required String? baseRevision,
    required int chunkCount,
    required int noteCount,
  }) async {
    commitCalls++;
    if (conflictOnCommit || conflictCount > 0) {
      if (conflictCount > 0) conflictCount--;
      final previous = manifests[contextKey];
      return NoteSortCloudCommitResult.conflict(
        previousRevision: previous?['revision'] as String?,
        previousChunkCount: previous?['chunk_count'] as int? ?? 0,
      );
    }
    final previous = manifests[contextKey];
    manifests[contextKey] = {
      'schema_version': schemaVersion,
      'context_key': contextKey,
      'sort_mode': sortMode,
      'revision': revision,
      'chunk_count': chunkCount,
      'note_count': noteCount,
    };
    return NoteSortCloudCommitResult.committed(
      previousRevision: previous?['revision'] as String?,
      previousChunkCount: previous?['chunk_count'] as int? ?? 0,
    );
  }

  @override
  Future<void> deleteRevision(String revision, int chunkCount) async {
    if (failDeletes) throw StateError('delete failed');
    if (deleteStarted?.isCompleted == false) deleteStarted!.complete();
    await deleteBarrier?.future;
    deletedRevisions.add(revision);
    chunks.remove(revision);
  }

  @override
  Future<List<Map<String, dynamic>>?> readChunks(
    String revision,
    int chunkCount,
  ) async {
    return chunks[revision];
  }

  @override
  Future<Map<String, dynamic>?> readManifest(String contextKey) async {
    readManifestCalls++;
    if (failReadManifestCalls.contains(readManifestCalls)) {
      throw StateError('manifest read failed');
    }
    return manifests[contextKey];
  }

  @override
  Future<void> writeChunks(String revision, List<List<String>> values) async {
    writeCalls++;
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    chunks[revision] = [
      for (final value in values)
        {
          'schema_version': schemaVersion,
          'revision': revision,
          'note_ids': value,
        },
    ];
    await writeBarrier?.future;
    if (writeError != null) throw writeError!;
    if (failWrites || failWriteCount > 0) {
      if (failWriteCount > 0) failWriteCount--;
      throw StateError('write failed');
    }
  }
}
