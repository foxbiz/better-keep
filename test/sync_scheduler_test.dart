import 'dart:async';

import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';

import 'package:sqflite/sqflite.dart' show DatabaseException;

import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'connection drain waits for retired work but not another provider',
    (tester) async {
      final gates = {
        'dropbox:1': Completer<void>(),
        'drive:1': Completer<void>(),
      };
      final scheduler = SyncScheduler(
        isCurrent: () => true,
        sync: (adapter) => gates[adapter.connectionId]!.future,
      );
      addTearDown(scheduler.dispose);
      final drive = _Provider('drive:1');
      scheduler.setAdapters([_Provider('dropbox:1'), drive]);
      await tester.pump();
      scheduler.setAdapters([drive]);
      var drained = false, allDrained = false;
      final drain = scheduler
          .waitForIdle(connectionId: 'dropbox:1')
          .then((_) => drained = true);
      final all = scheduler.waitForIdle().then((_) => allDrained = true);
      await tester.pump();
      expect(drained, false);
      gates['dropbox:1']!.complete();
      await tester.pump();
      expect(drained, true);
      expect(allDrained, false);
      gates['drive:1']!.complete();
      await tester.pump();
      await Future.wait([drain, all]);
    },
  );

  testWidgets(
    'blocked-only manual work clears intent without enabling later edits',
    (tester) async {
      var uploads = 0, pendingIntent = false;
      SyncScheduler create() => SyncScheduler(
        automatic: false,
        isCurrent: () => true,
        blockedEntities: () => 1,
        notesRequiringUnlock: () => 1,
        pendingLocalChanges: () => true,
        hasRunnableUpload: () => false,
        loadPendingUpload: (_) async => pendingIntent,
        savePendingUpload: (_, value) async => pendingIntent = value,
        sync: (_) async {
          uploads++;
        },
      );
      final scheduler = create();
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      await scheduler.syncNow();
      expect(uploads, 1);
      expect(pendingIntent, false);
      expect(scheduler.progress['drive:1']!.notesRequiringUnlock, 1);
      expect(scheduler.progress['drive:1']!.lastSuccess, isNull);
      scheduler.localChanged();
      await tester.pump(const Duration(seconds: 3));
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      await tester.pump();
      expect(uploads, 1);
      final reopened = create();
      addTearDown(reopened.dispose);
      reopened.setAdapters([_Provider('drive:1')]);
      await tester.pump();
      expect(uploads, 1);
      await reopened.syncNow();
      expect(uploads, 2);
    },
  );

  testWidgets('no-progress continuation waits and reuses durable intent', (
    tester,
  ) async {
    var calls = 0;
    final writes = <bool>[];
    late SyncScheduler scheduler;
    scheduler = SyncScheduler(
      automatic: false,
      isCurrent: () => true,
      now: tester.binding.clock.now,
      pendingLocalChanges: () => calls < 3,
      hasRunnableUpload: () => calls < 3,
      savePendingUpload: (_, value) async {
        writes.add(value);
      },
      sync: (adapter) async {
        calls++;
        if (calls < 3) {
          scheduler.continueUpload(adapter.connectionId, madeProgress: false);
        }
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('drive:1')]);
    await scheduler.syncNow();
    expect(calls, 1);
    expect(writes, [true]);
    expect(scheduler.progress['drive:1']!.retryAt, isNotNull);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(calls, 2);
    expect(writes, [true]);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 3);
    expect(writes, [true, false]);
    expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
  });

  for (final cancellation in [
    const CloudOperationCancelled(),
    const SyncReplicaCancelled(),
  ]) {
    testWidgets(
      'cancelled Free restores preserve retry allowance: ${cancellation.runtimeType}',
      (tester) async {
        var restores = 0;
        final scheduler = SyncScheduler(
          automatic: false,
          isCurrent: () => true,
          now: tester.binding.clock.now,
          sync: (_) async => fail('Free restore must not upload'),
          restore: (_) async {
            restores++;
            if (restores <= 3) throw cancellation;
            if (restores == 4) {
              throw const SyncProviderFailure(
                SyncProviderFailureKind.unavailable,
              );
            }
          },
        );
        addTearDown(scheduler.dispose);
        scheduler.setAdapters([_Provider('drive:1')]);
        await tester.pump();
        for (var i = 1; i <= 3; i++) {
          expect(restores, i);
          expect(scheduler.progress['drive:1']!.failure, isNull);
          expect(scheduler.progress['drive:1']!.retryAt, isNull);
          scheduler.setForeground(false);
          scheduler.setForeground(true);
          await tester.pump();
        }
        expect(restores, 4);
        expect(scheduler.progress['drive:1']!.retryAt, isNotNull);
        await tester.pump(const Duration(seconds: 5));
        expect(restores, 5);
        expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
      },
    );
  }

  for (final cancellation in [
    const CloudOperationCancelled(),
    const SyncReplicaCancelled(),
  ]) {
    testWidgets(
      'neutral ${cancellation.runtimeType} retains intent without retry spin',
      (tester) async {
        var calls = 0, pending = false, successes = 0;
        late SyncScheduler scheduler;
        scheduler = SyncScheduler(
          automatic: false,
          isCurrent: () => true,
          now: tester.binding.clock.now,
          pendingLocalChanges: () => pending,
          savePendingUpload: (_, value) async => pending = value,
          saveLastSuccess: (_, _) async => successes++,
          sync: (adapter) async {
            if (++calls == 1) {
              scheduler.continueUpload(adapter.connectionId);
              throw cancellation;
            }
            pending = false;
          },
        );
        addTearDown(scheduler.dispose);
        scheduler.setAdapters([_Provider('drive:1')]);
        await scheduler.syncNow();
        expect(calls, 1);
        expect(pending, isTrue);
        expect(successes, 0);
        final progress = scheduler.progress['drive:1']!;
        expect(progress.running, isFalse);
        expect(progress.failure, isNull);
        expect(progress.retryAt, isNull);
        expect(progress.lastSuccess, isNull);
        expect(progress.pendingLocalChanges, isTrue);
        await tester.pump(const Duration(minutes: 10));
        expect(calls, 1);
        scheduler.setForeground(false);
        scheduler.setForeground(true);
        await tester.pump();
        await scheduler.waitForIdle();
        expect(calls, 2);
        expect(pending, isFalse);
        expect(successes, 1);
      },
    );
  }

  testWidgets('manual retry queued during cancellation still runs', (
    tester,
  ) async {
    final release = Completer<void>();
    var calls = 0;
    final scheduler = SyncScheduler(
      automatic: false,
      isCurrent: () => true,
      sync: (_) async {
        if (++calls == 1) {
          await release.future;
          throw const CloudOperationCancelled();
        }
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('drive:1')]);
    final first = scheduler.syncNow();
    await tester.pump();
    final retry = scheduler.syncNow();
    release.complete();
    await Future.wait([first, retry]);
    expect(calls, 2);
    expect(scheduler.progress['drive:1']!.failure, isNull);
    expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
  });

  testWidgets(
    'restart resumes only the connection with unfinished upload intent',
    (tester) async {
      final intents = <String>{'drive:1'};
      final uploads = <String>[];
      final restores = <String>[];
      final scheduler = SyncScheduler(
        automatic: false,
        isCurrent: () => true,
        loadPendingUpload: (id) async => intents.contains(id),
        savePendingUpload: (id, pending) async {
          if (pending) {
            intents.add(id);
          } else {
            intents.remove(id);
          }
        },
        restore: (adapter) async {
          restores.add(adapter.connectionId);
        },
        sync: (adapter) async {
          expectSync(intents, contains(adapter.connectionId));
          uploads.add(adapter.connectionId);
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('dropbox:1'), _Provider('drive:1')]);
      await tester.pump();
      await scheduler.waitForIdle();
      expect(uploads, ['drive:1']);
      expect(restores, ['dropbox:1']);
      expect(intents, isEmpty);
      scheduler.localChanged();
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      await tester.pump(const Duration(minutes: 1));
      expect(uploads, ['drive:1']);
    },
  );

  testWidgets(
    'sleep during manual upload retains intent and retries on unlock',
    (tester) async {
      final release = Completer<void>();
      var uploads = 0, pendingIntent = false;
      final scheduler = SyncScheduler(
        automatic: false,
        now: tester.binding.clock.now,
        isCurrent: () => true,
        loadPendingUpload: (_) async => pendingIntent,
        savePendingUpload: (_, pending) async {
          pendingIntent = pending;
        },
        sync: (_) async {
          expectSync(pendingIntent, isTrue);
          if (++uploads == 1) {
            await release.future;
            throw const SyncProviderFailure(
              SyncProviderFailureKind.unavailable,
            );
          }
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      final manual = scheduler.syncNow();
      await tester.pump();
      expect(uploads, 1);
      scheduler.setForeground(false);
      release.complete();
      await tester.pump();
      await manual;
      expect(pendingIntent, isTrue);
      expect(scheduler.progress['drive:1']!.lastSuccess, isNull);
      await tester.pump(const Duration(minutes: 1));
      expect(uploads, 1);
      scheduler.setForeground(true);
      await tester.pump();
      await scheduler.waitForIdle();
      expect(uploads, 2);
      expect(pendingIntent, isFalse);
      expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
    },
  );

  testWidgets(
    'intent persistence failure prevents uploading and remains retryable',
    (tester) async {
      var writes = 0, uploads = 0;
      final scheduler = SyncScheduler(
        automatic: false,
        now: tester.binding.clock.now,
        isCurrent: () => true,
        loadPendingUpload: (_) async => false,
        savePendingUpload: (_, pending) async {
          if (++writes == 1) {
            throw StateError('Storage temporarily unavailable');
          }
        },
        sync: (_) async {
          uploads++;
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive:1')]);
      final requested = scheduler.syncNow();
      await tester.pump();
      await requested;
      expect(uploads, 0);
      expect(scheduler.progress['drive:1']!.lastSuccess, isNull);
      await tester.pump(const Duration(seconds: 5));
      expect(uploads, 1);
      expect(scheduler.progress['drive:1']!.failure, isNull);
    },
  );

  for (final operation in [
    'load history',
    'load intent',
    'save intent',
    'clear intent',
    'save history',
  ]) {
    testWidgets(
      'local $operation failure is retryable without an offline diagnosis',
      (tester) async {
        var failed = false;
        void check(String step) {
          if (step == operation && !failed) {
            failed = true;
            throw StateError('synthetic local storage failure');
          }
        }

        final scheduler = SyncScheduler(
          isCurrent: () => true,
          now: tester.binding.clock.now,
          loadLastSuccess: (_) async {
            check('load history');
            return null;
          },
          loadPendingUpload: (_) async {
            check('load intent');
            return false;
          },
          savePendingUpload: (_, pending) async {
            check(pending ? 'save intent' : 'clear intent');
          },
          saveLastSuccess: (_, _) async {
            check('save history');
          },
          sync: (_) async {},
        );
        addTearDown(scheduler.dispose);
        scheduler.setAdapters([_Provider('drive:1')]);
        await tester.pump();
        expect(
          scheduler.progress['drive:1']!.failure,
          SyncProviderFailureKind.localStorage,
        );
        expect(scheduler.progress['drive:1']!.retryAt, isNotNull);
        await tester.pump(const Duration(seconds: 5));
        expect(scheduler.progress['drive:1']!.failure, isNull);
        expect(scheduler.progress['drive:1']!.lastSuccess, isNotNull);
      },
    );
  }

  for (final automatic in [false, true]) {
    testWidgets(
      'SQLite failure inside ${automatic ? 'sync' : 'restore'} is not offline',
      (tester) async {
        var calls = 0;
        Future<void> run(SyncProviderAdapter _) async {
          if (++calls == 1) throw _DatabaseFailure();
        }

        final scheduler = SyncScheduler(
          automatic: automatic,
          isCurrent: () => true,
          now: tester.binding.clock.now,
          sync: run,
          restore: run,
        );
        addTearDown(scheduler.dispose);
        scheduler.setAdapters([_Provider('drive:1')]);
        await tester.pump();
        expect(
          scheduler.progress['drive:1']!.failure,
          SyncProviderFailureKind.localStorage,
        );
        await tester.pump(const Duration(seconds: 5));
        expect(calls, 2);
        expect(scheduler.progress['drive:1']!.failure, isNull);
      },
    );
  }

  testWidgets('manual sync before restore starts is not lost', (tester) async {
    var restores = 0, uploads = 0;
    final scheduler = SyncScheduler(
      automatic: false,
      isCurrent: () => true,
      restore: (_) async {
        restores++;
      },
      sync: (_) async {
        uploads++;
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('dropbox:1')]);
    await scheduler.syncNow();
    expect(uploads, 1);
    expect(restores, 0);
  });

  testWidgets(
    'free restore bounds retries per foreground visit and permits manual retry',
    (tester) async {
      var restores = 0, uploads = 0;
      final scheduler = SyncScheduler(
        automatic: false,
        isCurrent: () => true,
        now: tester.binding.clock.now,
        restore: (_) async {
          restores++;
          throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
        },
        sync: (_) async {
          uploads++;
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('dropbox:1')]);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 10));
      expect(restores, 3);
      expect(scheduler.progress['dropbox:1']!.retryAt, isNull);
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      scheduler.remoteChanged('dropbox:1');
      await tester.pump(const Duration(hours: 1));
      expect(restores, 6);
      await tester.pump(const Duration(hours: 1));
      expect(restores, 6);
      await scheduler.syncNow();
      expect(uploads, 1);
      expect(scheduler.progress['dropbox:1']!.failure, isNull);
    },
  );

  testWidgets('free restores once and manual sync joins an in-flight restore', (
    tester,
  ) async {
    final release = Completer<void>();
    var restores = 0, syncs = 0;
    final provider = _Provider('dropbox:1');
    final scheduler = SyncScheduler(
      automatic: false,
      isCurrent: () => true,
      now: tester.binding.clock.now,
      restore: (_) async {
        restores++;
        await release.future;
      },
      sync: (_) async {
        syncs++;
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([provider]);
    await tester.pump();
    expect(restores, 1);
    expect(syncs, 0);
    final manual = scheduler.syncNow();
    release.complete();
    await tester.pump();
    await manual;
    expect(syncs, 1);
    expect(scheduler.progress[provider.connectionId]!.lastSuccess, isNotNull);
    scheduler.setAdapters([provider]);
    scheduler.localChanged();
    scheduler.remoteChanged(provider.connectionId);
    scheduler.setForeground(false);
    scheduler.setForeground(true);
    await tester.pump(const Duration(hours: 1));
    expect(restores, 1);
    expect(syncs, 1);
  });

  testWidgets('queued manual pass never announces completion between passes', (
    tester,
  ) async {
    final first = Completer<void>();
    final second = Completer<void>();
    var calls = 0;
    final scheduler = SyncScheduler(
      automatic: false,
      isCurrent: () => true,
      sync: (_) => ++calls == 1 ? first.future : second.future,
    );
    addTearDown(scheduler.dispose);
    final samples = <SyncConnectionProgress>[];
    scheduler.setAdapters([_Provider('drive')]);
    scheduler.addListener(() => samples.add(scheduler.progress['drive']!));
    final initial = scheduler.syncNow();
    await tester.pump();
    final queued = scheduler.syncNow();
    first.complete();
    await tester.pump();
    expect(calls, 2);
    expect(samples.every((s) => s.running), true);
    second.complete();
    await tester.pump();
    await Future.wait([initial, queued]);
    expect(samples.last.running, false);
    expect(samples.last.lastSuccess, isNotNull);
  });

  for (final stop in ['background', 'manual']) {
    testWidgets('queued pass settles when a listener switches to $stop', (
      tester,
    ) async {
      final release = Completer<void>();
      var runs = 0, starts = 0;
      final scheduler = SyncScheduler(
        isCurrent: () => true,
        onPassStarted: (_) => starts++,
        sync: (_) async {
          runs++;
          await release.future;
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('drive')]);
      await tester.pump();
      scheduler.remoteChanged('drive');
      var stopped = false;
      scheduler.addListener(() {
        final state = scheduler.progress['drive']!;
        if (!stopped && state.running && state.lastSuccess != null) {
          stopped = true;
          if (stop == 'background') {
            scheduler.setForeground(false);
          } else {
            scheduler.setAutomatic(false);
          }
        }
      });
      release.complete();
      await tester.pump();
      await scheduler.waitForIdle();
      expect(runs, 1);
      expect(starts, 1);
      expect(scheduler.progress['drive']!.running, false);
      expect(scheduler.progress['drive']!.lastSuccess, isNotNull);
      if (stop == 'background') {
        scheduler.setForeground(true);
      } else {
        scheduler.setAutomatic(true);
      }
      await tester.pump();
      await scheduler.waitForIdle();
      expect(runs, 2);
      expect(starts, 2);
      expect(scheduler.progress['drive']!.running, false);
    });
  }

  for (final automatic in [false, true]) {
    for (final cancellation in [
      const SyncReplicaCancelled(),
      const CloudOperationCancelled(),
    ]) {
      testWidgets(
        'foreground wake survives late ${cancellation.runtimeType} (automatic=$automatic)',
        (tester) async {
          final release = Completer<void>();
          var calls = 0;
          Future<void> run(SyncProviderAdapter _) async {
            if (++calls == 1) {
              await release.future;
              throw cancellation;
            }
          }

          final scheduler = SyncScheduler(
            automatic: automatic,
            isCurrent: () => true,
            sync: automatic
                ? run
                : (_) async => fail('A Free restore must not upload'),
            restore: run,
          );
          addTearDown(scheduler.dispose);
          scheduler.setAdapters([_Provider('dropbox:1')]);
          await tester.pump();
          expect(calls, 1);
          scheduler.setForeground(false);
          scheduler.setForeground(true);
          // The old pass only reports cancellation after the foreground event.
          release.complete();
          await tester.pump();
          await scheduler.waitForIdle();
          expect(calls, 2);
          expect(scheduler.progress['dropbox:1']!.failure, isNull);
          expect(scheduler.progress['dropbox:1']!.lastSuccess, isNotNull);
        },
      );
    }
  }

  testWidgets(
    'foreground retries an unfinished Free restore after its transient allowance is exhausted',
    (tester) async {
      var restores = 0;
      final scheduler = SyncScheduler(
        automatic: false,
        now: tester.binding.clock.now,
        isCurrent: () => true,
        sync: (_) async => fail('Restoration must not enable uploads'),
        restore: (_) async {
          if (++restores <= 3) {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.unavailable,
            );
          }
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('dropbox:1')]);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 10));
      expect(restores, 3);
      await tester.pump(const Duration(hours: 1));
      expect(restores, 3, reason: 'No unbounded retry loop');
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      await tester.pump();
      expect(restores, 4);
      expect(scheduler.progress['dropbox:1']!.lastSuccess, isNotNull);
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      scheduler.localChanged();
      await tester.pump(const Duration(hours: 1));
      expect(restores, 4, reason: 'A completed Free restore stays complete');
    },
  );

  testWidgets('free retries a failed initial download after resume', (
    tester,
  ) async {
    var restores = 0;
    final scheduler = SyncScheduler(
      automatic: false,
      foreground: false,
      isCurrent: () => true,
      now: tester.binding.clock.now,
      restore: (_) async {
        if (++restores == 1) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
        }
      },
      sync: (_) async => fail('Restoring must not upload'),
    );
    addTearDown(scheduler.dispose);
    scheduler.setAdapters([_Provider('dropbox:1')]);
    await tester.pump();
    expect(restores, 0);
    scheduler.setForeground(true);
    await tester.pump();
    expect(restores, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(restores, 2);
    expect(scheduler.progress['dropbox:1']!.failure, isNull);
    await tester.pump(const Duration(hours: 1));
    expect(restores, 2);
  });

  testWidgets(
    'downgrade finishes an interrupted upload without enabling later edits',
    (tester) async {
      var restores = 0, uploads = 0;
      final scheduler = SyncScheduler(
        isCurrent: () => true,
        now: tester.binding.clock.now,
        sync: (_) async {
          if (++uploads == 1) {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.unavailable,
            );
          }
        },
        restore: (_) async {
          restores++;
        },
      );
      addTearDown(scheduler.dispose);
      scheduler.setAdapters([_Provider('dropbox:1')]);
      await tester.pump();
      scheduler.setAutomatic(false);
      await tester.pump(const Duration(seconds: 5));
      expect(uploads, 2);
      expect(restores, 0);
      expect(scheduler.progress['dropbox:1']!.failure, isNull);
      scheduler.localChanged();
      scheduler.setForeground(false);
      scheduler.setForeground(true);
      await tester.pump(const Duration(hours: 1));
      expect(uploads, 2);
    },
  );

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

  for (final failure in [
    SyncProviderFailureKind.unsupported,
    SyncProviderFailureKind.reconnectRequired,
  ]) {
    testWidgets(
      'permanent $failure stops automatic work until explicit retry',
      (tester) async {
        var calls = 0;
        final scheduler = SyncScheduler(
          isCurrent: () => true,
          now: tester.binding.clock.now,
          saveDebounce: Duration.zero,
          sync: (_) async {
            if (++calls == 1) throw SyncProviderFailure(failure);
          },
        );
        addTearDown(scheduler.dispose);
        scheduler.setAdapters([_Provider('dropbox:1')]);
        await tester.pump();
        expect(scheduler.progress['dropbox:1']!.failure, failure);
        expect(scheduler.progress['dropbox:1']!.retryAt, isNull);
        scheduler.localChanged();
        scheduler.remoteChanged('dropbox:1');
        scheduler.setForeground(false);
        scheduler.setForeground(true);
        scheduler.setAutomatic(false);
        scheduler.setAutomatic(true);
        await tester.pump(const Duration(hours: 1));
        expect(calls, 1);
        await scheduler.syncNow();
        expect(calls, 2);
        expect(scheduler.progress['dropbox:1']!.failure, isNull);
      },
    );
  }

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

class _DatabaseFailure implements DatabaseException {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
