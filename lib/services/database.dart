import 'dart:io';
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
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

Future<Database> initDatabase() async {
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
      await RemoteContentRetryLedger.createTable(db);
      await SyncIdentityMigration.migrate(db);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      await Note.upgradeTable(db, oldVersion, newVersion);
      await Label.upgradeTable(db, oldVersion, newVersion);
      await NoteSyncTrack.upgradeTable(db, oldVersion, newVersion);
      await FileSyncTrack.upgradeTable(db, oldVersion, newVersion);
      await LabelSyncTrack.upgradeTable(db, oldVersion, newVersion);
      await ReminderActionReceiptService.upgradeTable(
        db,
        oldVersion,
        newVersion,
      );
      if (oldVersion < 9 && newVersion >= 9) {
        await SyncIdentityMigration.migrate(db);
      }
      await NoteSortService.upgradeTable(db, oldVersion, newVersion);
      await RemoteContentRetryLedger.upgradeTable(db, oldVersion, newVersion);
    },
    version: databaseVersion,
  );

  AppState.db = db;
  return db;
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
