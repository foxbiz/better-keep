import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Database db;
  var current = true;
  final first = DateTime.utc(2026, 1, 1), second = DateTime.utc(2026, 1, 2);
  SyncStatusStore store([String scope = 'account/library']) =>
      SyncStatusStore(database: db, scope: scope, isCurrent: () => current);
  setUp(() async {
    current = true;
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SyncStatusStore.createTable(db);
  });
  tearDown(() => db.close());
  test('success survives restart and is isolated by account, library and connection generation', () async {
    await store().save('drive:1', first);
    expect(await store().read('drive:1'), first);
    expect(await store('other/library').read('drive:1'), isNull);
    expect(await store('account/rotated').read('drive:1'), isNull);
    expect(await store().read('drive:2'), isNull);
    expect(await store().read('dropbox:1'), isNull);
  });
  test(
    'concurrent and clock-reversed writes cannot move success backwards',
    () async {
      final history = store();
      await Future.wait([
        history.save('drive:1', second),
        history.save('drive:1', first),
      ]);
      expect(history.lastSuccess['drive:1'], second);
      expect(await store().read('drive:1'), second);
      await history.load();
      expect(history.lastSuccess['drive:1'], second);
    },
  );
  test(
    'retirement rejects queued writes without crossing account cleanup',
    () async {
      final history = store();
      current = false;
      await expectLater(
        history.save('drive:1', first),
        throwsA(isA<SyncReplicaCancelled>()),
      );
      await history.waitForIdle();
      expect(await db.query('replica_connection_status'), isEmpty);
    },
  );
}
