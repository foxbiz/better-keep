import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/alarm_id_service.dart';
import 'package:better_keep/services/alarm_lifecycle_service.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/reminder_action_processor.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/reminder_action_ui_channel_stub.dart'
    if (dart.library.io) 'package:better_keep/services/reminder_action_ui_channel_native.dart'
    as reminder_action_ui;
import 'package:better_keep/services/reminder_navigation_service.dart';
import 'package:better_keep/services/reminder_notification_plan.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:better_keep/services/reminder_permission_service.dart';
import 'package:better_keep/services/reminder_schedule_intent.dart';
import 'package:better_keep/services/reminder_session_service.dart';
import 'package:better_keep/services/reminder_time_zone_resolver.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
void reminderNotificationBackgroundResponse(
  NotificationResponse response,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await ReminderCoordinator.instance.handleNotificationResponse(
      response,
      fromBackground: true,
    );
  } catch (error, stackTrace) {
    await AppLogger.error(
      'Unhandled background reminder response failure',
      error,
      stackTrace,
    );
  }
}

class ReminderCoordinator {
  ReminderCoordinator._();

  static final instance = ReminderCoordinator._();

  Future<void>? _initializing;
  Future<void>? _uiActionDrain;
  bool _uiActionDrainRequested = false;
  final AsyncKeyedSerializer<int> _noteOperations = AsyncKeyedSerializer<int>();
  final AsyncKeyedSerializer<String> _notificationPlanOperations =
      AsyncKeyedSerializer<String>();
  int _schedulingGeneration = 0;

  Future<void> init() {
    return _initializing ??= _init();
  }

  Future<void> _init() async {
    await LocalNotificationService.instance.init(
      onResponse: handleNotificationResponse,
      onBackgroundResponse: reminderNotificationBackgroundResponse,
    );
    await ReminderNavigationService.instance.restorePending();
    AlarmLifecycleService.instance.init(_completeFromAlarm);
  }

  void attachUiActionListener() {
    final attached = reminder_action_ui.attachReminderActionUiChannel(
      _handleUiActionSignal,
    );
    unawaited(AppLogger.log('Reminder action UI listener attached: $attached'));
  }

  void detachUiActionListener() {
    reminder_action_ui.detachReminderActionUiChannel();
  }

  void _handleUiActionSignal(Object? message) {
    if (message is! int) {
      unawaited(
        AppLogger.log('Reminder action UI signal ignored: invalid message'),
      );
      return;
    }
    unawaited(consumePendingUiActions());
  }

  Future<ReminderScheduleResult> schedule(
    Note note, {
    bool requestPermissions = false,
  }) async {
    await init();
    final noteId = note.id;
    final reminder = note.reminder;
    if (noteId == null || reminder == null || note.completed || note.trashed) {
      return const ReminderScheduleResult(ReminderDeliveryState.failed);
    }
    final expected = ReminderScheduleIntent.fromNote(note);
    _schedulingGeneration++;
    return _noteOperations.run(
      noteId,
      () => _scheduleSerialized(
        noteId,
        expected,
        requestPermissions: requestPermissions,
      ),
    );
  }

  Future<ReminderScheduleResult> _scheduleSerialized(
    int noteId,
    ReminderScheduleIntent expected, {
    required bool requestPermissions,
  }) async {
    var current = await Note.findById(noteId);
    if (!expected.matches(current)) {
      await _convergeLatestUnlocked(noteId, current);
      return const ReminderScheduleResult(ReminderDeliveryState.superseded);
    }
    if (!await ReminderSessionService.isSignedIn()) {
      await _cancelUnlocked(noteId);
      return const ReminderScheduleResult(
        ReminderDeliveryState.unsupported,
        reason: ReminderDeliveryReason.signedOut,
      );
    }

    try {
      await _cancelUnlocked(noteId);
      var reminder = current!.reminder!;
      if (!reminder.isSupportedType) {
        return const ReminderScheduleResult(
          ReminderDeliveryState.unsupported,
          reason: ReminderDeliveryReason.unsupportedType,
        );
      }

      if (requestPermissions) {
        final granted = await ReminderPermissionService().ensurePermissions(
          reminder.type,
        );
        if (!granted && _isDeliverySupported(reminder.type)) {
          return const ReminderScheduleResult(
            ReminderDeliveryState.permissionDenied,
            reason: ReminderDeliveryReason.permissionRequired,
          );
        }
      }

      current = await Note.findById(noteId);
      if (!expected.matches(current)) {
        await _convergeLatestUnlocked(noteId, current);
        return const ReminderScheduleResult(ReminderDeliveryState.superseded);
      }
      reminder = current!.reminder!;

      return switch (reminder.type) {
        ReminderType.notification => _scheduleNotification(current),
        ReminderType.alarm => _scheduleAlarm(current),
        ReminderType.unsupported => const ReminderScheduleResult(
          ReminderDeliveryState.unsupported,
        ),
      };
    } catch (error, stackTrace) {
      AppLogger.error('Failed to schedule reminder', error, stackTrace);
      return ReminderScheduleResult(
        ReminderDeliveryState.failed,
        reason: error is ReminderTimeZoneException
            ? ReminderDeliveryReason.timeZoneUnavailable
            : null,
        error: error,
      );
    }
  }

  Future<void> cancel(int noteId) async {
    await init();
    _schedulingGeneration++;
    await _noteOperations.run(noteId, () => _cancelUnlocked(noteId));
    await _reconcileNotificationPlan();
  }

  Future<void> _cancelUnlocked(int noteId) async {
    await LocalNotificationService.instance.cancelReminder(noteId);
    await _stopAlarmUnlocked(noteId);
  }

  Future<void> _stopAlarmUnlocked(int noteId) async {
    if (isAlarmSupported) {
      final alarmId = await AlarmIdService.getAlarmId(noteId);
      await AlarmLifecycleService.instance.stopProgrammatically(alarmId);
    }
  }

  Future<void> forget(int noteId) async {
    await init();
    _schedulingGeneration++;
    await _noteOperations.run(noteId, () async {
      await _cancelUnlocked(noteId);
      await AlarmIdService.removeAlarmId(noteId);
    });
    await _reconcileNotificationPlan();
  }

  Future<void> _convergeLatestUnlocked(int noteId, Note? note) async {
    await _cancelUnlocked(noteId);
    if (note == null ||
        note.completed ||
        note.trashed ||
        note.reminder == null ||
        !note.reminder!.isSupportedType ||
        !await ReminderSessionService.isSignedIn()) {
      await _reconcileNotificationPlan();
      return;
    }
    switch (note.reminder!.type) {
      case ReminderType.notification:
        await _scheduleNotification(note);
      case ReminderType.alarm:
        await _scheduleAlarm(note);
      case ReminderType.unsupported:
        break;
    }
  }

  Future<bool> openSystemSettings() {
    return ReminderPermissionService().openSystemSettings();
  }

  Future<void> reconcileAll() async {
    await init();
    if (!await ReminderSessionService.isSignedIn()) {
      await LocalNotificationService.instance.cancelAllReminderDeliveries();
      return;
    }
    final timeZoneChanged = await LocalNotificationService.instance
        .refreshTimeZone();
    try {
      final notes = await Note.get(NoteType.all);
      for (final note in notes) {
        if (note.id == null) continue;
        if (note.reminder == null || note.completed || note.trashed) {
          _schedulingGeneration++;
          await _noteOperations.run(note.id!, () => _cancelUnlocked(note.id!));
          continue;
        }
        if (note.reminder!.type == ReminderType.notification) {
          _schedulingGeneration++;
          await _noteOperations.run(
            note.id!,
            () => _stopAlarmUnlocked(note.id!),
          );
        } else {
          await schedule(note);
        }
      }
      await _reconcileNotificationPlan(forceRecreate: timeZoneChanged);
      if (timeZoneChanged) {
        AppLogger.log('Rescheduled reminders after timezone change');
      }
      await ReminderActionReceiptService.prune(AppState.db);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to reconcile reminders', error, stackTrace);
    }
  }

  Future<ReminderScheduleResult> _scheduleNotification(Note note) async {
    final notifications = LocalNotificationService.instance;
    if (!notifications.supportsScheduling) {
      return const ReminderScheduleResult(
        ReminderDeliveryState.unsupported,
        reason: ReminderDeliveryReason.notificationUnsupportedPlatform,
      );
    }
    final hasPermission = await ReminderPermissionService().hasPermissions(
      ReminderType.notification,
    );
    await AppLogger.log(
      'Reminder notification permission check: granted=$hasPermission',
    );
    if (!hasPermission) {
      return const ReminderScheduleResult(
        ReminderDeliveryState.permissionDenied,
        reason: ReminderDeliveryReason.permissionRequired,
      );
    }

    final plan = await _reconcileNotificationPlan();
    final noteId = note.id!;
    if (plan == null) {
      return const ReminderScheduleResult(ReminderDeliveryState.unsupported);
    }
    if (plan.capacityExceededNoteIds.contains(noteId)) {
      return ReminderScheduleResult(
        ReminderDeliveryState.capacityExceeded,
        reason: ReminderDeliveryReason.capacityExceeded,
      );
    }
    if (plan.pastDueNoteIds.contains(noteId)) {
      return const ReminderScheduleResult(ReminderDeliveryState.pastDue);
    }
    if (!plan.schedules(noteId)) {
      return const ReminderScheduleResult(ReminderDeliveryState.superseded);
    }
    return const ReminderScheduleResult(ReminderDeliveryState.scheduled);
  }

  Future<ReminderNotificationPlan?> _reconcileNotificationPlan({
    bool forceRecreate = false,
  }) async {
    final notifications = LocalNotificationService.instance;
    if (!notifications.supportsScheduling) return null;
    return _notificationPlanOperations.run('reminders', () async {
      ReminderNotificationPlan? result;
      var recreate = forceRecreate;
      while (true) {
        final generation = _schedulingGeneration;
        if (!await ReminderSessionService.isSignedIn()) {
          await notifications.cancelAllReminderDeliveries();
          return ReminderNotificationPlanner.build(
            candidates: const [],
            platform: _notificationPlatform,
            morningTime: AppState.morningTime,
            now: DateTime.now(),
          );
        }
        if (!await ReminderPermissionService().hasPermissions(
          ReminderType.notification,
        )) {
          return null;
        }
        final notes = await Note.get(NoteType.all);
        final candidates = <ReminderNotificationCandidate>[];
        for (final current in notes) {
          final reminder = current.reminder;
          final noteId = current.id;
          if (noteId == null ||
              reminder == null ||
              reminder.type != ReminderType.notification ||
              current.completed ||
              current.trashed) {
            continue;
          }
          candidates.add(_notificationCandidate(current));
        }
        result = ReminderNotificationPlanner.build(
          candidates: candidates,
          platform: _notificationPlatform,
          morningTime: AppState.morningTime,
          now: DateTime.now(),
        );
        if (result.capacityExceededNoteIds.isNotEmpty) {
          await AppLogger.log(
            'Reminder notification capacity reached: '
            'unscheduled=${result.capacityExceededNoteIds.length}, '
            'planned=${result.notifications.length}',
          );
        }
        await notifications.applyReminderPlan(
          result.notifications,
          forceRecreate: recreate,
        );
        recreate = false;
        if (generation == _schedulingGeneration) return result;
        await AppLogger.log(
          'Reminder notification plan changed while applying; rebuilding',
        );
      }
    });
  }

  ReminderNotificationCandidate _notificationCandidate(Note note) {
    final l10n = _l10n;
    return ReminderNotificationCandidate(
      noteId: note.id!,
      reminder: note.reminder!,
      title: note.locked
          ? l10n.reminderDue
          : (note.title?.trim().isNotEmpty == true
                ? note.title!.trim()
                : l10n.reminderDue),
      body: note.locked ? l10n.appTitle : note.body,
    );
  }

  ReminderNotificationPlatform get _notificationPlatform {
    if (kIsWeb) return ReminderNotificationPlatform.windows;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => ReminderNotificationPlatform.android,
      TargetPlatform.iOS => ReminderNotificationPlatform.ios,
      TargetPlatform.macOS => ReminderNotificationPlatform.macOS,
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => ReminderNotificationPlatform.windows,
    };
  }

  Future<ReminderScheduleResult> _scheduleAlarm(Note note) async {
    if (!isAlarmSupported) {
      return const ReminderScheduleResult(
        ReminderDeliveryState.unsupported,
        reason: ReminderDeliveryReason.alarmUnsupportedPlatform,
      );
    }
    if (note.reminder!.isAllDay) {
      return const ReminderScheduleResult(
        ReminderDeliveryState.unsupported,
        reason: ReminderDeliveryReason.alarmRequiresSpecificTime,
      );
    }
    if (!await ReminderPermissionService().hasPermissions(ReminderType.alarm)) {
      return const ReminderScheduleResult(
        ReminderDeliveryState.permissionDenied,
        reason: ReminderDeliveryReason.permissionRequired,
      );
    }

    final reminder = note.reminder!;
    final l10n = _l10n;
    var dueAt = reminder.dateTime;
    if (!dueAt.isAfter(DateTime.now())) {
      final next = reminder.getNextOccurrence();
      if (next == null) {
        return const ReminderScheduleResult(ReminderDeliveryState.pastDue);
      }
      dueAt = next.dateTime;
    }

    final alarmId = await AlarmIdService.getAlarmId(note.id!);
    final scheduled = await AlarmLifecycleService.instance.set(
      AlarmSettings(
        id: alarmId,
        dateTime: dueAt,
        assetAudioPath: AppState.alarmSound,
        loopAudio: true,
        vibrate: true,
        androidFullScreenIntent: true,
        allowSameSecondScheduling: true,
        allowAlarmOverlap: false,
        volumeSettings: VolumeSettings.fade(
          volume: 1,
          fadeDuration: const Duration(seconds: 3),
        ),
        notificationSettings: NotificationSettings(
          title: note.locked
              ? l10n.reminderDue
              : (note.title?.trim().isNotEmpty == true
                    ? note.title!.trim()
                    : l10n.reminderDue),
          body: note.locked ? l10n.appTitle : note.body,
          icon: LocalNotificationService.smallIcon,
          iconColor: note.color,
          stopButton: LocalNotificationService.instance.markDoneLabel,
        ),
        payload: note.id.toString(),
      ),
    );
    if (!scheduled) {
      throw StateError('The operating system rejected the alarm schedule.');
    }
    return const ReminderScheduleResult(ReminderDeliveryState.scheduled);
  }

  Future<void> handleNotificationResponse(
    NotificationResponse response, {
    bool fromBackground = false,
  }) async {
    final payload = decodeReminderNotificationPayload(response.payload);
    final noteId = payload?['noteId'];
    await AppLogger.log(
      'Reminder notification response: id=${response.id}, '
      'action=${response.actionId ?? 'default'}, '
      'type=${response.notificationResponseType.name}, '
      'noteId=${noteId is int ? noteId : 'invalid'}, '
      'background=$fromBackground',
    );
    if (payload == null || payload['kind'] != 'reminder') {
      await AppLogger.log('Reminder notification response rejected: payload');
      return;
    }
    if (noteId is! int) {
      await AppLogger.log('Reminder notification response rejected: noteId');
      return;
    }

    if (response.actionId == LocalNotificationService.markDoneActionId) {
      final initializationTimer = Stopwatch()..start();
      if (!await ReminderSessionService.isSignedIn()) {
        await _initializeBackgroundNotificationsIfNeeded(fromBackground);
        if (response.id != null) {
          await LocalNotificationService.instance.cancel(response.id!);
        }
        await AppLogger.log(
          'Reminder action ignored: result=signed_out, noteId=$noteId',
        );
        return;
      }
      if (fromBackground) {
        await ReminderActionProcessor.instance.ensureBackgroundReady();
      }
      final initializationMs = initializationTimer.elapsedMilliseconds;
      final transactionTimer = Stopwatch()..start();
      final result = await ReminderActionProcessor.instance.markDone(payload);
      final transactionMs = transactionTimer.elapsedMilliseconds;

      if (result.shouldRefreshUi) {
        if (fromBackground) {
          final signalTimer = Stopwatch()..start();
          final delivered = reminder_action_ui.signalReminderActionUi(noteId);
          unawaited(
            AppLogger.log(
              'Reminder action UI signal: noteId=$noteId, '
              'delivered=$delivered, elapsedMs=${signalTimer.elapsedMilliseconds}',
            ),
          );
        } else {
          await consumePendingUiActions();
        }
      }

      await AppLogger.log(
        'Reminder action processed: action=${response.actionId}, '
        'noteId=${result.noteId}, result=${result.state.name}, '
        'initializationMs=$initializationMs, transactionMs=$transactionMs',
      );
      await _finalizeNotificationAction(
        response,
        result,
        fromBackground: fromBackground,
      );
      return;
    }

    final isDefaultTap =
        response.actionId == null || response.actionId!.isEmpty;
    if (!fromBackground && isDefaultTap) {
      await ReminderNavigationService.instance.openFromNotification(
        notificationId: response.id,
        noteId: noteId,
        occurrenceToken: payload['token'] is String
            ? payload['token'] as String
            : null,
      );
      return;
    }
    await AppLogger.log(
      'Reminder notification response ignored: action=${response.actionId}',
    );
  }

  Future<void> _initializeBackgroundNotificationsIfNeeded(
    bool fromBackground,
  ) async {
    if (!fromBackground) return;
    await LocalNotificationService.instance.initForBackgroundAction(
      onBackgroundResponse: reminderNotificationBackgroundResponse,
    );
  }

  Future<void> _finalizeNotificationAction(
    NotificationResponse response,
    ReminderActionResult result, {
    required bool fromBackground,
  }) async {
    if (result.state == ReminderActionState.failed) return;

    await _initializeBackgroundNotificationsIfNeeded(fromBackground);
    final noteId = result.noteId;
    if (noteId != null && result.shouldRepairDelivery) {
      try {
        final note = await Note.findById(noteId);
        if (note != null &&
            !note.completed &&
            !note.trashed &&
            note.reminder?.type == ReminderType.notification) {
          final scheduleResult = await schedule(note);
          if (scheduleResult.state != ReminderDeliveryState.scheduled) {
            throw StateError(
              'Repeat repair returned ${scheduleResult.state.name}',
            );
          }
        }
      } catch (error, stackTrace) {
        await AppLogger.error(
          'Reminder repeat delivery repair deferred: noteId=$noteId',
          error,
          stackTrace,
        );
      }
    }
    if (result.shouldDismiss && response.id != null) {
      await LocalNotificationService.instance.cancel(response.id!);
    }
  }

  Future<void> consumePendingUiActions() {
    _uiActionDrainRequested = true;
    return _uiActionDrain ??= _drainPendingUiActions();
  }

  Future<void> _drainPendingUiActions() async {
    try {
      do {
        _uiActionDrainRequested = false;
        await _consumePendingUiActionsOnce();
      } while (_uiActionDrainRequested);
    } finally {
      _uiActionDrain = null;
    }
  }

  Future<void> _consumePendingUiActionsOnce() async {
    if (!await ReminderSessionService.isSignedIn()) return;
    final timer = Stopwatch()..start();
    try {
      final receipts = await ReminderActionReceiptService.pendingUiUpdates(
        AppState.db,
      );
      if (receipts.isEmpty) return;
      final notified = <int>{};
      for (final receipt in receipts) {
        final note = await Note.findById(receipt.noteId);
        if (note != null && notified.add(receipt.noteId)) {
          note.notify('updated', false);
        }
        await ReminderActionReceiptService.markUiConsumed(
          AppState.db,
          receipt.token,
        );
      }
      await AppLogger.log(
        'Reminder action UI updates consumed: '
        'receipts=${receipts.length}, notes=${notified.length}, '
        'elapsedMs=${timer.elapsedMilliseconds}',
      );
      try {
        unawaited(
          NoteSyncService().sync().catchError((Object error, StackTrace stack) {
            return AppLogger.error(
              'Reminder action sync trigger deferred',
              error,
              stack,
            );
          }),
        );
      } catch (error, stackTrace) {
        unawaited(
          AppLogger.error(
            'Reminder action sync trigger deferred',
            error,
            stackTrace,
          ),
        );
      }
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Failed to consume reminder action UI updates',
        error,
        stackTrace,
      );
    }
  }

  Future<void> onAppResumed() async {
    await consumePendingUiActions();
    await reconcileAll();
    await ReminderNavigationService.instance.flush();
  }

  Future<void> _completeFromAlarm(int noteId) async {
    final note = await Note.findById(noteId);
    if (note == null || note.completed || note.reminder == null) return;
    await note.done();
  }

  bool _isDeliverySupported(ReminderType type) {
    return switch (type) {
      ReminderType.notification =>
        LocalNotificationService.instance.supportsScheduling,
      ReminderType.alarm => isAlarmSupported,
      ReminderType.unsupported => false,
    };
  }

  AppLocalizations get _l10n {
    final requested =
        AppState.locale ?? WidgetsBinding.instance.platformDispatcher.locale;
    final locale =
        AppLocalizations.supportedLocales.any(
          (supported) => supported.languageCode == requested.languageCode,
        )
        ? Locale(requested.languageCode)
        : const Locale('en');
    return lookupAppLocalizations(locale);
  }
}
