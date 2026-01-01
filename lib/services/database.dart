import 'dart:io';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

Future<Database> initDatabase() async {
  String dbPath;
  if (!kIsWeb && Platform.isWindows) {
    final appSupportDir = await getApplicationSupportDirectory();
    dbPath = p.join(appSupportDir.path, databaseName);
  } else {
    dbPath = databaseName;
  }

  final db = await openDatabase(
    dbPath,
    onCreate: (db, version) async {
      await Note.createTable(db);
      await Label.createTable(db);
      await NoteSyncTrack.createTable(db);
      await FileSyncTrack.createTable(db);
      await LabelSyncTrack.createTable(db);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      await Note.upgradeTable(db, oldVersion, newVersion);
      await Label.upgradeTable(db, oldVersion, newVersion);
      await NoteSyncTrack.upgradeTable(db, oldVersion, newVersion);
      await FileSyncTrack.upgradeTable(db, oldVersion, newVersion);
      await LabelSyncTrack.upgradeTable(db, oldVersion, newVersion);
    },
    version: databaseVersion,
  );

  AppState.db = db;
  return db;
}
