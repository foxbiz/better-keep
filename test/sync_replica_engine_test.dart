import 'dart:typed_data';

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
      if (cursor != null) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
      return SyncChangePage(
        revisions: [revision(1), revision(2)],
        cursor: 'complete',
        hasMore: false,
      );
    };
    final restarted = SyncReplicaEngine(
      store: store,
      content: content,
      isCurrent: () => true,
    );
    await restarted.sync(adapter);
    expect(cursors, ['expired-scan', null]);
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
      expect((await db.query('applied')).length, 1);
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
  @override
  Future<Uint8List?> read(String objectId) async => objects[objectId];
  @override
  Future<void> cache(String objectId, Uint8List bytes) async {
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
  Future<SyncChangePage> changes(String? cursor) async => listChanges != null
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
