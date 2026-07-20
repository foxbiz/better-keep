import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/utils/logger.dart';

typedef AlarmEndedHandler = Future<void> Function(int noteId);

/// Non-visual alarm lifecycle tracking. Programmatic stops are suppressed so
/// editing, deleting, or rescheduling an alarm cannot complete its note.
class AlarmLifecycleService {
  AlarmLifecycleService._();

  static final instance = AlarmLifecycleService._();

  StreamSubscription<AlarmSet>? _subscription;
  AlarmEndedHandler? _onUserEnded;
  final Map<int, int> _ringing = <int, int>{};
  final Set<int> _programmaticStops = <int>{};
  Future<void> _operations = Future<void>.value();

  void init(AlarmEndedHandler onUserEnded) {
    if (!isAlarmSupported) return;
    _onUserEnded = onUserEnded;
    _subscription?.cancel();
    _subscription = Alarm.ringing.listen(_onRingingChanged);
  }

  Future<void> stopProgrammatically(int alarmId) async {
    if (!isAlarmSupported) return;
    if (_ringing.containsKey(alarmId)) _programmaticStops.add(alarmId);
    await _serialize(() => Alarm.stop(alarmId));
    if (!_ringing.containsKey(alarmId)) _programmaticStops.remove(alarmId);
  }

  Future<bool> set(AlarmSettings settings) {
    return _serialize(() => Alarm.set(alarmSettings: settings));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _operations = _operations.then((_) async {
      try {
        completion.complete(await operation());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  void _onRingingChanged(AlarmSet alarmSet) {
    final next = <int, int>{};
    for (final alarm in alarmSet.alarms) {
      final noteId = int.tryParse(alarm.payload ?? '');
      if (noteId != null) next[alarm.id] = noteId;
    }

    for (final entry in _ringing.entries) {
      if (next.containsKey(entry.key)) continue;
      if (_programmaticStops.remove(entry.key)) continue;
      unawaited(
        Future<void>(() async {
          try {
            await _onUserEnded?.call(entry.value);
          } catch (error, stackTrace) {
            AppLogger.error(
              'Failed to complete note after alarm ended',
              error,
              stackTrace,
            );
          }
        }),
      );
    }

    _ringing
      ..clear()
      ..addAll(next);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _ringing.clear();
    _programmaticStops.clear();
  }
}
