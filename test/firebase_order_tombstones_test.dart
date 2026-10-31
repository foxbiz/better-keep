import 'package:better_keep/services/external_sync/firebase_order_tombstones.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Database db;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SyncReplicaStore.createTables(db);
    await SyncMutationJournal.install(db);
  });
  tearDown(() => db.close());

  SyncVersion version(String id, int timestamp, {bool deleted = true}) =>
      SyncVersion(
        kind: SyncEntityKind.order,
        entityId: 'main:grid',
        revisionId: id,
        modifiedAtMicros: timestamp,
        deleted: deleted,
      );
  Future<void> receive(SyncVersion value) => db.transaction(
    (txn) => SyncMutationJournal.received(txn, value, value.entityId),
  );
  Future<void> acknowledge(SyncVersion value, [String uid = 'user']) =>
      db.transaction(
        (txn) => FirebaseOrderTombstones.acknowledge(db, txn, uid, value),
      );

  test(
    'deletion remains pending until its captured version is acknowledged',
    () async {
      final first = version('delete-1', 1);
      final newer = version('delete-2', 2);
      await receive(first);
      expect(
        (await FirebaseOrderTombstones.pending(db, 'user')).single.revisionId,
        'delete-1',
      );
      await receive(newer);
      await acknowledge(first);
      expect(
        (await FirebaseOrderTombstones.pending(db, 'user')).single.revisionId,
        'delete-2',
      );
      await acknowledge(newer);
      expect(await FirebaseOrderTombstones.pending(db, 'user'), isEmpty);
      await acknowledge(
        first,
      ); // A late completion cannot regress the checkpoint.
      expect(await FirebaseOrderTombstones.pending(db, 'user'), isEmpty);
    },
  );

  test('Firebase acknowledgement cannot acknowledge another account or external destination', () async {
    final deleted = version('deleted', 1);
    await receive(deleted);
    await acknowledge(deleted);
    expect(await FirebaseOrderTombstones.pending(db, 'other'), hasLength(1));
    final rows = await db.query('replica_acknowledgements');
    expect(rows.single['scope'], FirebaseOrderTombstones.scope('user'));
    expect(rows.single['connection_id'], 'firebase');
    expect(await db.query('replica_entities'), isEmpty);
  });

  test('revivals do not become pending deletions and cannot be acknowledged as tombstones', () async {
    final live = version('revived', 2, deleted: false);
    await receive(live);
    expect(await FirebaseOrderTombstones.pending(db, 'user'), isEmpty);
    await expectLater(acknowledge(live), throwsFormatException);
  });

  test(
    'cancelled acknowledgement transaction leaves deletion pending',
    () async {
      final deleted = version('deleted', 1);
      await receive(deleted);
      await expectLater(
        db.transaction((txn) async {
          await FirebaseOrderTombstones.acknowledge(db, txn, 'user', deleted);
          throw StateError('Session retired before commit');
        }),
        throwsStateError,
      );
      expect(await FirebaseOrderTombstones.pending(db, 'user'), hasLength(1));
    },
  );
}
