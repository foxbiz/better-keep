import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(db);
    await Label.createTable(db);
    await NoteSortService.createTable(db);
    await SyncReplicaStore.createTables(db);
    await SyncMutationJournal.install(db);
  });
  tearDown(() => db.close());
  Future<void> insert() =>
      db.insert('note', {'id': 1, 'sync_id': 'note-id', 'content': 'first'});
  Future<SyncLocalVersion?> current() =>
      SyncMutationJournal.current(db, SyncEntityKind.note, 'note-id');

  test(
    'direct writes and deletions record versions in the content transaction',
    () async {
      await insert();
      final first = (await current())!;
      expect(first.deleted, false);
      await db.update('note', {
        'reminder': '{"completed":true}',
      }, where: 'id = 1');
      final changed = (await current())!;
      expect(changed.revisionId, isNot(first.revisionId));
      expect(changed.modifiedAtMicros, greaterThan(first.modifiedAtMicros));
      await db.delete('note', where: 'id = 1');
      final deleted = (await current())!;
      expect(deleted.deleted, true);
      expect(deleted.modifiedAtMicros, greaterThan(changed.modifiedAtMicros));
      expect(
        (await SyncMutationJournal.pending(
          db,
          'user:library',
        )).single.revisionId,
        deleted.revisionId,
      );
    },
  );

  test(
    'rollback leaves neither content nor a phantom outgoing revision',
    () async {
      await expectLater(
        db.transaction((txn) async {
          await txn.insert('note', {'id': 1, 'sync_id': 'note-id'});
          throw StateError('synthetic rollback');
        }),
        throwsStateError,
      );
      expect(await current(), isNull);
      expect(await db.query('note'), isEmpty);
    },
  );

  test('remote adoption preserves version and later local edits advance past future clocks', () async {
    final remote = SyncRevision(
      kind: SyncEntityKind.note,
      entityId: 'note-id',
      revisionId: 'remote-revision',
      modifiedAtMicros: DateTime.now()
          .toUtc()
          .add(const Duration(days: 1))
          .microsecondsSinceEpoch,
      deleted: false,
      payloadObjectId: 'a' * 64,
    );
    await db.transaction(
      (txn) => SyncMutationJournal.withoutCapture(txn, () async {
        await SyncMutationJournal.withoutCapture(
          txn,
          () => txn.insert('note', {'id': 1, 'sync_id': 'note-id'}),
        );
        await SyncMutationJournal.received(txn, remote, '1');
        await SyncReplicaStore(db, scope: 'scope').accept(txn, remote);
      }),
    );
    expect((await current())!.revisionId, 'remote-revision');
    expect(await SyncMutationJournal.pending(db, 'scope'), isEmpty);
    await db.update('note', {'title': 'edit'}, where: 'id = 1');
    expect((await current())!.modifiedAtMicros, remote.modifiedAtMicros + 1);
    expect(await db.query(SyncMutationJournal.guardTable), isEmpty);
  });

  test(
    'derived search text and cloud acknowledgement changes do not create edits',
    () async {
      await insert();
      final before = (await current())!.revisionId;
      await db.update('note', {
        'plain_text': 'derived',
        'remote_id': 'legacy',
      }, where: 'id = 1');
      expect((await current())!.revisionId, before);
      await db.insert('note_sort_context', {
        'context_key': 'main',
        'sort_mode': 'custom',
        'revision': 'r1',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final order = await SyncMutationJournal.current(
        db,
        SyncEntityKind.order,
        'main',
      );
      await db.update('note_sort_context', {
        'dirty': 0,
        'hydrated': 1,
      }, where: "context_key = 'main'");
      expect(
        (await SyncMutationJournal.current(
          db,
          SyncEntityKind.order,
          'main',
        ))!.revisionId,
        order!.revisionId,
      );
    },
  );

  test(
    'bootstrap is idempotent, retains timestamps and includes labels',
    () async {
      await db.execute('DROP TRIGGER replica_label_insert');
      await db.insert('label', {
        'id': 2,
        'sync_id': 'label-id',
        'name': 'label',
        'updated_at': '2025-01-02T03:04:05Z',
      });
      await SyncMutationJournal.install(db);
      final first = (await SyncMutationJournal.current(
        db,
        SyncEntityKind.label,
        'label-id',
      ))!;
      expect(
        first.modifiedAtMicros,
        DateTime.utc(2025, 1, 2, 3, 4, 5).microsecondsSinceEpoch,
      );
      await SyncMutationJournal.install(db);
      expect(
        (await SyncMutationJournal.current(
          db,
          SyncEntityKind.label,
          'label-id',
        ))!.revisionId,
        first.revisionId,
      );
      expect((await db.query('label')).single['name'], 'label');
    },
  );

  test(
    'bootstrap retains existing order snapshot identity and exact time',
    () async {
      await db.execute('DROP TRIGGER replica_order_insert');
      await db.insert('note_sort_context', {
        'context_key': 'main:grid',
        'sort_mode': 'custom',
        'revision': 'existing-order',
        'updated_at': '2026-01-02T03:04:05.123456Z',
      });
      await SyncMutationJournal.install(db);
      final version = (await SyncMutationJournal.current(
        db,
        SyncEntityKind.order,
        'main:grid',
      ))!;
      expect(version.revisionId, 'existing-order');
      expect(
        version.modifiedAtMicros,
        DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456).microsecondsSinceEpoch,
      );
    },
  );
}
