import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/note_sync_batch.dart';

import 'dart:async';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'notification initialization retries after a platform failure',
    () async {
      var attempts = 0;
      final service = LocalNotificationService.forTesting(
        initialize: () async {
          attempts++;
          if (attempts == 1) throw StateError('notification icon unavailable');
        },
      );

      Future<void> initialize() => service.init(
        onResponse: (_) {},
        onBackgroundResponse: _backgroundResponse,
      );

      await expectLater(initialize(), throwsStateError);
      await initialize();

      expect(attempts, 2);
    },
  );

  test('reminder initialization failure becomes a delivery failure', () async {
    final coordinator = ReminderCoordinator.forTesting(
      initialize: () async => throw StateError('notifications unavailable'),
    );
    final note = Note(
      id: 42,
      reminder: Reminder(dateTime: DateTime(2026, 8, 13, 10)),
    );

    final result = await coordinator.schedule(note);

    expect(result.state, ReminderDeliveryState.failed);
    expect(result.error, isA<StateError>());
  });

  test('remote reminder reconciliation requests are coalesced', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var passes = 0;
    final coordinator = ReminderCoordinator.forTesting(
      reconcile: () async {
        passes++;
        if (passes == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
      },
    );

    coordinator.requestReconciliation();
    await firstStarted.future;
    coordinator.requestReconciliation();
    coordinator.requestReconciliation();
    coordinator.requestReconciliation();
    releaseFirst.complete();
    await coordinator.waitForRequestedReconciliation();

    expect(passes, 2);
  });

  test('interrupted bulk restore releases one pending reminder scan', () async {
    var scans = 0;
    final coordinator = ReminderCoordinator.forTesting(
      reconcile: () async {
        scans++;
      },
    );
    await expectLater(
      NoteSyncBatch().run(100, (meter) async {
        for (var i = 0; i < 50; i++) {
          coordinator.requestReconciliation();
          meter.advance();
          await Future<void>.microtask(() {});
        }
        expect(scans, 0);
        throw StateError('interrupted');
      }, isEmptyLibrary: () async => true),
      throwsStateError,
    );
    await coordinator.waitForRequestedReconciliation();
    expect(scans, 1);
    expect(NoteSyncBatch.active.value, false);
    expect(NoteSyncBatch.progress.value, isNull);
  });

  testWidgets(
    'only empty-library restores block, and retired runs cannot release a newer one',
    (tester) async {
      final oldSession = NoteSyncBatch();
      final currentSession = NoteSyncBatch();
      for (final stage in [
        NoteTransferStage.uploading,
        NoteTransferStage.downloading,
      ]) {
        await oldSession.run(
          20,
          (_) async {
            expect(NoteSyncBatch.active.value, isFalse);
          },
          stage: stage,
          isEmptyLibrary: () async => false,
        );
      }
      for (final failure in [
        Exception('unavailable'),
        StateError('database closed'),
      ]) {
        var processed = false;
        await oldSession.run(20, (_) async {
          processed = true;
          expect(NoteSyncBatch.active.value, isFalse);
        }, isEmptyLibrary: () async => throw failure);
        expect(processed, isTrue);
      }
      final oldDone = Completer<void>();
      final newDone = Completer<void>();
      final old = oldSession.run(
        30,
        (_) => oldDone.future,
        isEmptyLibrary: () async => true,
      );
      await tester.pump();
      final waiting = NoteSyncBatch.pending!;
      final current = currentSession.run(
        50,
        (_) => newDone.future,
        isEmptyLibrary: () async => true,
      );
      await tester.pump();
      expect(NoteSyncBatch.progress.value?.total, 30);
      oldSession.reset();
      expect(NoteSyncBatch.progress.value?.total, 50);
      oldDone.complete();
      await old;
      expect(NoteSyncBatch.active.value, isTrue);
      await tester.pump(const Duration(minutes: 2));
      await waiting;
      expect(NoteSyncBatch.active.value, isFalse);
      newDone.complete();
      await current;
      expect(NoteSyncBatch.pending, isNull);
    },
  );

  test('asynchronous reconciliation failures are contained', () async {
    final coordinator = ReminderCoordinator.forTesting(
      reconcile: () async => throw StateError('reconciliation unavailable'),
    );

    await expectLater(coordinator.reconcileAll(), completes);
  });
}

@pragma('vm:entry-point')
void _backgroundResponse(NotificationResponse _) {}
