import 'package:sqflite/sqflite.dart';

class ReminderActionReceipt {
  const ReminderActionReceipt({
    required this.token,
    required this.noteId,
    required this.action,
    required this.createdAt,
  });

  final String token;
  final int noteId;
  final String action;
  final DateTime createdAt;
}

/// Durable idempotency receipts for notification actions. A notification can
/// be delivered more than once by the OS, so every occurrence is claimed
/// before its note is mutated.
class ReminderActionReceiptService {
  static const table = 'reminder_action_receipt';

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        token TEXT PRIMARY KEY,
        note_id INTEGER,
        action TEXT,
        ui_consumed_at TEXT,
        created_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> upgradeTable(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 5) await createTable(db);
    if (oldVersion < 6) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      final names = columns.map((column) => column['name']).toSet();
      if (!names.contains('note_id')) {
        await db.execute('ALTER TABLE $table ADD COLUMN note_id INTEGER');
      }
      if (!names.contains('action')) {
        await db.execute('ALTER TABLE $table ADD COLUMN action TEXT');
      }
      if (!names.contains('ui_consumed_at')) {
        await db.execute('ALTER TABLE $table ADD COLUMN ui_consumed_at TEXT');
      }
    }
  }

  static Future<bool> claim(
    DatabaseExecutor db,
    String token, {
    required int noteId,
    required String action,
    DateTime? now,
  }) async {
    final result = await db.insert(table, {
      'token': token,
      'note_id': noteId,
      'action': action,
      'created_at': (now ?? DateTime.now()).toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return result != 0;
  }

  static Future<bool> exists(DatabaseExecutor db, String token) async {
    final rows = await db.query(
      table,
      columns: const ['token'],
      where: 'token = ?',
      whereArgs: [token],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<List<ReminderActionReceipt>> pendingUiUpdates(
    Database db,
  ) async {
    final rows = await db.query(
      table,
      columns: const ['token', 'note_id', 'action', 'created_at'],
      where: 'ui_consumed_at IS NULL AND note_id IS NOT NULL',
      orderBy: 'created_at ASC, token ASC',
    );
    return rows
        .map((row) {
          return ReminderActionReceipt(
            token: row['token']! as String,
            noteId: row['note_id']! as int,
            action: row['action'] as String? ?? 'unknown',
            createdAt: DateTime.parse(row['created_at']! as String),
          );
        })
        .toList(growable: false);
  }

  static Future<void> markUiConsumed(
    Database db,
    String token, {
    DateTime? now,
  }) async {
    await db.update(
      table,
      {'ui_consumed_at': (now ?? DateTime.now()).toIso8601String()},
      where: 'token = ? AND ui_consumed_at IS NULL',
      whereArgs: [token],
    );
  }

  static Future<void> prune(Database db, {DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 30));
    await db.delete(
      table,
      where: 'created_at < ?',
      whereArgs: [cutoff.toIso8601String()],
    );
  }
}
