import 'package:better_keep/config.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/reminder.dart';

Future<Reminder?> reminder(BuildContext context, {Reminder? initialReminder}) {
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
  static const double _maxDialogWidth = 440;

  late String _date;
  late String? _time;
  late String _repeat;
  late String _selectedDateOption;
  late String? _selectedTimeOption;
  late bool _isRepeatMode;
  late ReminderType _type;

  @override
  void initState() {
    super.initState();
    final r = widget.initialReminder;
    if (r != null) {
      _type = r.type == ReminderType.unsupported
          ? ReminderType.notification
          : r.type;
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
        _time = null;
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
      _type = ReminderType.notification;
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
      constraints: const BoxConstraints(maxWidth: _maxDialogWidth),
      title: Text(context.l10n.setReminder),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ReminderDropdownField<ReminderType>(
              label: context.l10n.reminderType,
              value: _type,
              items: [
                DropdownMenuItem(
                  value: ReminderType.notification,
                  child: _ReminderOptionSummary(
                    primary: context.l10n.notificationReminder,
                  ),
                ),
                DropdownMenuItem(
                  value: ReminderType.alarm,
                  child: _ReminderOptionSummary(
                    primary: context.l10n.alarmReminder,
                  ),
                ),
              ],
              onChanged: (type) {
                if (type == null) return;
                setState(() {
                  _type = type;
                  if (_type == ReminderType.alarm &&
                      _selectedTimeOption == Reminder.allDay) {
                    _selectedTimeOption = null;
                    _time = null;
                  }
                });
              },
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _type == ReminderType.notification
                    ? context.l10n.notificationReminderDescription
                    : context.l10n.alarmReminderDescription,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_platformInfo != null) ...[
              const SizedBox(height: 12),
              _buildInfo(_platformInfo!),
            ],
            if (_type == ReminderType.alarm) ...[
              const SizedBox(height: 8),
              _buildInfo(context.l10n.alarmRequiresSpecificTime),
            ],
            const SizedBox(height: 12),
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
              _ReminderDropdownField<String>(
                label: context.l10n.frequency,
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
              _ReminderDropdownField<String>(
                label: context.l10n.date,
                value: _selectedDateOption,
                onChanged: _selectDate,
                items: Reminder.dateOptions.map(_buildItem).toList(),
              ),
            const SizedBox(height: 12),
            _ReminderDropdownField<String>(
              label: context.l10n.time,
              hint: context.l10n.selectTime,
              value: _selectedTimeOption,
              onChanged: _selectTime,
              items: Reminder.timeOptions
                  .where(
                    (option) =>
                        _type != ReminderType.alarm ||
                        option != Reminder.allDay,
                  )
                  .map(_buildTimeItem)
                  .toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: !_hasSelectedTime
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
                    Reminder.build(
                      effectiveDate,
                      _selectedTimeOption == Reminder.allDay
                          ? Reminder.allDay
                          : _time!,
                      effectiveRepeat,
                      type: _type,
                    ),
                  );
                },
          child: Text(context.l10n.ok),
        ),
      ],
    );
  }

  String? get _platformInfo {
    if (_type == ReminderType.alarm && !isAlarmSupported) {
      return context.l10n.alarmUnsupportedPlatform;
    }
    if (_type == ReminderType.notification &&
        !LocalNotificationService.instance.supportsScheduling) {
      return context.l10n.notificationUnsupportedPlatform;
    }
    return null;
  }

  Widget _buildInfo(String text) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  DropdownMenuItem<String> _buildRepeatItem(String option) {
    return DropdownMenuItem(
      value: option,
      child: _ReminderOptionSummary(primary: _optionLabel(option)),
    );
  }

  DropdownMenuItem<String> _buildTimeItem(String option) {
    String? displayValue;
    if (option != Reminder.custom && option != Reminder.allDay) {
      displayValue = Reminder.getValueOf(context, option);
    } else if (option == Reminder.custom &&
        _selectedTimeOption == Reminder.custom) {
      displayValue = _formatStoredTime(_time);
    }

    return DropdownMenuItem(
      value: option,
      child: _ReminderOptionSummary(
        primary: _optionLabel(option),
        secondary: displayValue,
      ),
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
        Reminder.allDay => null,
        _ => _time,
      };
    });
  }

  bool get _hasSelectedTime =>
      _selectedTimeOption == Reminder.allDay || _time != null;

  DropdownMenuItem<String> _buildItem(String option) {
    DateTime? displayDate;

    if (option != Reminder.custom) {
      displayDate = DateTime.tryParse(Reminder.getValueOf(context, option));
    } else if (_selectedDateOption == Reminder.custom) {
      displayDate = DateTime.tryParse(_date);
    }

    return DropdownMenuItem(
      value: option,
      child: _ReminderOptionSummary(
        primary: _optionLabel(option),
        secondary: displayDate == null
            ? null
            : MaterialLocalizations.of(context).formatMediumDate(displayDate),
      ),
    );
  }

  String _optionLabel(String option) {
    return switch (option) {
      Reminder.today => context.l10n.today,
      Reminder.tomorrow => context.l10n.tomorrow,
      Reminder.nextWeek => context.l10n.nextWeek,
      Reminder.nextMonth => context.l10n.nextMonth,
      Reminder.morning => context.l10n.morning,
      Reminder.afternoon => context.l10n.afternoon,
      Reminder.evening => context.l10n.evening,
      Reminder.allDay => context.l10n.allDay,
      Reminder.custom => context.l10n.custom,
      Reminder.repeatDaily => context.l10n.daily,
      Reminder.repeatWeekly => context.l10n.weekly,
      Reminder.repeatMonthly => context.l10n.monthly,
      Reminder.repeatYearly => context.l10n.yearly,
      _ => option,
    };
  }

  String? _formatStoredTime(String? value) {
    if (value == null || value == Reminder.allDay) return null;

    final match = RegExp(
      r'^(\d{1,2}):(\d{2})(?:\s+(AM|PM))?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return value;

    var hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    final period = match.group(3)?.toUpperCase();
    if (hour == null || minute == null || minute > 59) return value;

    if (period != null) {
      if (hour < 1 || hour > 12) return value;
      if (hour == 12) hour = 0;
      if (period == 'PM') hour += 12;
    } else if (hour > 23) {
      return value;
    }

    return TimeOfDay(hour: hour, minute: minute).format(context);
  }
}

class _ReminderDropdownField<T> extends StatelessWidget {
  const _ReminderDropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      isEmpty: value == null,
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: hint == null ? null : _ReminderOptionSummary(primary: hint!),
          isExpanded: true,
          itemHeight: null,
          borderRadius: BorderRadius.circular(12),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _ReminderOptionSummary extends StatelessWidget {
  const _ReminderOptionSummary({required this.primary, this.secondary});

  final String primary;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(primary),
          if (secondary?.isNotEmpty == true)
            Text(
              secondary!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
