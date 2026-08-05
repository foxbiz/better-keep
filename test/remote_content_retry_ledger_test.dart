import 'dart:async';

import 'package:better_keep/services/async_operation_coalescer.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database database;
  late RemoteContentRetryLedger ledger;
  final start = DateTime.utc(2026, 7, 29);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await RemoteContentRetryLedger.createTable(database);
    ledger = RemoteContentRetryLedger(database: () => database, jitterRatio: 0);
  });

  tearDown(() => database.close());

  Future<RemoteContentRetryEntry> fail({
    String revision = 'revision-1',
    bool permanent = false,
    DateTime? now,
  }) {
    return ledger.recordAutomaticFailure(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: revision,
      localId: 42,
      category: RemoteNoteFailureCategory.attachment,
      errorCode: 'unknown',
      permanent: permanent,
      now: now ?? start,
    );
  }

  test('five total attempts exhaust and a sixth record is ignored', () async {
    RemoteContentRetryEntry? entry;
    for (var attempt = 1; attempt <= 5; attempt++) {
      entry = await fail(now: start.add(Duration(seconds: attempt)));
      expect(entry.attempts, attempt);
      expect(
        entry.state,
        attempt == 5
            ? RemoteContentRetryState.exhausted
            : RemoteContentRetryState.waiting,
      );
    }

    final sixth = await fail(now: start.add(const Duration(minutes: 1)));
    expect(sixth.attempts, 5);
    expect(sixth.nextRetryAt, isNull);
  });

  test('retry delays are persisted as 1, 2, 4, and 8 seconds', () async {
    for (final expected in [1, 2, 4, 8]) {
      final entry = await fail(now: start);
      expect(entry.nextRetryAt!.difference(start), Duration(seconds: expected));
    }
  });

  test('attempts survive a new ledger instance', () async {
    await fail();
    final restored = RemoteContentRetryLedger(
      database: () => database,
      jitterRatio: 0,
    );
    final second = await restored.recordAutomaticFailure(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: 'revision-1',
      localId: 42,
      category: RemoteNoteFailureCategory.attachment,
      errorCode: 'unknown',
      permanent: false,
      now: start,
    );
    expect(second.attempts, 2);
  });

  test('database version 10 upgrade creates the durable ledger', () async {
    await database.execute('DROP TABLE ${RemoteContentRetryLedger.table}');
    await RemoteContentRetryLedger.upgradeTable(database, 9, 10);
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [RemoteContentRetryLedger.table],
    );
    expect(tables, hasLength(1));
  });

  test('permanent failure exhausts after one attempt', () async {
    final entry = await fail(permanent: true);
    expect(entry.attempts, 1);
    expect(entry.state, RemoteContentRetryState.exhausted);
    expect(entry.nextRetryAt, isNull);
  });

  test('deferred dependency consumes no attempts', () async {
    final entry = await ledger.recordDeferred(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: 'revision-1',
      localId: 42,
      category: RemoteNoteFailureCategory.decryption,
      errorCode: 'umk-unavailable',
      now: start,
    );
    expect(entry.attempts, 0);
    expect(entry.state, RemoteContentRetryState.deferred);
    expect(entry.nextRetryAt, isNull);
  });

  test(
    'dependency readiness preserves the ledger and schedules immediately',
    () async {
      final deferred = await ledger.recordDeferred(
        userId: 'user',
        remoteDocumentId: 'remote',
        revision: 'revision',
        localId: 41,
        category: RemoteNoteFailureCategory.decryption,
        errorCode: 'e2ee-not-ready',
        now: start,
      );
      final readyAt = start.add(const Duration(minutes: 1));

      final activated = await ledger.activateDeferred(
        userId: deferred.userId,
        remoteDocumentId: deferred.remoteDocumentId,
        now: readyAt,
      );

      expect(activated?.state, RemoteContentRetryState.waiting);
      expect(activated?.attempts, 0);
      expect(activated?.nextRetryAt, readyAt);
      expect(
        await ledger.get(deferred.userId, deferred.remoteDocumentId),
        isNotNull,
      );
    },
  );

  test('a new remote revision receives a fresh budget', () async {
    for (var i = 0; i < 5; i++) {
      await fail();
    }
    final fresh = await fail(revision: 'revision-2');
    expect(fresh.attempts, 1);
    expect(fresh.state, RemoteContentRetryState.waiting);
  });

  test('manual failure remains exhausted and schedules nothing', () async {
    await fail();
    final entry = await ledger.recordManualFailure(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: 'revision-1',
      localId: 42,
      category: RemoteNoteFailureCategory.attachment,
      errorCode: 'manual-failure',
      now: start,
    );
    expect(entry.attempts, 5);
    expect(entry.state, RemoteContentRetryState.exhausted);
    expect(entry.nextRetryAt, isNull);
  });

  test(
    'concurrent work for one revision coalesces into one operation',
    () async {
      final coalescer =
          AsyncOperationCoalescer<String, RemoteNoteApplyResult>();
      final completer = Completer<RemoteNoteApplyResult>();
      var operations = 0;

      Future<RemoteNoteApplyResult> run() {
        return coalescer.run('note-1:revision-1', () {
          operations++;
          return completer.future;
        });
      }

      final results = [run(), run(), run()];
      expect(operations, 1);
      completer.complete(const RemoteNoteApplyResult.success());
      await Future.wait(results);
      expect(coalescer.inFlightCount, 0);
    },
  );
}
