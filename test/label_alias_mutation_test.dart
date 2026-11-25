import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'renaming and deleting a displayed label updates aliases and memberships',
    () async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init(prefs: await SharedPreferences.getInstance());
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      AppState.db = db;
      await Note.createTable(db);
      await Label.createTable(db);
      await SyncMutationJournal.install(db);
      await db.insert('note', {
        'id': 1,
        'sync_id': 'note',
        'labels': 'Work,Home',
      });
      for (var i = 1; i <= 2; i++) {
        await db.insert('label', {
          'id': i,
          'sync_id': 'label-$i',
          'name': 'Work',
        });
      }
      final representative = Label.fromJson(
        (await db.query('label', where: 'id = 1')).single,
      )..name = 'Office';
      await representative.save(sync: false);
      expect((await db.query('label')).map((r) => r['name']), [
        'Office',
        'Office',
      ]);
      final labels = (await db.query('note')).single['labels'] as String;
      expect(labels, contains('Office'));
      expect(labels, contains('Home'));
      expect(labels, isNot(contains('Work')));
      await representative.delete(sync: false);
      expect(await db.query('label'), isEmpty);
      expect(
        (await db.query('note')).single['labels'],
        isNot(contains('Office')),
      );
      for (var i = 1; i <= 2; i++) {
        expect(
          (await SyncMutationJournal.current(
            db,
            SyncEntityKind.label,
            'label-$i',
          ))!.deleted,
          true,
        );
      }
    },
  );
}
