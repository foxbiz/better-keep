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

  test('asynchronous reconciliation failures are contained', () async {
    final coordinator = ReminderCoordinator.forTesting(
      reconcile: () async => throw StateError('reconciliation unavailable'),
    );

    await expectLater(coordinator.reconcileAll(), completes);
  });
}

@pragma('vm:entry-point')
void _backgroundResponse(NotificationResponse _) {}
