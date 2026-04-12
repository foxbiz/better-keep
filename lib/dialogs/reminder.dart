import 'package:better_keep/services/reminder_permission_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/week_days.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/reminder.dart';

Future<Reminder?> reminder(
  BuildContext context, {
  Reminder? initialReminder,
}) async {
  // Request permissions just-in-time before showing the reminder dialog
  final hasPermission = await ReminderPermissionService().ensurePermissions();

  if (!hasPermission) {
    // Show a message if permissions were denied
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.notificationPermissionsRequired),
          backgroundColor: Colors.orange,
        ),
      );
    }
    return null;
  }

  if (!context.mounted) return null;

  return showDialog<Reminder>(
    context: context,
    builder: (context) {
      return DatetimePicker(initialReminder: initialReminder);
    },
  );
}

class DatetimePicker extends StatefulWidget {
  const DatetimePicker({super.key, this.initialReminder});

  final Reminder? initialReminder;

  @override
  State<DatetimePicker> createState() => _DatetimePickerState();
}

class _DatetimePickerState extends State<DatetimePicker> {
  late String _date;
  late String? _time;
  late String _repeat;
  late String _selectedDateOption;
  late String? _selectedTimeOption;
  late bool _isRepeatMode;

  @override
  void initState() {
    super.initState();
    final r = widget.initialReminder;
    if (r != null) {
      _isRepeatMode = r.isRepeating;
      _repeat = r.isRepeating ? r.repeat : Reminder.repeatDaily;
      _date = r.dateTime.toIso8601String();

      // Try to match the stored date to a named date option
      final now = DateTime.now();
      final reminderDate = DateTime(
        r.dateTime.year,
        r.dateTime.month,
        r.dateTime.day,
      );
      final today = DateTime(now.year, now.month, now.day);
      if (reminderDate == today) {
        _selectedDateOption = Reminder.today;
      } else if (reminderDate == today.add(const Duration(days: 1))) {
        _selectedDateOption = Reminder.tomorrow;
      } else if (reminderDate == today.add(const Duration(days: 7))) {
        _selectedDateOption = Reminder.nextWeek;
      } else if (reminderDate == today.add(const Duration(days: 30))) {
        _selectedDateOption = Reminder.nextMonth;
      } else {
        _selectedDateOption = Reminder.custom;
      }

      // Try to match the stored time to a named time option
      if (r.isAllDay) {
        _selectedTimeOption = Reminder.allDay;
        _time = 'All Day';
      } else {
        final reminderTime = TimeOfDay(
          hour: r.dateTime.hour,
          minute: r.dateTime.minute,
        );
        final hour = r.dateTime.hour;
        final minute = r.dateTime.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final hour12 = hour % 12 == 0 ? 12 : hour % 12;
        _time = '$hour12:$minute $period';

        if (reminderTime == AppState.morningTime) {
          _selectedTimeOption = Reminder.morning;
        } else if (reminderTime == AppState.afternoonTime) {
          _selectedTimeOption = Reminder.afternoon;
        } else if (reminderTime == AppState.eveningTime) {
          _selectedTimeOption = Reminder.evening;
        } else {
          _selectedTimeOption = Reminder.custom;
        }
      }
    } else {
      _isRepeatMode = false;
      _repeat = Reminder.repeatDaily;
      _date = DateTime.now().toIso8601String();
      _selectedDateOption = Reminder.today;
      _selectedTimeOption = null;
      _time = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.setReminder),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Toggle switch for repeat mode
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(context.l10n.repeat),
              Switch(
                value: _isRepeatMode,
                onChanged: (value) {
                  setState(() {
                    _isRepeatMode = value;
                    if (value) {
                      // Switching to repeat mode - reset to defaults
                      _repeat = Reminder.repeatDaily;
                    } else {
                      // Switching to date mode - reset to today
                      _selectedDateOption = Reminder.today;
                      _date = DateTime.now().toIso8601String();
                    }
                  });
                },
              ),
            ],
          ),
          SizedBox(height: 8),
          // Show date selector or repeat selector based on toggle
          if (_isRepeatMode)
            DropdownButton<String>(
              isExpanded: true,
              value: _repeat,
              onChanged: (option) {
                setState(() {
                  _repeat = option ?? Reminder.repeatDaily;
                });
              },
              items: Reminder.repeatOptions
                  .where(
                    (r) =>
                        r != Reminder.repeatNever && r != Reminder.repeatOnce,
                  )
                  .map(_buildRepeatItem)
                  .toList(),
            )
          else
            DropdownButton<String>(
              isExpanded: true,
              value: _selectedDateOption,
              onChanged: _selectDate,
              items: Reminder.dateOptions.map(_buildItem).toList(),
            ),
          SizedBox(height: 8),
          DropdownButton<String>(
            hint: Text(context.l10n.time),
            isExpanded: true,
            value: _selectedTimeOption,
            onChanged: _selectTime,
            items: Reminder.timeOptions.map(_buildTimeItem).toList(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: _time == null
              ? null
              : () {
                  final effectiveRepeat = _isRepeatMode
                      ? _repeat
                      : Reminder.repeatNever;
                  final effectiveDate = _isRepeatMode
                      ? DateTime.now()
                            .toIso8601String() // Use today for repeat mode
                      : _date;
                  Navigator.pop(
                    context,
                    Reminder.build(effectiveDate, _time!, effectiveRepeat),
                  );
                },
          child: Text(context.l10n.ok),
        ),
      ],
    );
  }

  DropdownMenuItem<String> _buildRepeatItem(String option) {
    return DropdownMenuItem(value: option, child: Text(option));
  }

  DropdownMenuItem<String> _buildTimeItem(String option) {
    Widget displayValue = SizedBox.shrink();

    if (option != Reminder.custom) {
      String timeValue = Reminder.getValueOf(context, option);
      if (timeValue.isNotEmpty) {
        displayValue = Text(
          timeValue,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        );
      }
    } else if (_selectedTimeOption == Reminder.custom && _time != null) {
      // Show custom selected time
      displayValue = Text(
        _time!,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      );
    }

    return DropdownMenuItem(
      value: option,
      child: Row(children: [Text(option), Spacer(), displayValue]),
    );
  }

  void _selectDate(String? option) async {
    if (option == null) return;

    if (option == Reminder.custom) {
      final selectedDate = await showDatePicker(
        context: context,
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(Duration(days: 365)),
        initialDate: DateTime.now(),
      );

      if (!context.mounted) {
        return;
      }

      if (selectedDate != null) {
        setState(() {
          _selectedDateOption = Reminder.custom;
          _date = selectedDate.toIso8601String();
        });
      }
      return;
    }

    setState(() {
      _selectedDateOption = option;
      _date = switch (option) {
        Reminder.today => DateTime.now().toIso8601String(),
        Reminder.tomorrow =>
          DateTime.now().add(Duration(days: 1)).toIso8601String(),
        Reminder.nextWeek =>
          DateTime.now().add(Duration(days: 7)).toIso8601String(),
        Reminder.nextMonth =>
          DateTime.now().add(Duration(days: 30)).toIso8601String(),
        _ => _date,
      };
    });
  }

  void _selectTime(String? option) async {
    if (option == Reminder.custom) {
      final selectedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );

      if (!context.mounted) {
        return;
      }

      if (selectedTime != null) {
        setState(() {
          _selectedTimeOption = option;
          // Always format time in 12-hour format with AM/PM to ensure consistent parsing
          final hour = selectedTime.hourOfPeriod == 0
              ? 12
              : selectedTime.hourOfPeriod;
          final minute = selectedTime.minute.toString().padLeft(2, '0');
          final period = selectedTime.period == DayPeriod.am ? 'AM' : 'PM';
          _time = '$hour:$minute $period';
        });
      }
      return;
    }

    setState(() {
      _selectedTimeOption = option;
      _time = switch (option) {
        Reminder.morning => Reminder.getMorningValue(context),
        Reminder.afternoon => Reminder.getAfternoonValue(context),
        Reminder.evening => Reminder.getEveningValue(context),
        Reminder.allDay => "All Day",
        _ => _time,
      };
    });
  }

  DropdownMenuItem<String> _buildItem(String option) {
    String value = option;
    Widget displayValue = SizedBox.shrink();

    if (option != Reminder.custom) {
      if (Reminder.dateOptions.contains(option)) {
        value = Reminder.getValueOf(context, option);

        DateTime date = DateTime.parse(value);

        displayValue = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              weekDays[date.weekday - 1],
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            Text(
              "${date.day}/${date.month}/${date.year}",
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        );
      } else if (Reminder.timeOptions.contains(option)) {
        value = Reminder.getValueOf(context, option);

        displayValue = Text(
          value,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        );
      }
    }

    return DropdownMenuItem(
      value: option,
      child: Row(children: [Text(option), Spacer(), displayValue]),
    );
  }
}
