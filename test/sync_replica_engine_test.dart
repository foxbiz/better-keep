import 'dart:io';

import 'package:better_keep/models/app_progress.dart';

import 'dart:typed_data';
import 'dart:async';

import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late SyncReplicaStore store;
  late _Content content;
  late SyncReplicaEngine engine;
  var active = true;
  final bytes = Uint8List.fromList([1, 2, 3]);
  final objectId = sha256.convert(bytes).toString();

  SyncRevision revision(int time, {bool deleted = false, String? id}) =>
      SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-1',
        revisionId: id ?? 'revision-$time',
        modifiedAtMicros: time,
        deleted: deleted,
        payloadObjectId: deleted ? null : objectId,
      );
  Future<void> save(SyncRevision value) => db.transaction((txn) async {
    await store.accept(txn, value);
  });

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SyncReplicaStore.createTables(db);
    await db.execute('CREATE TABLE applied (revision TEXT NOT NULL)');
    store = SyncReplicaStore(db, scope: 'user:library');
    content = _Content()..objects[objectId] = bytes;
    active = true;
    engine = SyncReplicaEngine(
      store: store,
      content: content,
      isCurrent: () => active,
    );
  });
  tearDown(() => db.close());

  test(
    'legacy SQLite counts only scoped live notes and probes once per database',
    () async {
      final page = SyncChangePage(
        revisions: [revision(1), revision(2, deleted: true)],
        cursor: 'cursor',
        hasMore: false,
      );
      await store.stagePage('first', page);
      final legacy = _LegacyJsonDatabase(db);
      final scoped = SyncReplicaStore(legacy, scope: store.scope);
      expect(await scoped.incomingNoteCount('first'), 1);
      expect(await scoped.incomingNoteCount('second'), 0);
      expect(
        await SyncReplicaStore(
          legacy,
          scope: 'other',
        ).incomingNoteCount('first'),
        0,
      );
      expect(legacy.probes, 1);
    },
  );

  test(
    'counts only durable note updates and clears progress on retry',
    () async {
      final samples = <NoteTransfer?>[];
      final adapter = _Adapter('progress')..incoming = [revision(1)];
      engine = SyncReplicaEngine(
        store: store,
        content: content,
        isCurrent: () => active,
        onProgress: (_, value) => samples.add(value),
      );
      content.failApply = true;
      await expectLater(engine.sync(adapter), throwsStateError);
      expect(samples.last, isNull);
      expect(
        samples
            .whereType<NoteTransfer>()
            .where((s) => s.stage == NoteTransferStage.downloading)
            .every((s) => s.done == 0),
        true,
      );
      content.failApply = false;
      samples.clear();
      await engine.sync(adapter);
      expect(
        samples.whereType<NoteTransfer>().any(
          (s) =>
              s.stage == NoteTransferStage.downloading &&
              s.done == 1 &&
              s.total == 1,
        ),
        true,
      );
      expect(samples.last, isNull);
      final other = _Adapter('second');
      samples.clear();
      await engine.sync(other);
      expect(
        samples.whereType<NoteTransfer>().any(
          (s) =>
              s.stage == NoteTransferStage.uploading &&
              s.done == 1 &&
              s.total == 1,
        ),
        true,
      );
      expect(samples.last, isNull);
    },
  );

  for (final failRestore in [false, true]) {
    test(
      'idle waits for queued mode upgrade after restore failure: $failRestore',
      () async {
        await save(revision(1));
        final started = Completer<void>();
        final restoreRelease = Completer<void>();
        final fullStarted = Completer<void>();
        final fullRelease = Completer<void>();
        var passes = 0;
        final adapter = _Adapter('review')
          ..listChanges = (_) async {
            passes++;
            if (passes == 1) {
              started.complete();
              await restoreRelease.future;
              if (failRestore) {
                throw const SyncProviderFailure(
                  SyncProviderFailureKind.unavailable,
                );
              }
            } else if (passes == 2) {
              fullStarted.complete();
              await fullRelease.future;
            }
            return SyncChangePage(revisions: [], cursor: 'end', hasMore: false);
          };
        final restore = engine.sync(adapter, downloadOnly: true);
        final restored = failRestore
            ? expectLater(restore, throwsA(isA<SyncProviderFailure>()))
            : restore;
        await started.future;
        var idle = false;
        final drained = engine.waitForIdle().then((_) => idle = true);
        final requests = List.generate(20, (_) => engine.sync(adapter));
        restoreRelease.complete();
        await fullStarted.future;
        await Future<void>.delayed(Duration.zero);
        final finishedTooSoon = idle;
        fullRelease.complete();
        await Future.wait([restored, ...requests, drained]);
        expect(finishedTooSoon, isFalse);
        expect(passes, 2);
        expect(adapter.published, hasLength(1));
        expect(idle, isTrue);
        await engine.waitForIdle();
      },
    );
  }

  test('full sync waits for download-only work and then uploads', () async {
    await save(revision(1));
    final entered = Completer<void>();
    final release = Completer<void>();
    var reads = 0;
    final adapter = _Adapter('drive')
      ..listChanges = (_) async {
        if (++reads == 1) {
          entered.complete();
          await release.future;
        }
        return SyncChangePage(revisions: [], cursor: 'done', hasMore: false);
      };
    final restore = engine.sync(adapter, downloadOnly: true);
    await entered.future;
    final full = engine.sync(adapter);
    expect(adapter.published, isEmpty);
    release.complete();
    await Future.wait([restore, full]);
    expect(reads, 2);
    expect(adapter.published.single.revisionId, 'revision-1');
    expect(await store.pending('drive'), isEmpty);
  });

  test(
    'prefetch probes existence without reading cached payloads twice',
    () async {
      final adapter = _SmallAdapter('small')..incoming = [revision(1)];
      adapter.smallRead = (_) async => fail('Already cached');
      await engine.sync(adapter, downloadOnly: true);
      expect(content.readCalls, 1);
      expect(adapter.fullReads, 0);
    },
  );

  test(
    'prefetch surfaces cache-write failures before applying revisions',
    () async {
      content.objects.clear();
      final error = StateError('Cache write failed');
      content.cacheError = error;
      final adapter = _SmallAdapter('small')..incoming = [revision(1)];
      adapter.smallRead = (_) async => bytes;
      await expectLater(
        engine.sync(adapter, downloadOnly: true),
        throwsA(same(error)),
      );
      expect(adapter.fullReads, 0);
      expect(await db.query('applied'), isEmpty);
      expect(await store.inbox('small'), hasLength(1));
    },
  );

  test('batch failure retains pending revisions and retry does not echo unchanged notes', () async {
    await save(revision(1));
    await save(
      SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-2',
        revisionId: 'second',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: objectId,
      ),
    );
    final adapter = _BatchAdapter('batch')..failPublish = true;
    await expectLater(
      engine.sync(adapter),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(await store.pending('batch'), hasLength(2));
    expect(adapter.events, ['object']); // Shared object uploaded only once.
    adapter.failPublish = false;
    await engine.sync(adapter);
    expect(await store.pending('batch'), isEmpty);
    expect(adapter.published, hasLength(2));
    final events = adapter.events.length;
    await engine.sync(adapter);
    expect(adapter.events.length, events);
    expect(await store.pending('other-provider'), hasLength(2));
  });

  test(
    'batch rechecks local edits and cancellation before publishing',
    () async {
      await save(revision(1));
      await save(
        SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'note-2',
          revisionId: 'second',
          modifiedAtMicros: 1,
          deleted: true,
          payloadObjectId: null,
        ),
      );
      final adapter = _BatchAdapter('batch')..onPut = () => save(revision(2));
      await engine.sync(adapter);
      expect(adapter.published.map((r) => r.revisionId), ['second']);
      expect((await store.pending('batch')).single.revisionId, 'revision-2');
      final cancelled = _BatchAdapter('cancel')
        ..onPut = () async {
          active = false;
        };
      await expectLater(engine.sync(cancelled), throwsA(anything));
      expect(cancelled.published, isEmpty);
      expect(await store.pending('cancel'), hasLength(2));
    },
  );

  test(
    'batch object buffers stay bounded and large attachments use serial writes',
    () async {
      final adapter = _BatchAdapter('bounded');
      for (var i = 0; i < 40; i++) {
        final data = Uint8List(i == 0 ? 5 * 1024 * 1024 : 200 * 1024)..[0] = i;
        final id = sha256.convert(data).toString();
        content.objects[id] = data;
        await save(
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'n-$i',
            revisionId: 'r-$i',
            modifiedAtMicros: i,
            deleted: false,
            payloadObjectId: id,
          ),
        );
      }
      await engine.sync(adapter);
      expect(adapter.objects, hasLength(40));
      expect(adapter.published, hasLength(40));
      expect(adapter.batchSizes.length, greaterThan(1));
      expect(adapter.batchSizes.reduce((a, b) => a + b), 39);
      expect(
        adapter.retainedBatches.map((batch) => batch.length),
        adapter.batchSizes,
      );
      expect(
        () => adapter.retainedBatches.first.clear(),
        throwsUnsupportedError,
      );
      expect(await store.pending('bounded'), isEmpty);
    },
  );

  test('small object prefetch is bounded, drains failures, and avoids unchanged reads', () async {
    content.objects.clear();
    final adapter = _SmallAdapter('small');
    final ids = <String>[];
    for (var i = 0; i < 10; i++) {
      final data = Uint8List.fromList([i]);
      final id = sha256.convert(data).toString();
      ids.add(id);
      adapter.objects[id] = data;
      adapter.incoming.add(
        SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'note-$i',
          revisionId: 'edit-$i',
          modifiedAtMicros: i,
          deleted: false,
          payloadObjectId: id,
        ),
      );
    }
    final releases = <Completer<Uint8List?>>[];
    adapter.smallRead = (id) {
      final release = Completer<Uint8List?>();
      releases.add(release);
      return release.future;
    };
    var completed = false;
    final run = engine
        .sync(adapter, downloadOnly: true)
        .whenComplete(() => completed = true);
    for (var i = 0; releases.length < 8 && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(releases, hasLength(8));
    releases.first.completeError(
      const SyncProviderFailure(SyncProviderFailureKind.unavailable),
    );
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(await db.query('applied'), isEmpty);
    for (var i = 1; i < releases.length; i++) {
      releases[i].complete(adapter.objects[ids[i]]);
    }
    await run;
    expect(releases, hasLength(8));
    expect(adapter.fullReads, 3); // Failed prefetch plus two never started.
    expect(await db.query('applied'), hasLength(10));
    await engine.sync(adapter, downloadOnly: true);
    expect(releases, hasLength(8));
    expect(adapter.fullReads, 3);
  });

  test('large-object fallback remains serial and newer local winners are not prefetched', () async {
    content.objects.clear();
    final adapter = _SmallAdapter('small')
      ..incoming = [revision(1)]
      ..objects[objectId] = bytes;
    var smallCalls = 0;
    adapter.smallRead = (_) async {
      smallCalls++;
      return null;
    };
    await save(revision(5));
    await engine.sync(adapter, downloadOnly: true);
    expect(smallCalls, 0);
    expect(adapter.fullReads, 0);
    adapter.incoming = [revision(6)];
    await engine.sync(adapter, downloadOnly: true);
    expect(smallCalls, 1);
    expect(adapter.fullReads, 1);
    expect(content.objects[objectId], bytes);
  });

  test(
    'shared objects upload once per page, independently per provider and retry',
    () async {
      for (var i = 0; i < 2; i++) {
        await save(
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'shared-$i',
            revisionId: 'shared-revision-$i',
            modifiedAtMicros: i + 1,
            deleted: false,
            payloadObjectId: objectId,
          ),
        );
      }
      final first = _Adapter('dropbox');
      await engine.sync(first);
      expect(first.events, ['object', 'commit', 'commit']);
      final second = _Adapter('drive')..failPublish = true;
      await expectLater(
        engine.sync(second),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(second.events, ['object']);
      second.events.clear();
      second.failPublish = false;
      await engine.sync(second);
      expect(second.events, ['object', 'commit', 'commit']);
      expect(await store.pending('drive'), isEmpty);
    },
  );

  test(
    'initial download preserves newer local edits without uploading them',
    () async {
      await save(revision(5));
      final adapter = _Adapter('dropbox')..incoming = [revision(1)];
      await engine.sync(adapter, downloadOnly: true);
      expect(adapter.published, isEmpty);
      expect(adapter.events, isEmpty);
      expect(
        (await store.current(db, SyncEntityKind.note, 'note-1'))!.revisionId,
        'revision-5',
      );
      expect(await store.pending('dropbox'), hasLength(1));
      await engine.sync(adapter);
      expect(adapter.published.single.revisionId, 'revision-5');
    },
  );

  test(
    'initial download applies remote notes without writing provider files',
    () async {
      content.objects.clear();
      final adapter = _Adapter('dropbox')
        ..incoming = [revision(1)]
        ..objects[objectId] = bytes;
      await engine.sync(adapter, downloadOnly: true);
      expect(await db.query('applied'), hasLength(1));
      expect(content.objects[objectId], bytes);
      expect(adapter.published, isEmpty);
      expect(await store.pending('dropbox'), isEmpty);
    },
  );

  test('expired continuation restarts listing without reapplying acknowledged revisions', () async {
    final adapter = _Adapter('dav')..incoming = [revision(1)];
    await engine.sync(adapter);
    await store.stagePage(
      'dav',
      SyncChangePage(revisions: [], cursor: 'expired-scan', hasMore: true),
      ensureCurrent: () {},
    );
    final cursors = <String?>[];
    adapter.listChanges = (cursor) async {
      cursors.add(cursor);
      if (cursor == 'expired-scan') {
        return SyncChangePage(
          revisions: [revision(1)],
          cursor: 'bad-continuation',
          hasMore: true,
        );
      }
      if (cursor != null) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
      return SyncChangePage(
        revisions: [revision(1), revision(2)],
        cursor: 'complete',
        hasMore: false,
      );
    };
    final checked = <int>[];
    final restarted = SyncReplicaEngine(
      store: store,
      content: content,
      isCurrent: () => true,
      onProgress: (_, progress) {
        if (progress?.stage == NoteTransferStage.checking) {
          checked.add(progress!.done);
        }
      },
    );
    await restarted.sync(adapter);
    expect(cursors, ['expired-scan', 'bad-continuation', null]);
    expect(checked.last, 2);
    expect(checked, orderedEquals([...checked]..sort()));
    expect(await store.cursor('dav'), 'complete');
    expect(await db.query('applied'), hasLength(2));
  });

  test(
    'unchanged acknowledged notes do not upload again after engine restart',
    () async {
      await save(revision(1));
      final adapter = _Adapter('drive');
      await engine.sync(adapter);
      adapter.events.clear();
      final restarted = SyncReplicaEngine(
        store: SyncReplicaStore(db, scope: store.scope),
        content: content,
        isCurrent: () => true,
      );
      await restarted.sync(adapter);
      await restarted.sync(adapter);
      expect(adapter.events, isEmpty);
      expect(adapter.published, hasLength(1));
    },
  );

  test(
    'newer local note uploads instead of downloading an older incoming body',
    () async {
      await save(revision(5));
      final old = SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-1',
        revisionId: 'old',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: 'f' * 64,
      );
      final adapter = _Adapter('drive')..incoming = [old];
      await engine.sync(adapter);
      expect(await db.query('applied'), isEmpty);
      expect(adapter.published.single.revisionId, 'revision-5');
      adapter.events.clear();
      await engine.sync(adapter);
      expect(adapter.events, isEmpty);
    },
  );

  test(
    'evicted outgoing objects recover from another provider before publication',
    () async {
      await save(revision(1));
      content.objects.clear();
      final destination = _Adapter('dropbox');
      final retained = _Adapter('drive')..objects[objectId] = bytes;
      final recovering = SyncReplicaEngine(
        store: store,
        content: content,
        isCurrent: () => active,
        availableAdapters: () => [retained],
      );
      await recovering.sync(destination);
      expect(content.objects[objectId], bytes);
      expect(destination.objects[objectId], bytes);
      expect(destination.events, ['object', 'commit']);
      expect(await store.pending('dropbox'), isEmpty);
    },
  );

  test('missing incoming objects use a verified replica and reject corrupt fallback bytes', () async {
    content.objects.clear();
    final source = _Adapter('drive')..incoming = [revision(1)];
    final retained = _Adapter('dropbox')
      ..objects[objectId] = Uint8List.fromList([9]);
    final recovering = SyncReplicaEngine(
      store: store,
      content: content,
      isCurrent: () => active,
      availableAdapters: () => [retained],
    );
    await expectLater(
      recovering.sync(source),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(content.objects, isEmpty);
    expect(await db.query('applied'), isEmpty);
    expect(await store.inbox('drive'), hasLength(1));
    retained.objects[objectId] = bytes;
    await recovering.sync(source);
    expect(content.objects[objectId], bytes);
    expect(await db.query('applied'), hasLength(1));
    expect(await store.inbox('drive'), isEmpty);
  });

  test('latest timestamp, deletion tie, and revision ID converge deterministically', () {
    expect(revision(2).compareTo(revision(1)), greaterThan(0));
    expect(revision(2, deleted: true).compareTo(revision(2)), greaterThan(0));
    expect(
      revision(2, id: 'b').compareTo(revision(2, id: 'a')),
      greaterThan(0),
    );
    expect(
      SyncRevision.nextTimestamp(
        DateTime.fromMicrosecondsSinceEpoch(1),
        revision(5),
      ),
      6,
    );
    expect(
      SyncRevision.decode(revision(2).encode()).encode(),
      revision(2).encode(),
    );
    expect(() => SyncRevision.decode('{"version":2}'), throwsFormatException);
  });

  test(
    'provider failure leaves its work pending while another succeeds',
    () async {
      await save(revision(1));
      final failed = _Adapter('failed')..failPublish = true;
      final healthy = _Adapter('healthy');
      final failures = await engine.syncAll([failed, healthy]);
      expect(failures.keys, ['failed']);
      expect(await store.pending('healthy'), isEmpty);
      expect((await store.pending('failed')).single.revisionId, 'revision-1');
      expect(healthy.events, ['object', 'commit']);
    },
  );

  test(
    'a superseded upload is not committed after its objects finish uploading',
    () async {
      await save(revision(1));
      final adapter = _Adapter('drive')..onPut = () => save(revision(2));
      await engine.sync(adapter);
      expect(adapter.published, isEmpty);
      expect((await store.pending('drive')).single.revisionId, 'revision-2');
      adapter.onPut = null;
      await engine.sync(adapter);
      expect(adapter.published.single.revisionId, 'revision-2');
      expect(await store.pending('drive'), isEmpty);
    },
  );

  test('edit during upload remains pending after captured revision is acknowledged', () async {
    await save(revision(1));
    final adapter = _Adapter('drive')..onPublish = () => save(revision(2));
    await engine.sync(adapter);
    expect((await store.pending('drive')).single.revisionId, 'revision-2');
    adapter.onPublish = null;
    await engine.sync(adapter);
    expect(await store.pending('drive'), isEmpty);
  });

  test('retry after remote commit failure repeats immutable IDs and eventually acknowledges', () async {
    await save(revision(1));
    final adapter = _Adapter('drive')..failPublish = true;
    await expectLater(
      engine.sync(adapter),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(await store.pendingSignal('drive'), isNull);
    adapter.failPublish = false;
    await engine.sync(adapter);
    expect(adapter.objects.length, 1);
    expect(await store.pending('drive'), isEmpty);
    expect(await store.pendingSignal('drive'), 'revision-1');
  });

  test(
    'incoming revision forwards unchanged without echo to its source',
    () async {
      final source = _Adapter('drive')
        ..incoming = [revision(3)]
        ..objects[objectId] = bytes;
      content.objects.clear();
      await engine.sync(source);
      expect(source.events, isEmpty);
      expect(await store.pending('drive'), isEmpty);
      expect(await store.pendingSignal('drive'), isNull);
      final destination = _Adapter('dropbox');
      await engine.sync(destination);
      expect(destination.published.single.encode(), revision(3).encode());
      expect(await store.pendingSignal('dropbox'), 'revision-3');
      destination.events.clear();
      await engine.sync(source);
      await engine.sync(destination);
      expect(source.events, isEmpty);
      expect(destination.events, isEmpty);
      expect((await db.query('applied')).length, 1);
    },
  );

  test(
    'restart applies the remaining notes before checking for new changes',
    () async {
      final directory = await Directory.systemTemp.createTemp('restore-test-');
      final path = '${directory.path}/restore.db';
      var disk = await databaseFactoryFfi.openDatabase(path);
      addTearDown(() async {
        await disk.close();
        await directory.delete(recursive: true);
      });
      await SyncReplicaStore.createTables(disk);
      await disk.execute('CREATE TABLE applied (revision TEXT NOT NULL)');
      final data = List.generate(24, (i) => Uint8List.fromList([i]));
      final revisions = [
        for (final (i, bytes) in data.indexed)
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'n${i.toString().padLeft(2, '0')}',
            revisionId: 'r$i',
            modifiedAtMicros: i + 1,
            deleted: false,
            payloadObjectId: sha256.convert(bytes).toString(),
          ),
      ];
      final source = _Adapter('dropbox')
        ..incoming = revisions
        ..objects[revisions.first.payloadObjectId!] = data.first;
      SyncReplicaEngine open(List<NoteTransfer?> samples) => SyncReplicaEngine(
        store: SyncReplicaStore(disk, scope: store.scope),
        content: _Content(),
        isCurrent: () => true,
        onProgress: (_, value) => samples.add(value),
      );
      await expectLater(
        open([]).sync(source, downloadOnly: true),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(await disk.query('applied'), hasLength(1));
      await disk.close();
      disk = await databaseFactoryFfi.openDatabase(path);
      // The second client has no memory cache or access to the first payload.
      source.objects.clear();
      for (var i = 1; i < data.length; i++) {
        source.objects[revisions[i].payloadObjectId!] = data[i];
      }
      source.listChanges = (cursor) async {
        expect(cursor, 'cursor-1');
        expect(await disk.query('applied'), hasLength(24));
        return SyncChangePage(
          revisions: [],
          cursor: 'cursor-2',
          hasMore: false,
        );
      };
      final samples = <NoteTransfer?>[];
      final restored = open(samples);
      await restored.sync(source, downloadOnly: true);
      final first = samples.whereType<NoteTransfer>().first;
      expect(first.stage, NoteTransferStage.downloading);
      expect(first.total, 23);
      expect(await restored.store.inbox(source.connectionId), isEmpty);
      expect(source.published, isEmpty);
      expect(
        (await disk.query('applied')).map((r) => r['revision']).toSet(),
        revisions.map((r) => r.encode()).toSet(),
      );
    },
  );

  test(
    'missing incoming content survives cursor advance and engine restart',
    () async {
      content.objects.clear();
      final adapter = _Adapter('drive')..incoming = [revision(3)];
      await expectLater(
        engine.sync(adapter),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(await store.cursor('drive'), 'cursor-1');
      expect((await store.inbox('drive')).length, 1);
      adapter.incoming = [];
      adapter.objects[objectId] = bytes;
      final restarted = SyncReplicaEngine(
        store: SyncReplicaStore(db, scope: store.scope),
        content: content,
        isCurrent: () => true,
      );
      await restarted.sync(adapter);
      expect(await store.inbox('drive'), isEmpty);
      expect(
        (await store.current(db, SyncEntityKind.note, 'note-1'))!.revisionId,
        'revision-3',
      );
    },
  );

  test(
    'failed domain application rolls revision and acknowledgement back',
    () async {
      content.failApply = true;
      final adapter = _Adapter('drive')..incoming = [revision(3)];
      await expectLater(engine.sync(adapter), throwsStateError);
      expect(await store.current(db, SyncEntityKind.note, 'note-1'), isNull);
      expect(await db.query('applied'), isEmpty);
      expect((await store.inbox('drive')).length, 1);
    },
  );

  test('tombstone prevents stale resurrection and requires no media', () async {
    await save(revision(5, deleted: true));
    content.objects.clear();
    final adapter = _Adapter('drive')..incoming = [revision(3)];
    await engine.sync(adapter);
    expect(adapter.published.single.deleted, isTrue);
    expect(adapter.events, ['commit']);
    expect(
      (await store.current(db, SyncEntityKind.note, 'note-1'))!.deleted,
      isTrue,
    );
  });

  test(
    'same revision identity with changed content is rejected transactionally',
    () async {
      await save(revision(1));
      await expectLater(
        save(revision(2, id: 'revision-1')),
        throwsFormatException,
      );
      expect(
        (await store.current(
          db,
          SyncEntityKind.note,
          'note-1',
        ))!.modifiedAtMicros,
        1,
      );
    },
  );

  test(
    'a conflicting queued revision cannot block a newer valid revision',
    () async {
      await save(revision(1));
      final conflicting = revision(1, deleted: true);
      await store.stagePage(
        'drive',
        SyncChangePage(
          revisions: [conflicting],
          cursor: 'old-cursor',
          hasMore: false,
        ),
      );
      final adapter = _Adapter('drive')..incoming = [revision(2)];
      await engine.sync(adapter);
      expect(
        (await store.current(db, SyncEntityKind.note, 'note-1'))!.revisionId,
        'revision-2',
      );
      final applied = await db.query('applied');
      expect(
        applied.map(
          (row) => SyncRevision.decode(row['revision'] as String).revisionId,
        ),
        ['revision-2'],
      );
      expect(await store.inbox('drive'), isEmpty);
    },
  );

  test('an unresolved queued identity conflict still fails closed', () async {
    await save(revision(1));
    await store.stagePage(
      'drive',
      SyncChangePage(
        revisions: [revision(1, deleted: true)],
        cursor: 'old-cursor',
        hasMore: false,
      ),
    );
    final adapter = _Adapter('drive');
    await expectLater(engine.sync(adapter), throwsFormatException);
    expect(
      (await store.current(db, SyncEntityKind.note, 'note-1'))!.deleted,
      isFalse,
    );
    expect(await db.query('applied'), isEmpty);
    expect(await store.inbox('drive'), hasLength(1));
    expect(adapter.published, isEmpty);
  });

  test('account and key-generation scopes do not share acknowledgements or content state', () async {
    await save(revision(1));
    final other = SyncReplicaStore(db, scope: 'another-user:library');
    expect(await other.pending('drive'), isEmpty);
    expect(await other.current(db, SyncEntityKind.note, 'note-1'), isNull);
  });

  test('corrupt media cannot publish or apply a revision', () async {
    await save(revision(1));
    content.objects[objectId] = Uint8List.fromList([9]);
    final adapter = _Adapter('drive');
    await expectLater(
      engine.sync(adapter),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(adapter.events, isEmpty);
    expect((await store.pending('drive')).length, 1);
  });

  test(
    'session invalidation after publish does not acknowledge stale work',
    () async {
      await save(revision(1));
      final adapter = _Adapter('drive')
        ..onPublish = () async {
          active = false;
        };
      await expectLater(
        engine.sync(adapter),
        throwsA(isA<SyncReplicaCancelled>()),
      );
      expect((await store.pending('drive')).length, 1);
    },
  );

  test(
    'bounded inbox and outgoing pages drain without skipping acknowledgements',
    () async {
      final incoming = List.generate(
        205,
        (index) => SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'note-${index.toString().padLeft(4, '0')}',
          revisionId: 'revision-$index',
          modifiedAtMicros: index,
          deleted: false,
          payloadObjectId: objectId,
        ),
      );
      final source = _Adapter('source')..incoming = incoming;
      await engine.sync(source);
      expect(await store.inbox('source'), isEmpty);
      expect((await db.query('applied')).length, 205);
      final target = _Adapter('target');
      expect((await store.pending('target')).length, 100);
      await engine.sync(target);
      expect(target.published.length, 205);
      expect(target.published.map((r) => r.entityId).toSet().length, 205);
      expect(await store.pending('target'), isEmpty);
    },
  );

  test('replacement provider accounts start fresh without clearing previous provider records', () async {
    await save(revision(1));
    final original = _Adapter('google_drive:1');
    final replacement = _Adapter('google_drive:2');
    final other = _Adapter('dropbox:1');
    await engine.sync(original);
    await engine.sync(other);
    await store.stagePage(
      original.connectionId,
      SyncChangePage(
        revisions: [revision(2)],
        cursor: 'original-only',
        hasMore: false,
      ),
    );
    expect(await store.pending(replacement.connectionId), hasLength(1));
    expect(await store.cursor(replacement.connectionId), isNull);
    expect(await store.inbox(replacement.connectionId), isEmpty);
    await engine.sync(replacement);
    expect(replacement.published.single.revisionId, 'revision-1');
    expect(await store.cursor(original.connectionId), 'original-only');
    expect(
      (await store.inbox(original.connectionId)).single.revisionId,
      'revision-2',
    );
    expect(await store.pending(original.connectionId), isEmpty);
    expect(await store.pending(other.connectionId), isEmpty);
    expect(await store.inbox(other.connectionId), isEmpty);
  });

  test('migration is idempotent and preserves tombstones', () async {
    await save(revision(1, deleted: true));
    await SyncReplicaStore.createTables(db);
    expect((await store.pending('drive')).single.deleted, isTrue);
  });
}

class _Content implements SyncReplicaContent {
  final objects = <String, Uint8List>{};
  bool failApply = false;
  int readCalls = 0;
  Object? cacheError;
  @override
  Future<bool> contains(String objectId) async => objects.containsKey(objectId);
  @override
  Future<Uint8List?> read(String objectId) async {
    readCalls++;
    return objects[objectId];
  }

  @override
  Future<void> cache(String objectId, Uint8List bytes) async {
    if (cacheError case final error?) throw error;
    objects[objectId] = bytes;
  }

  @override
  Future<void> apply(Transaction txn, SyncRevision revision) async {
    await txn.insert('applied', {'revision': revision.encode()});
    if (failApply) throw StateError('Simulated apply failure');
  }
}

class _Adapter implements SyncProviderAdapter {
  _Adapter(this.connectionId);
  @override
  final String connectionId;
  final objects = <String, Uint8List>{};
  final events = <String>[];
  final published = <SyncRevision>[];
  List<SyncRevision> incoming = [];
  Future<SyncChangePage> Function(String?)? listChanges;
  bool failPublish = false;
  Future<void> Function()? onPublish;
  Future<void> Function()? onPut;
  @override
  Future<SyncChangePage> changes(
    String? cursor, {
    void Function(int count)? onCheckedNotes,
  }) async => listChanges != null
      ? listChanges!(cursor)
      : SyncChangePage(revisions: incoming, cursor: 'cursor-1', hasMore: false);
  @override
  Future<Uint8List> readObject(String objectId) async {
    final data = objects[objectId];
    if (data == null) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    return data;
  }

  @override
  Future<void> putObject(String objectId, Uint8List encryptedBytes) async {
    objects[objectId] = encryptedBytes;
    events.add('object');
    await onPut?.call();
  }

  @override
  Future<void> publish(SyncRevision revision) async {
    await onPublish?.call();
    if (failPublish) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    events.add('commit');
    published.add(revision);
  }
}

class _SmallAdapter extends _Adapter implements SmallSyncObjectReader {
  _SmallAdapter(super.connectionId);
  Future<Uint8List?> Function(String)? smallRead;
  int fullReads = 0;
  @override
  Future<bool> get supportsSmallReads async => true;
  @override
  Future<Uint8List?> readSmallObject(String id) => smallRead!(id);
  @override
  Future<Uint8List> readObject(String id) {
    fullReads++;
    return super.readObject(id);
  }
}

class _BatchAdapter extends _Adapter implements BatchSyncWriter {
  _BatchAdapter(super.connectionId);
  final batchSizes = <int>[];
  final retainedBatches = <Map<String, Uint8List>>[];
  @override
  Future<bool> get supportsBatchWrites async => true;
  @override
  Future<void> putObjects(Map<String, Uint8List> values) async {
    batchSizes.add(values.length);
    retainedBatches.add(values);
    expect(values.length, lessThanOrEqualTo(32));
    expect(
      values.values.fold<int>(0, (sum, data) => sum + data.length),
      lessThanOrEqualTo(4 * 1024 * 1024),
    );
    for (final entry in values.entries) {
      await putObject(entry.key, entry.value);
    }
  }

  @override
  Future<void> publishBatch(List<SyncRevision> revisions) async {
    for (final revision in revisions) {
      await publish(revision);
    }
  }
}

// Delegate the fallback to SQLite so its filtering and cursor behavior are exercised.
class _LegacyJsonDatabase extends Fake implements Database {
  _LegacyJsonDatabase(this.delegate);
  final Database delegate;
  int probes = 0;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    probes++;
    throw _MissingJsonExtract();
  }

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) => delegate.rawQueryCursor(sql, arguments, bufferSize: bufferSize);
}

class _MissingJsonExtract extends Fake implements DatabaseException {
  @override
  String toString() => 'no such function: json_extract';
}
