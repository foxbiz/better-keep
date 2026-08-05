import 'dart:math';

import 'package:better_keep/state.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:sqflite/sqflite.dart';

enum RemoteContentRetryState { waiting, deferred, exhausted }

class RemoteContentRetryEntry {
  const RemoteContentRetryEntry({
    required this.userId,
    required this.remoteDocumentId,
    required this.revision,
    required this.localId,
    required this.attempts,
    required this.category,
    required this.errorCode,
    required this.state,
    required this.updatedAt,
    this.nextRetryAt,
  });

  final String userId;
  final String remoteDocumentId;
  final String revision;
  final int localId;
  final int attempts;
  final RemoteNoteFailureCategory category;
  final String errorCode;
  final RemoteContentRetryState state;
  final DateTime? nextRetryAt;
  final DateTime updatedAt;

  bool get isExhausted => state == RemoteContentRetryState.exhausted;

  factory RemoteContentRetryEntry.fromRow(Map<String, Object?> row) {
    return RemoteContentRetryEntry(
      userId: row['user_id']! as String,
      remoteDocumentId: row['remote_document_id']! as String,
      revision: row['revision']! as String,
      localId: row['local_id']! as int,
      attempts: row['attempts']! as int,
      category: RemoteNoteFailureCategory.values.byName(
        row['category']! as String,
      ),
      errorCode: row['error_code']! as String,
      state: RemoteContentRetryState.values.byName(row['state']! as String),
      nextRetryAt: row['next_retry_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['next_retry_at']! as int,
              isUtc: true,
            ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at']! as int,
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> toRow() => {
    'user_id': userId,
    'remote_document_id': remoteDocumentId,
    'revision': revision,
    'local_id': localId,
    'attempts': attempts,
    'category': category.name,
    'error_code': errorCode,
    'state': state.name,
    'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };
}

class RemoteContentRetryLedger {
  RemoteContentRetryLedger({
    Database Function()? database,
    this.maxAttempts = 5,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    this.jitterRatio = 0.2,
    double Function()? randomDouble,
  }) : assert(maxAttempts > 0),
       assert(retryDelays.length >= maxAttempts - 1),
       assert(jitterRatio >= 0),
       _database = database ?? (() => AppState.db),
       _randomDouble = randomDouble ?? Random().nextDouble;

  static const table = 'remote_content_retry';

  final Database Function() _database;
  final int maxAttempts;
  final List<Duration> retryDelays;
  final double jitterRatio;
  final double Function() _randomDouble;

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $table (
        user_id TEXT NOT NULL,
        remote_document_id TEXT NOT NULL,
        revision TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        attempts INTEGER NOT NULL,
        category TEXT NOT NULL,
        error_code TEXT NOT NULL,
        state TEXT NOT NULL,
        next_retry_at INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, remote_document_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_remote_content_retry_local '
      'ON $table(user_id, local_id)',
    );
  }

  static Future<void> upgradeTable(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 10 && newVersion >= 10) {
      await createTable(db);
    }
  }

  Future<RemoteContentRetryEntry?> get(String userId, String remoteDocumentId) {
    return _getFrom(_database(), userId, remoteDocumentId);
  }

  Future<RemoteContentRetryEntry?> _getFrom(
    DatabaseExecutor database,
    String userId,
    String remoteDocumentId,
  ) async {
    final rows = await database.query(
      table,
      where: 'user_id = ? AND remote_document_id = ?',
      whereArgs: [userId, remoteDocumentId],
      limit: 1,
    );
    return rows.isEmpty ? null : RemoteContentRetryEntry.fromRow(rows.single);
  }

  Future<RemoteContentRetryEntry?> getByLocalId(
    String userId,
    int localId,
  ) async {
    final rows = await _database().query(
      table,
      where: 'user_id = ? AND local_id = ?',
      whereArgs: [userId, localId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : RemoteContentRetryEntry.fromRow(rows.single);
  }

  Future<List<RemoteContentRetryEntry>> listForUser(String userId) async {
    final rows = await _database().query(
      table,
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at ASC',
    );
    return rows.map(RemoteContentRetryEntry.fromRow).toList();
  }

  /// Records one failed automatic attempt. A different revision starts a new
  /// budget; cache recreation cannot reset a matching revision.
  Future<RemoteContentRetryEntry> recordAutomaticFailure({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required int localId,
    required RemoteNoteFailureCategory category,
    required String errorCode,
    required bool permanent,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return _database().transaction((transaction) async {
      final existing = await _getFrom(transaction, userId, remoteDocumentId);
      if (existing?.revision == revision && existing!.isExhausted) {
        return existing;
      }
      final attempts = existing == null || existing.revision != revision
          ? 1
          : existing.attempts + 1;
      final exhausted = permanent || attempts >= maxAttempts;
      final delayIndex = attempts - 1;
      final baseDelay = exhausted ? Duration.zero : retryDelays[delayIndex];
      final jitter = exhausted
          ? Duration.zero
          : Duration(
              milliseconds:
                  (baseDelay.inMilliseconds * jitterRatio * _randomDouble())
                      .round(),
            );
      final nextRetryAt = exhausted ? null : timestamp.add(baseDelay + jitter);
      final entry = RemoteContentRetryEntry(
        userId: userId,
        remoteDocumentId: remoteDocumentId,
        revision: revision,
        localId: localId,
        attempts: attempts,
        category: category,
        errorCode: errorCode,
        state: exhausted
            ? RemoteContentRetryState.exhausted
            : RemoteContentRetryState.waiting,
        nextRetryAt: nextRetryAt,
        updatedAt: timestamp,
      );
      await transaction.insert(
        table,
        entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return entry;
    });
  }

  /// A failed manual attempt remains terminal and never creates a timer.
  Future<RemoteContentRetryEntry> recordManualFailure({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required int localId,
    required RemoteNoteFailureCategory category,
    required String errorCode,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final existing = await get(userId, remoteDocumentId);
    final entry = RemoteContentRetryEntry(
      userId: userId,
      remoteDocumentId: remoteDocumentId,
      revision: revision,
      localId: localId,
      attempts: existing?.revision == revision
          ? max(existing!.attempts, maxAttempts)
          : maxAttempts,
      category: category,
      errorCode: errorCode,
      state: RemoteContentRetryState.exhausted,
      updatedAt: timestamp,
    );
    await _database().insert(
      table,
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return entry;
  }

  Future<RemoteContentRetryEntry> recordDeferred({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required int localId,
    required RemoteNoteFailureCategory category,
    required String errorCode,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final existing = await get(userId, remoteDocumentId);
    final entry = RemoteContentRetryEntry(
      userId: userId,
      remoteDocumentId: remoteDocumentId,
      revision: revision,
      localId: localId,
      attempts: existing?.revision == revision ? existing!.attempts : 0,
      category: category,
      errorCode: errorCode,
      state: RemoteContentRetryState.deferred,
      updatedAt: timestamp,
    );
    await _database().insert(
      table,
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return entry;
  }

  /// Makes a durable dependency deferral eligible for an immediate attempt.
  ///
  /// The attempt count remains unchanged. Persisting an immediate retry time
  /// ensures a process restart between dependency readiness and reconciliation
  /// cannot strand the entry without either a timer or visible failure state.
  Future<RemoteContentRetryEntry?> activateDeferred({
    required String userId,
    required String remoteDocumentId,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return _database().transaction((transaction) async {
      final existing = await _getFrom(transaction, userId, remoteDocumentId);
      if (existing == null ||
          existing.state != RemoteContentRetryState.deferred) {
        return existing;
      }
      final entry = RemoteContentRetryEntry(
        userId: existing.userId,
        remoteDocumentId: existing.remoteDocumentId,
        revision: existing.revision,
        localId: existing.localId,
        attempts: existing.attempts,
        category: existing.category,
        errorCode: existing.errorCode,
        state: RemoteContentRetryState.waiting,
        nextRetryAt: timestamp,
        updatedAt: timestamp,
      );
      await transaction.insert(
        table,
        entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return entry;
    });
  }

  Future<void> clear(String userId, String remoteDocumentId) {
    return _database().delete(
      table,
      where: 'user_id = ? AND remote_document_id = ?',
      whereArgs: [userId, remoteDocumentId],
    );
  }

  Future<void> clearForUser(String userId) {
    return _database().delete(table, where: 'user_id = ?', whereArgs: [userId]);
  }
}
