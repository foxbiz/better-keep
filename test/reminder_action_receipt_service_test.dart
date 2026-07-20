import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await ReminderActionReceiptService.createTable(database);
  });

  tearDown(() => database.close());

  test('an occurrence action can only be claimed once', () async {
    expect(
      await ReminderActionReceiptService.claim(
        database,
        'note:1:rev:1',
        noteId: 1,
        action: 'mark_done',
      ),
      isTrue,
    );
    expect(
      await ReminderActionReceiptService.claim(
        database,
        'note:1:rev:1',
        noteId: 1,
        action: 'mark_done',
      ),
      isFalse,
    );
  });

  test('old receipts are pruned without removing recent receipts', () async {
    final now = DateTime(2026, 7, 20);
    await ReminderActionReceiptService.claim(
      database,
      'old',
      noteId: 1,
      action: 'mark_done',
      now: now.subtract(const Duration(days: 31)),
    );
    await ReminderActionReceiptService.claim(
      database,
      'new',
      noteId: 2,
      action: 'mark_done',
      now: now,
    );

    await ReminderActionReceiptService.prune(database, now: now);

    final rows = await database.query(ReminderActionReceiptService.table);
    expect(rows.map((row) => row['token']), ['new']);
  });

  test('pending UI receipts are consumed exactly once', () async {
    final createdAt = DateTime(2026, 7, 20, 10);
    await ReminderActionReceiptService.claim(
      database,
      'one',
      noteId: 17,
      action: 'mark_done',
      now: createdAt,
    );

    final pending = await ReminderActionReceiptService.pendingUiUpdates(
      database,
    );
    expect(pending, hasLength(1));
    expect(pending.single.token, 'one');
    expect(pending.single.noteId, 17);
    expect(pending.single.action, 'mark_done');
    expect(pending.single.createdAt, createdAt);

    await ReminderActionReceiptService.markUiConsumed(database, 'one');
    await ReminderActionReceiptService.markUiConsumed(database, 'one');
    expect(
      await ReminderActionReceiptService.pendingUiUpdates(database),
      isEmpty,
    );
  });

  test('version 6 migration adds UI handoff metadata', () async {
    await database.execute('DROP TABLE ${ReminderActionReceiptService.table}');
    await database.execute('''
      CREATE TABLE ${ReminderActionReceiptService.table} (
        token TEXT PRIMARY KEY,
        created_at TEXT NOT NULL
      )
    ''');

    await ReminderActionReceiptService.upgradeTable(database, 5, 6);

    final columns = await database.rawQuery(
      'PRAGMA table_info(${ReminderActionReceiptService.table})',
    );
    expect(
      columns.map((column) => column['name']),
      containsAll(['note_id', 'action', 'ui_consumed_at']),
    );
  });
}
