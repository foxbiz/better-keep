import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/firebase_order_tombstones.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/sync_logout_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(db);
    await Label.createTable(db);
    await NoteSyncTrack.createTable(db);
    await LabelSyncTrack.createTable(db);
    await NoteSortService.createTable(db);
    await SyncReplicaStore.createTables(db);
    await SyncMutationJournal.install(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<SyncLogoutState> inspect({
    bool? firebase = false,
    List<String> destinations = const ['google_drive:1'],
    bool metadata = true,
    String scope = 'account:library',
    bool Function()? current,
  }) => inspectSyncBeforeLogout(
    database: db,
    firebaseEnabled: firebase,
    firebaseAccountId: 'account',
    scope: scope,
    externalReplicaIds: destinations,
    metadataReady: metadata,
    isCurrent: current ?? () => true,
  );

  Future<void> acknowledge(String destination) async {
    final versions = await db.query(SyncMutationJournal.table);
    await db.transaction((txn) async {
      for (final row in versions) {
        final version = SyncLocalVersion.fromRow(row);
        final revision = version.materialize(
          payloadObjectId: version.deleted ? null : 'a' * 64,
          contentFingerprint: version.deleted ? null : 'b' * 64,
        );
        await SyncReplicaStore(
          db,
          scope: 'account:library',
        ).acknowledge(txn, destination, revision);
      }
    });
  }

  test('uncaptured edits and every selected destination require current acknowledgements', () async {
    await db.insert('note', {'id': 1, 'sync_id': 'note-1', 'title': 'Local'});
    expect(await inspect(), SyncLogoutState.pending);
    await acknowledge('google_drive:1');
    expect(await inspect(), SyncLogoutState.complete);
    expect(
      await inspect(destinations: ['google_drive:1', 'dropbox:1']),
      SyncLogoutState.pending,
    );
    await acknowledge('dropbox:1');
    expect(
      await inspect(destinations: ['google_drive:1', 'dropbox:1']),
      SyncLogoutState.complete,
    );
    await db.update('note', {'title': 'Newer edit'}, where: 'id = 1');
    expect(await inspect(), SyncLogoutState.pending);
  });

  test('old account, encryption library and connection generation acknowledgements cannot hide pending work', () async {
    await db.insert('note', {'id': 1, 'sync_id': 'note-1'});
    await acknowledge('google_drive:1');
    expect(await inspect(scope: 'other:library'), SyncLogoutState.pending);
    expect(await inspect(scope: 'account:rotated'), SyncLogoutState.pending);
    expect(
      await inspect(destinations: ['google_drive:2']),
      SyncLogoutState.pending,
    );
  });

  test(
    'label and order changes and tombstones participate independently of notes',
    () async {
      await db.insert('label', {'id': 1, 'sync_id': 'label-1', 'name': 'Work'});
      expect(await inspect(), SyncLogoutState.pending);
      await acknowledge('google_drive:1');
      await db.insert('note_sort_context', {
        'context_key': 'main:grid',
        'sort_mode': 'custom',
        'revision': 'order-1',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      expect(await inspect(), SyncLogoutState.pending);
      await acknowledge('google_drive:1');
      expect(await inspect(), SyncLogoutState.complete);
      await db.delete('label', where: 'id = 1');
      expect(await inspect(), SyncLogoutState.pending);
      await acknowledge('google_drive:1');
      await db.delete('note_sort_context');
      expect(await inspect(), SyncLogoutState.pending);
      await acknowledge('google_drive:1');
      expect(await inspect(), SyncLogoutState.complete);
    },
  );

  test(
    'paused Firebase does not block a completely acknowledged external library',
    () async {
      await db.insert('note', {'id': 1, 'sync_id': 'note-1'});
      await db.insert('sync_track', {
        'local_id': 1,
        'action': 'create',
        'status': 'pending',
      });
      await acknowledge('google_drive:1');
      expect(await inspect(firebase: false), SyncLogoutState.complete);
      expect(await inspect(firebase: true), SyncLogoutState.pending);
    },
  );

  test('Firebase failure, active upload and missing queue rows all warn before logout', () async {
    await db.insert('note', {'id': 1, 'sync_id': 'note-1'});
    expect(
      await inspect(firebase: true, destinations: []),
      SyncLogoutState.pending,
    );
    await db.insert('sync_track', {
      'local_id': 1,
      'action': 'create',
      'remote_id': 'note-1',
      'status': 'synced',
    });
    expect(
      await inspect(firebase: true, destinations: []),
      SyncLogoutState.complete,
    );
    for (final status in ['pending', 'failed', 'syncing']) {
      await db.update('sync_track', {'status': status});
      expect(
        await inspect(firebase: true, destinations: []),
        SyncLogoutState.pending,
      );
    }
    await db.delete('note');
    expect(
      await inspect(firebase: true, destinations: []),
      SyncLogoutState.pending,
    );
  });

  test(
    'Firebase-only labels and ordering cannot be hidden by an empty note queue',
    () async {
      await db.insert('label_sync_track', {
        'local_id': 1,
        'action': 'delete',
        'status': 'failed',
      });
      expect(
        await inspect(firebase: true, destinations: []),
        SyncLogoutState.pending,
      );
      await db.delete('label_sync_track');
      await db.insert('note_sort_context', {
        'context_key': 'main:grid',
        'sort_mode': 'custom',
        'revision': 'order-1',
        'updated_at': '2026-01-01T00:00:00Z',
        'dirty': 1,
      });
      expect(
        await inspect(firebase: true, destinations: []),
        SyncLogoutState.pending,
      );
      await db.delete('note_sort_context');
      expect(
        await inspect(firebase: true, destinations: []),
        SyncLogoutState.pending,
      );
      final deleted = (await FirebaseOrderTombstones.pending(
        db,
        'account',
      )).single;
      await db.transaction(
        (txn) =>
            FirebaseOrderTombstones.acknowledge(db, txn, 'account', deleted),
      );
      expect(
        await inspect(firebase: true, destinations: []),
        SyncLogoutState.complete,
      );
    },
  );

  test('no enabled destination still warns about local-only changes', () async {
    await db.insert('note', {'id': 1, 'sync_id': 'note-1'});
    expect(
      await inspect(firebase: false, destinations: []),
      SyncLogoutState.pending,
    );
  });

  test('unknown metadata, account changes and database errors never imply successful sync', () async {
    expect(await inspect(metadata: false), SyncLogoutState.unknown);
    expect(await inspect(firebase: null), SyncLogoutState.unknown);
    var calls = 0;
    expect(await inspect(current: () => ++calls == 1), SyncLogoutState.unknown);
    await db.close();
    expect(await inspect(), SyncLogoutState.unknown);
  });
}
