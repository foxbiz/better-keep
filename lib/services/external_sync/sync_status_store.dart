import 'package:sqflite/sqflite.dart';

import '../async_keyed_serializer.dart';
import 'sync_replica_engine.dart';

/// Local, account/library/connection-generation scoped history for settings.
/// Only complete successful passes advance the timestamp.
class SyncStatusStore {
  SyncStatusStore({
    required this.database,
    required this.scope,
    required this.isCurrent,
    this.onChanged,
  });
  final Database database;
  final String scope;
  final bool Function() isCurrent;
  final void Function()? onChanged;
  final _successes = <String, DateTime>{};
  final _writes = AsyncKeyedSerializer<String>();
  Future<void>? _loading;

  Map<String, DateTime> get lastSuccess => Map.unmodifiable(_successes);
  static Future<void> createTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS replica_connection_status (
      scope TEXT NOT NULL, connection_id TEXT NOT NULL,
      last_success_micros INTEGER NOT NULL,
      PRIMARY KEY(scope, connection_id))
  ''');

  void _guard() {
    if (!isCurrent()) throw const SyncReplicaCancelled();
  }

  Future<void> load() =>
      _loading ??= _load().onError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _load() async {
    _guard();
    final rows = await database.query(
      'replica_connection_status',
      where: 'scope = ?',
      whereArgs: [scope],
    );
    _guard();
    for (final row in rows) {
      final time = DateTime.fromMicrosecondsSinceEpoch(
        row['last_success_micros'] as int,
        isUtc: true,
      );
      _remember(row['connection_id'] as String, time);
    }
    onChanged?.call();
  }

  Future<DateTime?> read(String connectionId) async {
    await load();
    _guard();
    return _successes[connectionId];
  }

  void _remember(String id, DateTime time) {
    if (_successes[id]?.isAfter(time) ?? false) return;
    _successes[id] = time.toUtc();
  }

  Future<void> save(String connectionId, DateTime time) =>
      _writes.run(connectionId, () async {
        _guard();
        final stored = await database.transaction((txn) async {
          _guard();
          await txn.rawInsert(
            '''INSERT INTO replica_connection_status
        (scope, connection_id, last_success_micros) VALUES (?, ?, ?)
        ON CONFLICT(scope, connection_id) DO UPDATE SET last_success_micros =
          MAX(last_success_micros, excluded.last_success_micros)''',
            [scope, connectionId, time.microsecondsSinceEpoch],
          );
          final rows = await txn.query(
            'replica_connection_status',
            where: 'scope = ? AND connection_id = ?',
            whereArgs: [scope, connectionId],
          );
          _guard();
          return rows.single['last_success_micros'] as int;
        });
        _guard();
        _remember(
          connectionId,
          DateTime.fromMicrosecondsSinceEpoch(stored, isUtc: true),
        );
        onChanged?.call();
      });

  Future<void> waitForIdle() async {
    try {
      await _loading;
    } on SyncReplicaCancelled {
      /* Retired read is expected. */
    }
    await _writes.waitForAll();
  }
}
