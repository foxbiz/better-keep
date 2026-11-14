import 'dart:io';

import 'local_storage_recovery.dart';

import 'package:better_keep/config.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/sync_identity_migration.dart';
import 'package:better_keep/services/import/import_fingerprint_store.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

Future<Database> initDatabase({bool detectDataLoss = false}) async {
  final dbPath = await activeDatabasePath();

  final db = await openDatabase(
    dbPath,
    onCreate: (db, version) async {
      await Note.createTable(db);
      await Label.createTable(db);
      await NoteSyncTrack.createTable(db);
      await FileSyncTrack.createTable(db);
      await LabelSyncTrack.createTable(db);
      await ReminderActionReceiptService.createTable(db);
      await NoteSortService.createTable(db);
      await ImportFingerprintStore.createTable(db);
      await RemoteContentRetryLedger.createTable(db);
      await SyncIdentityMigration.migrate(db);
      if (detectDataLoss) {
        await LocalStorageRecovery(await SharedPreferences.getInstance())
            .databaseCreated();
      }
      await SyncReplicaStore.createTables(db);
      await SyncAttachmentStore.createTable(db);
      await SyncStatusStore.createTable(db);
      await SyncMutationJournal.install(db);
    },
    onUpgrade: upgradeDatabase,
    version: databaseVersion,
  );

  AppState.db = db;
  return db;
}

/// Shared with upgrade tests so they exercise the same ordered migration chain.
Future<void> upgradeDatabase(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  await Note.upgradeTable(db, oldVersion, newVersion);
  await Label.upgradeTable(db, oldVersion, newVersion);
  await NoteSyncTrack.upgradeTable(db, oldVersion, newVersion);
  await FileSyncTrack.upgradeTable(db, oldVersion, newVersion);
  await LabelSyncTrack.upgradeTable(db, oldVersion, newVersion);
  await ReminderActionReceiptService.upgradeTable(db, oldVersion, newVersion);
  if (oldVersion < 9 && newVersion >= 9) {
    await SyncIdentityMigration.migrate(db);
  }
  await NoteSortService.upgradeTable(db, oldVersion, newVersion);
  await upgradeMergedFeatureTables(db, oldVersion, newVersion);
  await upgradeReplicaTables(db, oldVersion, newVersion);
}

Future<void> upgradeReplicaTables(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  if (oldVersion < 12 && newVersion >= 12) {
    await SyncReplicaStore.createTables(db);
    await SyncAttachmentStore.createTable(db);
    await SyncStatusStore.createTable(db);
    await SyncMutationJournal.install(db);
  }
  if (oldVersion < 13 && newVersion >= 13) {
    final columns = await db.rawQuery('PRAGMA table_info(replica_cursors)');
    if (!columns.any((column) => column['name'] == 'checked_notes')) {
      // Zero conservatively treats legacy cursors as an unfinished listing.
      await db.execute(
        'ALTER TABLE replica_cursors ADD COLUMN checked_notes INTEGER DEFAULT 0',
      );
    }
  }
}

/// Reconciles the two different schemas that existed at database version 10.
///
/// The SEO line added import fingerprints while main added the remote retry
/// ledger. Version 11 idempotently creates both so an installation upgraded
/// through either history reaches the same schema.
Future<void> upgradeMergedFeatureTables(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  await RemoteContentRetryLedger.upgradeTable(db, oldVersion, newVersion);
  if (oldVersion < 11 && newVersion >= 11) {
    await ImportFingerprintStore.createTable(db);
    await RemoteContentRetryLedger.createTable(db);
  }
}

/// Desktop sqflite can report success when a locked database survives deletion.
Future<void> deleteSignedOutDatabase(String path) async {
  await deleteDatabase(path);
  await verifySignedOutDatabaseRemoved(path);
}

Future<void> verifySignedOutDatabaseRemoved(String path) async {
  if (await databaseExists(path)) {
    throw StateError('Account database is still in use');
  }
  if (kIsWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }
  final absolute = p.isAbsolute(path)
      ? path
      : p.join(await getDatabasesPath(), path);
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    // Metadata probes can also report "not found" on access errors. Opening
    // read-only distinguishes a missing file from an unreadable or locked one.
    final file = File('$absolute$suffix');
    try {
      await (await file.open()).close();
    } on PathNotFoundException {
      if (!await FileSystemEntity.isLink(file.path)) continue;
    }
    throw StateError('Account database files are still in use');
  }
}

Future<String> activeDatabasePath() async {
  final databaseName = FirebaseBackend.isConfigured
      ? activeDatabaseName
      : FirebaseScopedPreferences.scopeForPreferences(
          await SharedPreferences.getInstance(),
        ).databaseName;
  if (!kIsWeb && Platform.isWindows) {
    final appSupportDir = await getApplicationSupportDirectory();
    return p.join(appSupportDir.path, databaseName);
  }
  return databaseName;
}
