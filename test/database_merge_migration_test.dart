import 'dart:io';

import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/import/import_fingerprint_store.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  Future<bool> hasTable(Database database, String table) async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  test(
    'v11 reopens through the production upgrade and journals later writes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'better-keep-v11-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/fixture.sqlite';
      var db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 11,
          onCreate: (db, _) async {
            final sql = await File('test/fixtures/schema_v11_sync.sql')
                .readAsString();
            for (final statement in sql.split(';')) {
              if (statement.trim().isNotEmpty) await db.execute(statement);
            }
          },
        ),
      );
      await db.insert('note', {
        'id': 1,
        'sync_id': 'note-1',
        'content': 'preserve-media-and-text',
        'labels': 'Work',
      });
      for (var i = 1; i <= 2; i++) {
        await db.insert('label', {
          'id': i,
          'sync_id': 'label-$i',
          'name': 'Work',
        });
      }
      await db.insert('note_sort_context', {
        'context_key': 'all',
        'sort_mode': 'manual',
        'revision': 'order-1',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final before = {
        for (final table in ['note', 'label', 'note_sort_context'])
          table: await db.query(table),
      };
      await db.close();
      db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 12, onUpgrade: upgradeDatabase),
      );
      addTearDown(db.close);
      expect(await db.getVersion(), 12);
      for (final table in before.keys) {
        expect(await db.query(table), before[table]);
      }
      expect(await db.query(SyncMutationJournal.table), hasLength(4));
      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'replica_%'",
      );
      expect(triggers, hasLength(12));
      final initial = (await SyncMutationJournal.current(
        db,
        SyncEntityKind.note,
        'note-1',
      ))!;
      await db.update('note', {'title': 'edited'}, where: 'id = 1');
      final updated = (await SyncMutationJournal.current(
        db,
        SyncEntityKind.note,
        'note-1',
      ))!;
      expect(updated.compareTo(initial), greaterThan(0));
      await db.delete('label', where: 'id = 2');
      expect(
        (await SyncMutationJournal.current(
          db,
          SyncEntityKind.label,
          'label-2',
        ))!.deleted,
        true,
      );
      await db.update('note_sort_context', {'revision': 'order-2'});
      expect(
        (await SyncMutationJournal.current(
          db,
          SyncEntityKind.order,
          'all',
        ))!.revisionId,
        isNot('order-1'),
      );
      await db.insert('note', {'id': 2, 'sync_id': 'new-note'});
      expect(
        await SyncMutationJournal.current(db, SyncEntityKind.note, 'new-note'),
        isNotNull,
      );
      final versions = await db.query(SyncMutationJournal.table);
      await SyncMutationJournal.install(db);
      expect(await db.query(SyncMutationJournal.table), versions);
    },
  );

  for (final existingTable in [
    ImportFingerprintStore.table,
    RemoteContentRetryLedger.table,
  ]) {
    test(
      'version 11 completes the version 10 schema with $existingTable',
      () async {
        final database = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );
        addTearDown(database.close);

        if (existingTable == ImportFingerprintStore.table) {
          await ImportFingerprintStore.createTable(database);
        } else {
          await RemoteContentRetryLedger.createTable(database);
        }

        await upgradeMergedFeatureTables(database, 10, 11);

        expect(await hasTable(database, ImportFingerprintStore.table), isTrue);
        expect(
          await hasTable(database, RemoteContentRetryLedger.table),
          isTrue,
        );
      },
    );
  }

  test(
    'version 12 adds replica state without changing existing data',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await Note.createTable(database);
      await database.insert('note', {'id': 1, 'content': 'keep me'});
      await upgradeReplicaTables(database, 11, 12);
      await upgradeReplicaTables(database, 11, 12);
      for (final table in [
        'replica_entities',
        'replica_acknowledgements',
        'replica_inbox',
        'replica_cursors',
        'replica_attachment_cache',
        'replica_connection_status',
      ]) {
        expect(await hasTable(database, table), isTrue);
      }
      expect((await database.query('note')).single['content'], 'keep me');
    },
  );
}
