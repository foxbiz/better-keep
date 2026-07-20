import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/database.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/reminder_occurrence.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';

enum ReminderActionState { applied, alreadyApplied, stale, missing, failed }

class ReminderActionResult {
  const ReminderActionResult(
    this.state, {
    this.noteId,
    this.activeReminder,
    this.error,
  });

  final ReminderActionState state;
  final int? noteId;
  final Reminder? activeReminder;
  final Object? error;

  bool get shouldDismiss => state != ReminderActionState.failed;
  bool get shouldRefreshUi =>
      state == ReminderActionState.applied ||
      state == ReminderActionState.alreadyApplied;
  bool get shouldRepairDelivery =>
      (state == ReminderActionState.applied ||
          state == ReminderActionState.alreadyApplied) &&
      activeReminder != null;
}

/// Applies notification actions without initializing Firebase, navigation,
/// alarms, or the full application coordinator. This is safe to use from the
/// separate Flutter engine spawned for Android/iOS background actions.
class ReminderActionProcessor {
  ReminderActionProcessor._();

  static final instance = ReminderActionProcessor._();
  static const markDoneAction = 'mark_done';

  Future<void> ensureBackgroundReady() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      AppState.db;
    } on StateError {
      await AppState.init();
      await initDatabase();
    }
  }

  Future<ReminderActionResult> markDone(
    Map<String, dynamic> payload, {
    Database? database,
    DateTime? now,
  }) async {
    final db = database ?? AppState.db;
    final actionTime = now ?? DateTime.now();
    final noteId = payload['noteId'];
    final revision = payload['revision'];
    final dueAt = DateTime.tryParse(payload['dueAt'] as String? ?? '');
    final token = payload['token'];
    if (noteId is! int ||
        revision is! int ||
        dueAt == null ||
        token is! String ||
        token != reminderOccurrenceToken(noteId, revision, dueAt)) {
      await AppLogger.log(
        'Reminder action rejected: result=stale, noteId=${noteId is int ? noteId : 'invalid'}',
      );
      return ReminderActionResult(
        ReminderActionState.stale,
        noteId: noteId is int ? noteId : null,
      );
    }

    try {
      return await db.transaction((transaction) async {
        if (await ReminderActionReceiptService.exists(transaction, token)) {
          final active = await _readActiveReminder(transaction, noteId);
          return ReminderActionResult(
            ReminderActionState.alreadyApplied,
            noteId: noteId,
            activeReminder: active,
          );
        }

        final rows = await transaction.query(
          Note.model,
          columns: const ['reminder', 'completed', 'trashed'],
          where: 'id = ?',
          whereArgs: [noteId],
          limit: 1,
        );
        if (rows.isEmpty) {
          return ReminderActionResult(
            ReminderActionState.missing,
            noteId: noteId,
          );
        }
        final row = rows.first;
        if (row['trashed'] == 1 || row['completed'] == 1) {
          return ReminderActionResult(
            ReminderActionState.stale,
            noteId: noteId,
          );
        }
        final rawReminder = row['reminder'];
        if (rawReminder is! String) {
          return ReminderActionResult(
            ReminderActionState.stale,
            noteId: noteId,
          );
        }
        final reminder = Reminder.fromJson(
          jsonDecode(rawReminder) as Map<String, Object?>,
        );
        if (reminder.type != ReminderType.notification ||
            reminder.revision != revision ||
            !isReminderOccurrence(
              reminder,
              dueAt,
              morningTime: AppState.morningTime,
            )) {
          return ReminderActionResult(
            ReminderActionState.stale,
            noteId: noteId,
          );
        }

        if (!await ReminderActionReceiptService.claim(
          transaction,
          token,
          noteId: noteId,
          action: markDoneAction,
          now: actionTime,
        )) {
          final active = await _readActiveReminder(transaction, noteId);
          return ReminderActionResult(
            ReminderActionState.alreadyApplied,
            noteId: noteId,
            activeReminder: active,
          );
        }

        final advanceAfter = actionTime.isAfter(dueAt) ? actionTime : dueAt;
        final next = reminder.getNextOccurrence(after: advanceAfter);
        final updatedReminder = next?.copyWith(revision: reminder.revision + 1);
        final updatedAt = actionTime.toIso8601String();
        await transaction.update(
          Note.model,
          {
            'reminder': jsonEncode((updatedReminder ?? reminder).toJson()),
            'completed': updatedReminder == null ? 1 : 0,
            'updated_at': updatedAt,
          },
          where: 'id = ?',
          whereArgs: [noteId],
        );
        await _markSyncPending(transaction, noteId, updatedAt);
        return ReminderActionResult(
          ReminderActionState.applied,
          noteId: noteId,
          activeReminder: updatedReminder,
        );
      });
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Reminder action failed: action=$markDoneAction, noteId=$noteId',
        error,
        stackTrace,
      );
      return ReminderActionResult(
        ReminderActionState.failed,
        noteId: noteId,
        error: error,
      );
    }
  }

  Future<Reminder?> _readActiveReminder(DatabaseExecutor db, int noteId) async {
    final rows = await db.query(
      Note.model,
      columns: const ['reminder', 'completed', 'trashed'],
      where: 'id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.first['completed'] == 1 ||
        rows.first['trashed'] == 1) {
      return null;
    }
    final raw = rows.first['reminder'];
    if (raw is! String) return null;
    final reminder = Reminder.fromJson(jsonDecode(raw) as Map<String, Object?>);
    return reminder.type == ReminderType.notification ? reminder : null;
  }

  Future<void> _markSyncPending(
    Transaction transaction,
    int noteId,
    String now,
  ) async {
    final tracks = await transaction.query(
      'sync_track',
      columns: const ['id'],
      where: 'local_id = ?',
      whereArgs: [noteId],
      limit: 1,
    );
    if (tracks.isEmpty) {
      await transaction.insert('sync_track', {
        'local_id': noteId,
        'action': 'upload',
        'status': 'pending',
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await transaction.update(
        'sync_track',
        {'action': 'upload', 'status': 'pending', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [tracks.first['id']],
      );
    }
  }
}
