import 'dart:async';

import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'free keeps manual sync but ignores automatic triggers and downgrade stops retries',
    (tester) async {
      var calls = 0;
      final scheduler = SyncScheduler(
        automatic: false,
        isCurrent: () => true,
        sync: (_) async {
          calls++;
        },
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      scheduler.localChanged();
      scheduler.remoteChanged('drive:1');
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      await tester.pump(const Duration(hours: 1));
      expect(calls, 0);
      await scheduler.syncNow();
      expect(calls, 1);
      scheduler.setAutomatic(true);
      await tester.pump();
      expect(calls, 2);
      scheduler.localChanged();
      scheduler.setAutomatic(false);
      await tester.pump(const Duration(minutes: 2));
      expect(calls, 2);
      await scheduler.syncNow();
      expect(calls, 3);
      scheduler.dispose();
    },
  );

  testWidgets('full storage stays paused until an explicit retry succeeds', (
    tester,
  ) async {
    var calls = 0;
    final scheduler = SyncScheduler(
      sync: (_) async {
        if (++calls == 1) {
          throw const SyncProviderFailure(
            SyncProviderFailureKind.quotaExceeded,
          );
        }
      },
      isCurrent: () => true,
      now: tester.binding.clock.now,
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('drive:1')]);
    await tester.pump();
    expect(
      scheduler.progress['drive:1']!.failure,
      SyncProviderFailureKind.quotaExceeded,
    );
    expect(scheduler.progress['drive:1']!.retryAt, isNull);
    scheduler.localChanged();
    await tester.pump(const Duration(minutes: 10));
    expect(calls, 1);
    await scheduler.syncNow();
    expect(calls, 2);
    expect(scheduler.progress['drive:1']!.failure, isNull);
    scheduler.dispose();
  });

  testWidgets(
    'corrupt data pauses automatic retries and permits explicit retry',
    (tester) async {
      var calls = 0;
      final scheduler = SyncScheduler(
        sync: (_) async {
          calls++;
          if (calls == 1) {
            throw const FormatException('Malformed provider record');
          }
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(
        scheduler.progress['drive:1']!.failure,
        SyncProviderFailureKind.corruptData,
      );
      expect(scheduler.progress['drive:1']!.retryAt, isNull);
      scheduler.localChanged();
      await tester.pump(const Duration(minutes: 10));
      expect(calls, 1);
      await scheduler.syncNow();
      expect(calls, 2);
      expect(scheduler.progress['drive:1']!.failure, isNull);
      scheduler.dispose();
    },
  );

  testWidgets(
    'authorization waits for consent instead of retrying until adapter replacement',
    (tester) async {
      var calls = 0;
      var authorized = false;
      final scheduler = SyncScheduler(
        sync: (_) async {
          calls++;
          if (!authorized) {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.sharedSetupRequired,
            );
          }
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(calls, 1);
      expect(scheduler.progress['drive:1']!.retryAt, isNull);
      scheduler.localChanged();
      await tester.pump(const Duration(minutes: 6));
      await scheduler.syncNow();
      expect(calls, 1);
      authorized = true;
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(calls, 2);
      expect(scheduler.progress['drive:1']!.failure, isNull);
      scheduler.dispose();
    },
  );
  testWidgets(
    'saved history is restored and failed status writes retain the previous success with backoff',
    (tester) async {
      final previous = tester.binding.clock.now().subtract(
        const Duration(days: 1),
      );
      var fail = true;
      final scheduler = SyncScheduler(
        sync: (_) async {},
        isCurrent: () => true,
        now: tester.binding.clock.now,
        loadLastSuccess: (_) async => previous,
        saveLastSuccess: (_, _) async {
          if (fail) throw StateError('Synthetic disk failure');
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(scheduler.progress['drive:1']!.lastSuccess, previous);
      expect(
        scheduler.progress['drive:1']!.retryAt,
        tester.binding.clock.now().add(const Duration(seconds: 5)),
      );
      var retry = scheduler.syncNow();
      await tester.pump();
      await retry;
      expect(
        scheduler.progress['drive:1']!.retryAt,
        tester.binding.clock.now().add(const Duration(seconds: 10)),
      );
      fail = false;
      retry = scheduler.syncNow();
      await tester.pump();
      await retry;
      expect(scheduler.progress['drive:1']!.failure, isNull);
      expect(
        scheduler.progress['drive:1']!.lastSuccess,
        tester.binding.clock.now(),
      );
      scheduler.dispose();
    },
  );

  testWidgets(
    'launch, save debounce, remote notification and resume reconcile',
    (tester) async {
      var calls = 0;
      final scheduler = SyncScheduler(
        sync: (_) async {
          calls++;
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(calls, 1);
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 1));
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      await tester.pump(const Duration(hours: 1));
      expect(calls, 2);
      scheduler.remoteChanged('drive:1');
      await tester.pump();
      expect(calls, 3);
      scheduler.localChanged();
      scheduler.setForeground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(calls, 3);
      scheduler.setForeground(true);
      await tester.pump();
      expect(calls, 4);
      scheduler.dispose();
    },
  );

  testWidgets(
    'provider rate limits do not delay other providers and explicit retry bypasses backoff',
    (tester) async {
      final calls = <String, int>{};
      final scheduler = SyncScheduler(
        sync: (provider) async {
          calls.update(
            provider.connectionId,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (provider.connectionId == 'drive:1') {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.rateLimited,
              retryAfter: Duration(minutes: 2),
            );
          }
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1'), _Provider('dropbox:1')]);
      await tester.pump();
      expect(
        scheduler.progress['drive:1']!.failure,
        SyncProviderFailureKind.rateLimited,
      );
      expect(scheduler.progress['dropbox:1']!.lastSuccess, isNotNull);
      await tester.pump(const Duration(seconds: 30));
      expect(calls, {'drive:1': 1, 'dropbox:1': 1});
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, {'drive:1': 1, 'dropbox:1': 2});
      final retry = scheduler.syncNow(connectionId: 'drive:1');
      await tester.pump();
      await retry;
      expect(calls, {'drive:1': 2, 'dropbox:1': 2});
      scheduler.dispose();
    },
  );

  testWidgets(
    'changes during an upload run once more without overlapping passes',
    (tester) async {
      final release = Completer<void>();
      var calls = 0, concurrent = 0, maxConcurrent = 0;
      final scheduler = SyncScheduler(
        sync: (_) async {
          calls++;
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          if (calls == 1) await release.future;
          concurrent--;
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 2));
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 1);
      release.complete();
      await tester.pump();
      expect(calls, 2);
      expect(maxConcurrent, 1);
      expect(scheduler.progress['drive:1']!.running, isFalse);
      scheduler.dispose();
    },
  );

  testWidgets(
    'same-ID replacement waits for retired pass and ignores its outcome',
    (tester) async {
      final old = _Provider('drive:1'), replacement = _Provider('drive:1');
      final release = Completer<void>();
      final calls = <SyncProviderAdapter>[];
      final scheduler = SyncScheduler(
        sync: (adapter) async {
          calls.add(adapter);
          if (identical(adapter, old)) {
            await release.future;
            throw const SyncProviderFailure(
              SyncProviderFailureKind.reconnectRequired,
            );
          }
        },
        isCurrent: () => true,
        now: tester.binding.clock.now,
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([old]);
      await tester.pump();
      scheduler.setAdapters([replacement]);
      await tester.pump();
      expect(calls, [old]);
      release.complete();
      await tester.pump();
      expect(calls, [old, replacement]);
      expect(scheduler.progress['drive:1']!.failure, isNull);
      expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
      scheduler.dispose();
    },
  );

  testWidgets('partial local capture never claims a complete successful sync', (
    tester,
  ) async {
    var blocked = 1, pending = true;
    final scheduler = SyncScheduler(
      sync: (_) async {},
      isCurrent: () => true,
      now: tester.binding.clock.now,
      blockedEntities: () => blocked,
      notesRequiringUnlock: () => blocked,
      pendingLocalChanges: () => pending,
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('drive:1')]);
    await tester.pump();
    expect(scheduler.progress['drive:1']!.lastSuccess, isNull);
    expect(scheduler.progress['drive:1']!.blockedEntities, 1);
    expect(scheduler.progress['drive:1']!.notesRequiringUnlock, 1);
    scheduler.localChanged();
    expect(scheduler.progress['drive:1']!.notesRequiringUnlock, 1);
    blocked = 0;
    var retry = scheduler.syncNow();
    await tester.pump();
    await retry;
    expect(scheduler.progress['drive:1']!.lastSuccess, isNull);
    expect(scheduler.progress['drive:1']!.pendingLocalChanges, isTrue);
    pending = false;
    retry = scheduler.syncNow();
    await tester.pump();
    await retry;
    expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
    expect(scheduler.progress['drive:1']!.blockedEntities, 0);
    expect(scheduler.progress['drive:1']!.notesRequiringUnlock, 0);
    scheduler.dispose();
  });

  testWidgets('retirement stops timers and draining waits for active work', (
    tester,
  ) async {
    var current = true, calls = 0, drained = false;
    final release = Completer<void>();
    final scheduler = SyncScheduler(
      sync: (_) async {
        calls++;
        await release.future;
      },
      isCurrent: () => current,
      now: tester.binding.clock.now,
    );
    scheduler.setAdapters([_Provider('drive:1')]);
    await tester.pump();
    current = false;
    scheduler.dispose();
    final drain = scheduler.waitForIdle().then((_) => drained = true);
    await tester.pump(const Duration(minutes: 2));
    expect(drained, isFalse);
    release.complete();
    await tester.pump();
    await drain;
    expect(drained, isTrue);
    expect(calls, 1);
    expect(scheduler.progress, isEmpty);
  });
}

class _Provider implements SyncProviderAdapter {
  _Provider(this.connectionId);
  @override
  final String connectionId;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
