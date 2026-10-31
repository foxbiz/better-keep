import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../async_keyed_serializer.dart';
import 'sync_provider_adapter.dart';
import 'sync_replica_engine.dart';

class SyncConnectionProgress {
  const SyncConnectionProgress({
    this.running = false,
    this.lastSuccess,
    this.failure,
    this.retryAt,
    this.blockedEntities = 0,
    this.notesRequiringUnlock = 0,
    this.pendingLocalChanges = false,
  });

  final bool running;
  final DateTime? lastSuccess;
  final SyncProviderFailureKind? failure;
  final DateTime? retryAt;
  final int blockedEntities;
  final int notesRequiringUnlock;
  final bool pendingLocalChanges;
}

/// Foreground scheduling only. Provider failures have independent backoff;
/// edits arriving during a pass cause another pass after that one finishes.
/// The owning account must retire adapters and drain work before closing its DB.
class SyncScheduler extends ChangeNotifier {
  SyncScheduler({
    required this.sync,
    required this.isCurrent,
    this.blockedEntities,
    this.notesRequiringUnlock,
    this.pendingLocalChanges,
    this.loadLastSuccess,
    this.saveLastSuccess,
    DateTime Function()? now,
    this.saveDebounce = const Duration(seconds: 2),
    this._automatic = true,
    this._foreground = true,
  }) : now = now ?? DateTime.now;

  final Future<void> Function(SyncProviderAdapter) sync;
  final bool Function() isCurrent;
  final int Function()? blockedEntities;
  final int Function()? notesRequiringUnlock;
  final bool Function()? pendingLocalChanges;
  final Future<DateTime?> Function(String connectionId)? loadLastSuccess;
  final Future<void> Function(String connectionId, DateTime time)?
  saveLastSuccess;
  final DateTime Function() now;
  final Duration saveDebounce;
  final _entries = <String, _ScheduledConnection>{};
  final _tasks = <Future<void>>{};
  final _serial = AsyncKeyedSerializer<String>();
  Timer? _save;
  bool _automatic;
  bool _foreground, _disposed = false;

  bool get _active => !_disposed && isCurrent();
  Map<String, SyncConnectionProgress> get progress => Map.unmodifiable({
    for (final entry in _entries.values)
      entry.adapter.connectionId: entry.progress,
  });

  bool _owns(_ScheduledConnection entry) =>
      _active && identical(_entries[entry.adapter.connectionId], entry);

  void setAdapters(Iterable<SyncProviderAdapter> adapters) {
    if (!_active) return;
    final next = {
      for (final adapter in adapters) adapter.connectionId: adapter,
    };
    _entries.removeWhere((id, entry) {
      final removed = !identical(next[id], entry.adapter);
      if (removed) entry.retry?.cancel();
      return removed;
    });
    for (final adapter in next.values) {
      if (_entries.containsKey(adapter.connectionId)) continue;
      final entry = _ScheduledConnection(adapter);
      _entries[adapter.connectionId] = entry;
      if (_automatic) unawaited(_request(entry));
    }
    notifyListeners();
  }

  void localChanged() {
    if (!_active || !_foreground) return;
    for (final entry in _entries.values) {
      final previous = entry.progress;
      entry.progress = SyncConnectionProgress(
        running: previous.running,
        lastSuccess: previous.lastSuccess,
        failure: previous.failure,
        retryAt: previous.retryAt,
        blockedEntities: previous.blockedEntities,
        notesRequiringUnlock: previous.notesRequiringUnlock,
        pendingLocalChanges: true,
      );
    }
    notifyListeners();
    if (!_automatic) return;
    _save?.cancel();
    _save = Timer(saveDebounce, () {
      unawaited(_requestAll());
    });
  }

  void setAutomatic(bool enabled) {
    if (!_active || enabled == _automatic) return;
    _automatic = enabled;
    _cancelTimers();
    if (enabled && _foreground) unawaited(_requestAll());
  }

  void setForeground(bool foreground) {
    if (!_active || foreground == _foreground) return;
    _foreground = foreground;
    _cancelTimers();
    if (foreground && _automatic) unawaited(_requestAll());
  }

  void _cancelTimers() {
    _save?.cancel();
    for (final entry in _entries.values) {
      entry.retry?.cancel();
    }
  }

  /// Firebase notifications are hints; the provider remains the source of data.
  /// Coalesces notifications received during a pass and respects provider backoff.
  void remoteChanged(String connectionId) {
    if (!_active || !_automatic || !_foreground) return;
    final entry = _entries[connectionId];
    if (entry != null) unawaited(_request(entry));
  }

  /// Explicit retry bypasses an earlier transient backoff, once.
  Future<void> syncNow({String? connectionId}) async {
    if (!_active || !_foreground) return;
    _save?.cancel();
    final entries = connectionId == null
        ? _entries.values.toList()
        : [?_entries[connectionId]];
    await Future.wait(entries.map((entry) => _request(entry, force: true)));
  }

  Future<void> _requestAll() =>
      Future.wait(_entries.values.toList().map(_request));

  Future<void> _request(_ScheduledConnection entry, {bool force = false}) {
    if (!_owns(entry) || !_foreground || (!force && !_automatic)) {
      return Future.value();
    }
    // Consent requires a user gesture. Authorization replaces the adapter and
    // starts it again; polling cannot resolve this state.
    if (entry.progress.failure == SyncProviderFailureKind.sharedSetupRequired) {
      return Future.value();
    }
    if (!force &&
        const {
          SyncProviderFailureKind.corruptData,
          SyncProviderFailureKind.quotaExceeded,
        }.contains(entry.progress.failure)) {
      return Future.value();
    }
    if (entry.running != null) {
      entry.again = true;
      entry.forceAgain |= force;
      return entry.running!;
    }
    if (!force && (entry.progress.retryAt?.isAfter(now()) ?? false)) {
      _scheduleRetry(entry);
      return Future.value();
    }
    entry.retry?.cancel();
    // Retiring and replacing an adapter with the same replica ID must not
    // coalesce into the engine's still-running old adapter operation.
    late final Future<void> task;
    task = _serial
        .run(entry.adapter.connectionId, () => _run(entry))
        .whenComplete(() {
          entry.running = null;
          _tasks.remove(task);
        });
    entry.running = task;
    _tasks.add(task);
    return task;
  }

  Future<void> _run(_ScheduledConnection entry) async {
    do {
      if (!_owns(entry) || !_foreground) return;
      entry.again = entry.forceAgain = false;
      final previous = entry.progress;
      var lastSuccess = previous.lastSuccess;
      entry.progress = SyncConnectionProgress(
        running: true,
        lastSuccess: previous.lastSuccess,
        failure: previous.failure,
        blockedEntities: previous.blockedEntities,
        notesRequiringUnlock: previous.notesRequiringUnlock,
        pendingLocalChanges: previous.pendingLocalChanges,
      );
      notifyListeners();
      try {
        if (!_owns(entry)) return;
        lastSuccess ??= await loadLastSuccess?.call(entry.adapter.connectionId);
        if (!_owns(entry)) return;
        await sync(entry.adapter);
        if (!_owns(entry)) return;
        final blocked = blockedEntities?.call() ?? 0;
        final pending = pendingLocalChanges?.call() ?? false;
        if (blocked == 0 && !pending) {
          final clock = now();
          final success = lastSuccess != null && lastSuccess.isAfter(clock)
              ? lastSuccess
              : clock;
          await saveLastSuccess?.call(entry.adapter.connectionId, success);
          if (!_owns(entry)) return;
          lastSuccess = success;
        }
        entry.failures = 0;
        entry.progress = SyncConnectionProgress(
          lastSuccess: lastSuccess,
          blockedEntities: blocked,
          notesRequiringUnlock: notesRequiringUnlock?.call() ?? 0,
          pendingLocalChanges: pending,
        );
      } on SyncReplicaCancelled {
        if (!_owns(entry)) return;
        entry.progress = SyncConnectionProgress(lastSuccess: lastSuccess);
      } catch (error) {
        if (!_owns(entry)) return;
        entry.failures++;
        final delay = Duration(
          seconds: math.min(300, 5 * (1 << math.min(6, entry.failures - 1))),
        );
        final retry = error is SyncProviderFailure ? error.retryAfter : null;
        final failure = error is SyncProviderFailure
            ? error.kind
            : error is FormatException
            ? SyncProviderFailureKind.corruptData
            : SyncProviderFailureKind.unavailable;
        entry.progress = SyncConnectionProgress(
          lastSuccess: lastSuccess,
          failure: failure,
          retryAt:
              failure == SyncProviderFailureKind.sharedSetupRequired ||
                  failure == SyncProviderFailureKind.corruptData ||
                  failure == SyncProviderFailureKind.quotaExceeded
              ? null
              : now().add(retry != null && retry > delay ? retry : delay),
          blockedEntities: blockedEntities?.call() ?? 0,
          notesRequiringUnlock: notesRequiringUnlock?.call() ?? 0,
          pendingLocalChanges: pendingLocalChanges?.call() ?? false,
        );
      }
      notifyListeners();
      _scheduleRetry(entry);
    } while (entry.again &&
        (_automatic || entry.forceAgain) &&
        entry.progress.failure != SyncProviderFailureKind.sharedSetupRequired &&
        (entry.forceAgain ||
            (entry.progress.failure != SyncProviderFailureKind.corruptData &&
                entry.progress.failure !=
                    SyncProviderFailureKind.quotaExceeded &&
                !(entry.progress.retryAt?.isAfter(now()) ?? false))));
  }

  void _scheduleRetry(_ScheduledConnection entry) {
    entry.retry?.cancel();
    final retryAt = entry.progress.retryAt;
    if (!_owns(entry) || !_foreground || !_automatic || retryAt == null) return;
    final delay = retryAt.difference(now());
    entry.retry = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(_request(entry));
    });
  }

  Future<void> waitForIdle() async {
    while (_tasks.isNotEmpty) {
      await Future.wait(_tasks.toList());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    _entries.clear();
    super.dispose();
  }
}

class _ScheduledConnection {
  _ScheduledConnection(this.adapter);
  final SyncProviderAdapter adapter;
  SyncConnectionProgress progress = const SyncConnectionProgress();
  Future<void>? running;
  Timer? retry;
  int failures = 0;
  bool again = false, forceAgain = false;
}
