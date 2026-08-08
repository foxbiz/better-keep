import 'package:better_keep/services/database.dart';
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
}
