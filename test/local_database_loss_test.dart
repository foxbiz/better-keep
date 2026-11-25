import 'dart:io';

import 'package:better_keep/config.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'a newer schema is rejected without changing its version or data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'downgrade-fixture-',
      );
      final previousPath = await databaseFactory.getDatabasesPath();
      await databaseFactory.setDatabasesPath(directory.path);
      Database? db;
      addTearDown(() async {
        await db?.close();
        await databaseFactory.setDatabasesPath(previousPath);
        await directory.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final recovery = LocalStorageRecovery(
        await SharedPreferences.getInstance(),
      );
      db = await initDatabase(detectDataLoss: true);
      final fixturePath = db.path;
      await db.execute('CREATE TABLE future_data (value TEXT)');
      await db.insert('future_data', {'value': 'preserve me'});
      await db.setVersion(databaseVersion + 1);
      await db.close();

      await expectLater(
        initDatabase(detectDataLoss: true),
        throwsA(
          isA<DatabaseUpdateRequired>().having(
            (error) => error.message,
            'message',
            contains('Update the app'),
          ),
        ),
      );
      db = await databaseFactory.openDatabase(fixturePath);
      expect(await db.getVersion(), databaseVersion + 1);
      expect(await db.query('future_data'), [
        {'value': 'preserve me'},
      ]);
      expect(recovery.pending, false);
    },
  );

  test(
    'fresh v14 schema is safe; only confirmed recreation requests logout',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'storage-loss-fixture-',
      );
      final previousPath = await databaseFactory.getDatabasesPath();
      await databaseFactory.setDatabasesPath(directory.path);
      Database? db;
      addTearDown(() async {
        await db?.close();
        await databaseFactory.setDatabasesPath(previousPath);
        await directory.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final recovery = LocalStorageRecovery(prefs);

      db = await initDatabase(detectDataLoss: true);
      expect(recovery.pending, false); // First install.
      expect(await db.getVersion(), 14);
      expect(await db.query('replica_upload_intents'), isEmpty);
      final fixturePath = db.path;
      expect(fixturePath, startsWith(directory.path));
      await db.close();
      await prefs.setString('user_uid', 'fixture-account');
      db = await initDatabase(detectDataLoss: true);
      expect(recovery.pending, false); // Existing, legitimately empty database.
      await db.close();

      // A directory at the database path makes SQLite opening fail without
      // touching anything outside this disposable test directory.
      await File(fixturePath).rename('$fixturePath.saved');
      await Directory(fixturePath).create();
      await expectLater(
        initDatabase(detectDataLoss: true),
        throwsA(isA<DatabaseException>()),
      );
      expect(recovery.pending, false);
      await Directory(fixturePath).delete();
      await File('$fixturePath.saved').rename(fixturePath);

      await databaseFactory.deleteDatabase(fixturePath);
      db = await initDatabase(detectDataLoss: true);
      expect(recovery.pending, true);
      expect(LocalStorageRecovery.notice.value, 'cleared');
      await recovery.completeLogout();
    },
  );
}
