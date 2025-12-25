import 'package:better_keep/services/reminder_permission_service.dart';
import 'package:better_keep/utils/week_days.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/reminder.dart';

Future<Reminder?> reminder(BuildContext context) async {
  // Request permissions just-in-time before showing the reminder dialog
  final hasPermission = await ReminderPermissionService().ensurePermissions();

  if (!hasPermission) {
    // Show a message if permissions were denied
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Notification and alarm permissions are required for reminders',
          ),
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
      return DatetimePicker();
    },
  );
}

class DatetimePicker extends StatefulWidget {
  const DatetimePicker({super.key});

  @override
  State<DatetimePicker> createState() => _DatetimePickerState();
}

class _DatetimePickerState extends State<DatetimePicker> {
  String _date = DateTime.now().toIso8601String(); // Default to today
  String? _time;
  String _repeat = Reminder.repeatDaily; // Default repeat is daily
  String _selectedDateOption = Reminder.today; // Default date option
  String? _selectedTimeOption;
  bool _isRepeatMode = false; // Toggle: false = date mode, true = repeat mode

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set Reminder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Toggle switch for repeat mode
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Repeat'),
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
            hint: Text("Time"),
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
          child: Text('Cancel'),
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
          child: Text('OK'),
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
      String timeValue = Reminder.getValueOf(option);
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
          _time = selectedTime.format(context);
        });
      }
      return;
    }

    setState(() {
      _selectedTimeOption = option;
      _time = switch (option) {
        Reminder.morning => Reminder.morningValue,
        Reminder.afternoon => Reminder.afternoonValue,
        Reminder.evening => Reminder.eveningValue,
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
        value = Reminder.getValueOf(option);

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
        value = Reminder.getValueOf(option);

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
