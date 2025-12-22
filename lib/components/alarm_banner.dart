import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:flutter/material.dart';

/// Service to manage ringing alarms globally
class RingingAlarmService {
  static final RingingAlarmService _instance = RingingAlarmService._internal();
  factory RingingAlarmService() => _instance;
  RingingAlarmService._internal();

  final ValueNotifier<List<AlarmSettings>> ringingAlarms = ValueNotifier([]);
  final Map<int, int> _alarmIdToNoteId = {};
  StreamSubscription<AlarmSet>? _subscription;

  void init() {
    if (!isAlarmSupported) {
      return;
    }

    _subscription?.cancel();
    _subscription = Alarm.ringing.listen((alarmSet) {
      final alarms = alarmSet.alarms;

      // Update the alarm to note mapping
      for (final alarm in alarms) {
        final noteId = int.tryParse(alarm.payload ?? '');
        if (noteId != null) {
          _alarmIdToNoteId[alarm.id] = noteId;
        }
      }

      // Update the ringing alarms list
      ringingAlarms.value = List.from(alarms);
    });
  }

  void dispose() {
    _subscription?.cancel();
  }

  int? getNoteIdForAlarm(int alarmId) {
    return _alarmIdToNoteId[alarmId];
  }

  Future<void> stopAlarm(int alarmId) async {
    await Alarm.stop(alarmId);
  }

  Future<void> stopAlarmAndMarkDone(int alarmId) async {
    final noteId = _alarmIdToNoteId[alarmId];
    await Alarm.stop(alarmId);

    if (noteId != null) {
      final note = await Note.findById(noteId);
      if (note != null && !note.completed) {
        await note.done();
      }
    }
  }

  Future<void> stopAllAlarms() async {
    await Alarm.stopAll();
  }
}

/// A banner widget that shows when alarms are ringing
class AlarmBanner extends StatelessWidget {
  const AlarmBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isAlarmSupported) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<List<AlarmSettings>>(
      valueListenable: RingingAlarmService().ringingAlarms,
      builder: (context, alarms, child) {
        if (alarms.isEmpty) {
          return const SizedBox.shrink();
        }

        return Material(
          elevation: 8,
          color: Theme.of(context).colorScheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: alarms.map((alarm) {
                  return _AlarmBannerItem(alarm: alarm);
                }).toList(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AlarmBannerItem extends StatelessWidget {
  final AlarmSettings alarm;

  const _AlarmBannerItem({required this.alarm});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noteId = RingingAlarmService().getNoteIdForAlarm(alarm.id);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.alarm, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  alarm.notificationSettings.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (alarm.notificationSettings.body.isNotEmpty)
                  Text(
                    alarm.notificationSettings.body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer.withValues(
                        alpha: 0.8,
                      ),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (noteId != null)
            FilledButton.tonal(
              onPressed: () => _markAsDone(context),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.onErrorContainer.withValues(
                  alpha: 0.2,
                ),
                foregroundColor: theme.colorScheme.onErrorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('Done'),
            ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () => _stopAlarm(context),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.onErrorContainer.withValues(
                alpha: 0.2,
              ),
              foregroundColor: theme.colorScheme.onErrorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 36),
            ),
            child: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }

  Future<void> _stopAlarm(BuildContext context) async {
    await RingingAlarmService().stopAlarm(alarm.id);
  }

  Future<void> _markAsDone(BuildContext context) async {
    await RingingAlarmService().stopAlarmAndMarkDone(alarm.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Note marked as done'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
}
