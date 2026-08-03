import 'dart:async';

import 'package:better_keep/services/remote_content_apply_coordinator.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Database database;
  late RemoteContentRetryLedger ledger;
  late RemoteContentApplyCoordinator coordinator;
  final now = DateTime.utc(2026, 7, 30);
  late DateTime currentTime;

  setUp(() async {
    currentTime = now;
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await RemoteContentRetryLedger.createTable(database);
    ledger = RemoteContentRetryLedger(database: () => database, jitterRatio: 0);
    coordinator = RemoteContentApplyCoordinator(ledger, now: () => currentTime);
  });

  tearDown(() => database.close());

  Future<RemoteContentHandlingResult> automatic({
    String revision = 'revision-1',
    required RemoteContentAttempt attempt,
  }) {
    return coordinator.handleAutomatic(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: revision,
      resolveLocalId: (existing) async => existing?.localId ?? 42,
      attempt: attempt,
      onHandled: (_) async {},
    );
  }

  test('concurrent events perform and record one real attempt', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    var attempts = 0;
    Future<RemoteNoteApplyResult> attempt(int _) async {
      attempts++;
      if (!started.isCompleted) started.complete();
      await release.future;
      return const RemoteNoteApplyResult.retryable(
        RemoteNoteFailureCategory.attachment,
        'network-error',
      );
    }

    final results = [
      automatic(attempt: attempt),
      automatic(attempt: attempt),
      automatic(attempt: attempt),
    ];
    await started.future;
    expect(attempts, 1);
    release.complete();
    await Future.wait(results);

    final entry = await ledger.get('user-1', 'note-1');
    expect(entry?.attempts, 1);
    expect(entry?.nextRetryAt, now.add(const Duration(seconds: 1)));
  });

  test(
    'different revisions are serialized and receive fresh budgets',
    () async {
      final release = Completer<void>();
      final firstStarted = Completer<void>();
      final events = <String>[];
      final first = automatic(
        revision: 'revision-1',
        attempt: (_) async {
          events.add('first-start');
          firstStarted.complete();
          await release.future;
          events.add('first-end');
          return const RemoteNoteApplyResult.retryable(
            RemoteNoteFailureCategory.attachment,
            'network-error',
          );
        },
      );
      final second = automatic(
        revision: 'revision-2',
        attempt: (_) async {
          events.add('second');
          return const RemoteNoteApplyResult.retryable(
            RemoteNoteFailureCategory.attachment,
            'network-error',
          );
        },
      );

      await firstStarted.future;
      expect(events, ['first-start']);
      release.complete();
      await Future.wait([first, second]);

      expect(events, ['first-start', 'first-end', 'second']);
      final entry = await ledger.get('user-1', 'note-1');
      expect(entry?.revision, 'revision-2');
      expect(entry?.attempts, 1);
    },
  );

  test('rapid manual retries coalesce and schedule nothing', () async {
    await automatic(
      attempt: (_) async => const RemoteNoteApplyResult.permanent(
        RemoteNoteFailureCategory.invalidPayload,
        'invalid',
      ),
    );
    final release = Completer<void>();
    final started = Completer<void>();
    var attempts = 0;

    Future<RemoteContentHandlingResult> manual() {
      return coordinator.handleManual(
        userId: 'user-1',
        remoteDocumentId: 'note-1',
        revision: 'revision-1',
        resolveLocalId: (existing) async => existing!.localId,
        attempt: (_) async {
          attempts++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return const RemoteNoteApplyResult.retryable(
            RemoteNoteFailureCategory.attachment,
            'network-error',
          );
        },
        onHandled: (_) async {},
      );
    }

    final results = [manual(), manual()];
    await started.future;
    expect(attempts, 1);
    release.complete();
    await Future.wait(results);

    final entry = await ledger.get('user-1', 'note-1');
    expect(entry?.state, RemoteContentRetryState.exhausted);
    expect(entry?.nextRetryAt, isNull);
  });

  test('manual retry keeps an unavailable E2EE dependency deferred', () async {
    final handled = await coordinator.handleManual(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: 'revision-1',
      resolveLocalId: (_) async => 42,
      attempt: (_) async => const RemoteNoteApplyResult.deferred(
        RemoteNoteFailureCategory.decryption,
        'e2ee-not-ready',
      ),
      onHandled: (_) async {},
    );

    expect(handled.disposition, RemoteContentHandlingDisposition.deferred);
    expect(handled.ledgerEntry?.attempts, 0);
    expect(handled.ledgerEntry?.nextRetryAt, isNull);
  });

  test('exactly five real automatic attempts exhaust the revision', () async {
    var attempts = 0;

    for (var expectedAttempt = 1; expectedAttempt <= 5; expectedAttempt++) {
      final handled = await automatic(
        attempt: (_) async {
          attempts++;
          return const RemoteNoteApplyResult.retryable(
            RemoteNoteFailureCategory.attachment,
            'network-error',
          );
        },
      );
      expect(handled.ledgerEntry?.attempts, expectedAttempt);
      if (expectedAttempt < 5) {
        expect(handled.disposition, RemoteContentHandlingDisposition.waiting);
        currentTime = handled.ledgerEntry!.nextRetryAt!;
      } else {
        expect(handled.disposition, RemoteContentHandlingDisposition.exhausted);
      }
    }

    final sixthEvent = await automatic(
      attempt: (_) async {
        attempts++;
        return const RemoteNoteApplyResult.success();
      },
    );

    expect(attempts, 5);
    expect(sixthEvent.disposition, RemoteContentHandlingDisposition.exhausted);
    expect(sixthEvent.ledgerEntry?.attempts, 5);
  });

  test('permanent and deferred outcomes do not create retry loops', () async {
    var permanentAttempts = 0;
    final permanent = await automatic(
      revision: 'permanent-revision',
      attempt: (_) async {
        permanentAttempts++;
        return const RemoteNoteApplyResult.permanent(
          RemoteNoteFailureCategory.invalidPayload,
          'invalid-payload',
        );
      },
    );
    final repeatedPermanent = await automatic(
      revision: 'permanent-revision',
      attempt: (_) async {
        permanentAttempts++;
        return const RemoteNoteApplyResult.success();
      },
    );

    expect(permanentAttempts, 1);
    expect(permanent.ledgerEntry?.attempts, 1);
    expect(
      repeatedPermanent.disposition,
      RemoteContentHandlingDisposition.exhausted,
    );

    var deferredAttempts = 0;
    final deferred = await automatic(
      revision: 'deferred-revision',
      attempt: (_) async {
        deferredAttempts++;
        return const RemoteNoteApplyResult.deferred(
          RemoteNoteFailureCategory.decryption,
          'e2ee-not-ready',
        );
      },
    );
    final repeatedDeferred = await automatic(
      revision: 'deferred-revision',
      attempt: (_) async {
        deferredAttempts++;
        return const RemoteNoteApplyResult.success();
      },
    );

    expect(deferredAttempts, 1);
    expect(deferred.ledgerEntry?.attempts, 0);
    expect(
      repeatedDeferred.disposition,
      RemoteContentHandlingDisposition.deferred,
    );
  });

  test('ledger reservation survives coordinator recreation', () async {
    await automatic(
      attempt: (_) async => const RemoteNoteApplyResult.retryable(
        RemoteNoteFailureCategory.attachment,
        'network-error',
      ),
    );
    final recreated = RemoteContentApplyCoordinator(
      RemoteContentRetryLedger(database: () => database, jitterRatio: 0),
      now: () => now.add(const Duration(minutes: 1)),
    );
    int? reservationSeen;

    final handled = await recreated.handleAutomatic(
      userId: 'user-1',
      remoteDocumentId: 'note-1',
      revision: 'revision-2',
      resolveLocalId: (existing) async {
        reservationSeen = existing?.localId;
        return existing?.localId ?? 99;
      },
      attempt: (_) async => const RemoteNoteApplyResult.retryable(
        RemoteNoteFailureCategory.attachment,
        'network-error',
      ),
      onHandled: (_) async {},
    );

    expect(reservationSeen, 42);
    expect(handled.localId, 42);
    expect(handled.ledgerEntry?.attempts, 1);
  });

  test(
    'ledger persistence failure never returns checkpoint-safe handling',
    () async {
      var attemptInvoked = false;
      var callbackInvoked = false;

      await expectLater(
        coordinator.handleAutomatic(
          userId: 'user-1',
          remoteDocumentId: 'note-1',
          revision: 'revision-1',
          resolveLocalId: (_) async => 42,
          attempt: (_) async {
            attemptInvoked = true;
            await database.close();
            return const RemoteNoteApplyResult.retryable(
              RemoteNoteFailureCategory.attachment,
              'network-error',
            );
          },
          onHandled: (_) async => callbackInvoked = true,
        ),
        throwsA(anything),
      );

      expect(attemptInvoked, isTrue);
      expect(callbackInvoked, isFalse);
      // Re-open so tearDown can close a valid handle.
      database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await RemoteContentRetryLedger.createTable(database);
    },
  );
}
