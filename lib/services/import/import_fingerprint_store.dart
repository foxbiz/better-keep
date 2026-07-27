import 'package:sqflite/sqflite.dart';

class ImportFingerprintStore {
  static const table = 'import_fingerprint';

  const ImportFingerprintStore._();

  static Future<void> createTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS $table (
      fingerprint TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      note_id INTEGER NOT NULL,
      imported_at DATETIME NOT NULL
    )
  ''');

  static Future<Set<String>> getForSource(
    DatabaseExecutor db,
    String source,
  ) async {
    final rows = await db.query(
      table,
      columns: const ['fingerprint'],
      where: 'source = ?',
      whereArgs: [source],
    );
    return rows.map((row) => row['fingerprint'] as String).toSet();
  }
}
