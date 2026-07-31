import 'dart:async';

import 'package:better_keep/dialogs/unlock_note_dialog.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/reminder_session_service.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef ReminderNavigationNoteLoader = Future<Note?> Function(int noteId);
typedef ReminderNavigationUnlocker =
    Future<bool?> Function(BuildContext context, Note note);
typedef ReminderNavigationRouteOpener =
    Future<void> Function(BuildContext context, Note note);
typedef ReminderNavigationDiagnostics = Future<void> Function(String message);

class _PendingReminderNavigation {
  const _PendingReminderNavigation(this.noteId, this.createdAt);

  final int noteId;
  final DateTime createdAt;
}

/// Persists notification navigation until authenticated note UI and the root
/// navigator are ready. A notification tap can arrive before any of those
/// startup conditions have completed.
class ReminderNavigationService {
  ReminderNavigationService._();

  static final instance = ReminderNavigationService._();
  static String _noteIdKey(SharedPreferences preferences) =>
      FirebaseScopedPreferences.keyForPreferences(
        'pending_reminder_navigation_note_id',
        preferences,
      );
  static String _createdAtKey(SharedPreferences preferences) =>
      FirebaseScopedPreferences.keyForPreferences(
        'pending_reminder_navigation_created_at',
        preferences,
      );
  static String _lastActivationKey(SharedPreferences preferences) =>
      FirebaseScopedPreferences.keyForPreferences(
        'reminder_navigation_last_activation',
        preferences,
      );
  static String _lastActivationAtKey(SharedPreferences preferences) =>
      FirebaseScopedPreferences.keyForPreferences(
        'reminder_navigation_last_activation_at',
        preferences,
      );
  static const _maxPendingAge = Duration(minutes: 10);
  static const _maxActivationAge = Duration(seconds: 10);

  final Set<Object> _readyHosts = <Object>{};
  _PendingReminderNavigation? _pending;
  bool _opening = false;

  @visibleForTesting
  ReminderNavigationNoteLoader? noteLoaderOverride;

  @visibleForTesting
  ReminderNavigationUnlocker? unlockerOverride;

  @visibleForTesting
  ReminderNavigationRouteOpener? routeOpenerOverride;

  @visibleForTesting
  ReminderNavigationDiagnostics? diagnosticsOverride;

  @visibleForTesting
  DateTime Function()? nowOverride;

  DateTime get _now => (nowOverride ?? DateTime.now)();

  Future<void> restorePending() async {
    if (_pending != null) return;
    final prefs = await SharedPreferences.getInstance();
    final noteId = prefs.getInt(_noteIdKey(prefs));
    final createdAt = DateTime.tryParse(
      prefs.getString(_createdAtKey(prefs)) ?? '',
    );
    if (noteId == null || createdAt == null) {
      await _clearPersisted(prefs);
      return;
    }
    if (_now.difference(createdAt) > _maxPendingAge) {
      await _log(
        'Reminder navigation discarded: reason=expired, noteId=$noteId',
      );
      await _clearPersisted(prefs);
      return;
    }
    _pending = _PendingReminderNavigation(noteId, createdAt);
    await _log('Reminder navigation restored: noteId=$noteId');
    await flush();
  }

  Future<void> open(int noteId) async {
    if (!await ReminderSessionService.isSignedIn()) {
      await _log(
        'Reminder navigation discarded: reason=signed_out, noteId=$noteId',
      );
      await clear();
      return;
    }
    final pending = _PendingReminderNavigation(noteId, _now);
    _pending = pending;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_noteIdKey(prefs), pending.noteId);
    await prefs.setString(
      _createdAtKey(prefs),
      pending.createdAt.toIso8601String(),
    );
    await _log('Reminder navigation queued: noteId=$noteId');
    await flush();
  }

  Future<void> openFromNotification({
    required int? notificationId,
    required int noteId,
    required String? occurrenceToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final activation =
        '${notificationId ?? 'unknown'}:${occurrenceToken ?? noteId}';
    final previous = prefs.getString(_lastActivationKey(prefs));
    final previousAt = DateTime.tryParse(
      prefs.getString(_lastActivationAtKey(prefs)) ?? '',
    );
    final now = _now;
    final age = previousAt == null ? null : now.difference(previousAt);
    if (previous == activation &&
        age != null &&
        !age.isNegative &&
        age <= _maxActivationAge) {
      await _log(
        'Reminder navigation discarded: reason=duplicate_activation, noteId=$noteId',
      );
      return;
    }
    await prefs.setString(_lastActivationKey(prefs), activation);
    await prefs.setString(_lastActivationAtKey(prefs), now.toIso8601String());
    await open(noteId);
  }

  void registerReadyHost(Object host) {
    _readyHosts.add(host);
    unawaited(
      _log('Reminder navigation host ready: hosts=${_readyHosts.length}'),
    );
    unawaited(flush());
  }

  void unregisterReadyHost(Object host) {
    _readyHosts.remove(host);
  }

  Future<void> flush() async {
    final pending = _pending;
    if (_opening || pending == null || _readyHosts.isEmpty) return;
    if (_now.difference(pending.createdAt) > _maxPendingAge) {
      await _log(
        'Reminder navigation discarded: reason=expired, noteId=${pending.noteId}',
      );
      await clear();
      return;
    }
    if (!await ReminderSessionService.isSignedIn()) {
      await _log(
        'Reminder navigation discarded: reason=signed_out, noteId=${pending.noteId}',
      );
      await clear();
      return;
    }

    final navigator = AppState.navigatorKey.currentState;
    final context = navigator?.context;
    if (navigator == null || context == null || !context.mounted) {
      await _log(
        'Reminder navigation waiting: reason=navigator_unavailable, noteId=${pending.noteId}',
      );
      return;
    }

    _opening = true;
    try {
      final note = await (noteLoaderOverride ?? Note.findById)(pending.noteId);
      if (note == null || note.trashed) {
        await _log(
          'Reminder navigation discarded: reason=${note == null ? 'missing' : 'trashed'}, noteId=${pending.noteId}',
        );
        await clear();
        return;
      }
      if (!context.mounted) return;
      if (note.locked && !note.unlocked) {
        final unlocked = await (unlockerOverride ?? showUnlockNoteDialog)(
          context,
          note,
        );
        if (unlocked != true) {
          await _log(
            'Reminder navigation discarded: reason=unlock_cancelled, noteId=${pending.noteId}',
          );
          await clear();
          return;
        }
      }
      if (!context.mounted) return;
      await clear();
      await _log('Reminder navigation opened: noteId=${note.id}');
      if (!context.mounted) return;
      await (routeOpenerOverride ?? _openEditor)(context, note);
    } on StateError catch (error, stackTrace) {
      await AppLogger.error(
        'Reminder navigation waiting: reason=database_unavailable, noteId=${pending.noteId}',
        error,
        stackTrace,
      );
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Reminder navigation failed: noteId=${pending.noteId}',
        error,
        stackTrace,
      );
    } finally {
      _opening = false;
      if (_pending != null) unawaited(flush());
    }
  }

  Future<void> clear() async {
    _pending = null;
    await _clearPersisted(await SharedPreferences.getInstance());
  }

  Future<void> clearForSignOut() async {
    await clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastActivationKey(prefs));
    await prefs.remove(_lastActivationAtKey(prefs));
  }

  Future<void> _clearPersisted(SharedPreferences prefs) async {
    await prefs.remove(_noteIdKey(prefs));
    await prefs.remove(_createdAtKey(prefs));
  }

  Future<void> _log(String message) {
    return (diagnosticsOverride ?? AppLogger.log)(message);
  }

  Future<void> _openEditor(BuildContext context, Note note) {
    final route = showPage(
      context,
      NoteEditor(note: note),
      allowFullScreen: true,
    );
    unawaited(_observeRoute(route, note.id));
    return Future<void>.value();
  }

  Future<void> _observeRoute(Future<dynamic> route, int? noteId) async {
    try {
      await route;
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Reminder navigation route failed: noteId=$noteId',
        error,
        stackTrace,
      );
    }
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    _readyHosts.clear();
    _pending = null;
    _opening = false;
    noteLoaderOverride = null;
    unlockerOverride = null;
    routeOpenerOverride = null;
    diagnosticsOverride = null;
    nowOverride = null;
    await clearForSignOut();
  }
}
