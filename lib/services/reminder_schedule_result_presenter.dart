import 'dart:async';

import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

typedef OpenReminderSystemSettings = Future<bool> Function();

/// Presents the local-delivery outcome of a persisted reminder edit.
///
/// Keeping this mapping here gives every reminder editor identical feedback
/// without coupling reminder persistence to navigation or Flutter UI state.
class ReminderScheduleResultPresenter {
  ReminderScheduleResultPresenter._(this._openSystemSettings);

  static final instance = ReminderScheduleResultPresenter._(
    ReminderCoordinator.instance.openSystemSettings,
  );

  @visibleForTesting
  factory ReminderScheduleResultPresenter.forTesting({
    required OpenReminderSystemSettings openSystemSettings,
  }) => ReminderScheduleResultPresenter._(openSystemSettings);

  final OpenReminderSystemSettings _openSystemSettings;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _activeFeedback;
  ScaffoldMessengerState? _activeMessenger;

  void show(BuildContext context, ReminderUpdateResult result) {
    if (!context.mounted || !result.persisted) return;
    final delivery = result.delivery;
    final reminder = result.savedReminder;
    if (delivery == null ||
        reminder == null ||
        delivery.state == ReminderDeliveryState.superseded) {
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final isFailure = delivery.state == ReminderDeliveryState.failed;
    final isSuccess = delivery.state == ReminderDeliveryState.scheduled;
    final background = isSuccess
        ? colors.primaryContainer
        : isFailure
        ? colors.errorContainer
        : colors.tertiaryContainer;
    final foreground = isSuccess
        ? colors.onPrimaryContainer
        : isFailure
        ? colors.onErrorContainer
        : colors.onTertiaryContainer;

    final message = switch (delivery.state) {
      ReminderDeliveryState.scheduled => l10n.reminderSet,
      ReminderDeliveryState.unsupported =>
        reminder.type == ReminderType.alarm
            ? l10n.alarmUnsupportedPlatform
            : reminder.type == ReminderType.notification
            ? l10n.notificationUnsupportedPlatform
            : delivery.message ?? l10n.reminderScheduleFailed,
      ReminderDeliveryState.permissionDenied =>
        l10n.reminderSavedPermissionRequired,
      ReminderDeliveryState.pastDue => l10n.reminderSavedAlreadyDue,
      ReminderDeliveryState.capacityExceeded => l10n.reminderCapacityExceeded,
      ReminderDeliveryState.failed =>
        delivery.message ?? l10n.reminderScheduleFailed,
      ReminderDeliveryState.superseded => throw StateError(
        'Superseded reminder feedback must not be presented',
      ),
    };
    final action = delivery.state == ReminderDeliveryState.permissionDenied
        ? SnackBarAction(
            label: l10n.openSettings,
            textColor: foreground,
            onPressed: () {
              unawaited(_openSettingsSafely());
            },
          )
        : null;

    if (identical(_activeMessenger, messenger)) {
      _activeFeedback?.close();
    } else {
      _activeFeedback = null;
    }
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: foreground)),
        backgroundColor: background,
        action: action,
      ),
    );
    _activeFeedback = controller;
    _activeMessenger = messenger;
    unawaited(
      controller.closed.whenComplete(() {
        if (identical(_activeFeedback, controller)) {
          _activeFeedback = null;
          _activeMessenger = null;
        }
      }),
    );
  }

  Future<void> _openSettingsSafely() async {
    try {
      await _openSystemSettings();
    } catch (_) {
      // The reminder remains persisted. A platform settings failure must not
      // escape through a SnackBar callback as an unhandled async exception.
    }
  }
}
