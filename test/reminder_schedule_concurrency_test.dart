import 'dart:async';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/reminder_schedule_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Note note(Reminder? reminder) =>
      Note(id: 42, title: 'Race', content: '', reminder: reminder);

  Reminder reminder(int revision, ReminderType type) => Reminder(
    dateTime: DateTime(2026, 7, 20, 10 + revision),
    type: type,
    revision: revision,
  );

  test(
    'older schedule cannot restore a reminder changed during an await',
    () async {
      final serializer = AsyncKeyedSerializer<int>();
      var persisted = note(reminder(1, ReminderType.alarm));
      final oldIntent = ReminderScheduleIntent.fromNote(persisted);
      final permissionGate = Completer<void>();
      final registered = <ReminderType>[];

      final oldOperation = serializer.run<void>(42, () async {
        await permissionGate.future;
        if (oldIntent.matches(persisted)) registered.add(oldIntent.type);
      });

      persisted = note(reminder(2, ReminderType.notification));
      final newIntent = ReminderScheduleIntent.fromNote(persisted);
      final newOperation = serializer.run<void>(42, () async {
        if (newIntent.matches(persisted)) registered.add(newIntent.type);
      });

      permissionGate.complete();
      await Future.wait([oldOperation, newOperation]);

      expect(registered, [ReminderType.notification]);
    },
  );

  test(
    'older schedule cannot restore a reminder removed during an await',
    () async {
      final serializer = AsyncKeyedSerializer<int>();
      var persisted = note(reminder(1, ReminderType.notification));
      final oldIntent = ReminderScheduleIntent.fromNote(persisted);
      final cancellationGate = Completer<void>();
      var registrations = 0;

      final oldOperation = serializer.run<void>(42, () async {
        await cancellationGate.future;
        if (oldIntent.matches(persisted)) registrations++;
      });
      persisted = note(null);
      final removal = serializer.run<void>(42, () async {
        // A real coordinator cancellation runs here after the older request.
      });

      cancellationGate.complete();
      await Future.wait([oldOperation, removal]);

      expect(registrations, 0);
    },
  );
}
