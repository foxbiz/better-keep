import 'dart:async';
import 'dart:io';

import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:better_keep/services/retry_controller.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

enum CloudSessionState { pending, ready, unavailable, blocked }

enum CloudRecoveryActivity { idle, verifying, resuming }

enum SyncRefreshOutcome {
  complete,
  uploadRestricted,
  unavailable,
  deferred,
  failed,
}

/// A remote read supplied no authoritative result (for example a cache miss).
class CloudVerificationUnavailable implements Exception {
  const CloudVerificationUnavailable();
}

/// A superseded account/operation must not publish or acknowledge its results.
class CloudOperationCancelled implements Exception {
  const CloudOperationCancelled();
}

void requireCurrentSession(bool Function() isCurrent) {
  if (!isCurrent()) throw const CloudOperationCancelled();
}

SyncRefreshOutcome combineSyncRefreshOutcomes(
  Iterable<SyncRefreshOutcome> outcomes,
) {
  // A real content/storage failure must not be hidden by another offline task.
  for (final outcome in [
    SyncRefreshOutcome.failed,
    SyncRefreshOutcome.unavailable,
    SyncRefreshOutcome.deferred,
    SyncRefreshOutcome.uploadRestricted,
  ]) {
    if (outcomes.contains(outcome)) return outcome;
  }
  return SyncRefreshOutcome.complete;
}

bool isCloudConnectionFailure(Object error) {
  if (error is FirestoreDocumentFetchException) {
    return isCloudConnectionFailure(error.cause);
  }
  return error is CloudVerificationUnavailable ||
      error is TimeoutException ||
      error is SocketException ||
      (error is FirebaseException &&
          const {
            'network-request-failed',
            'unavailable',
            'deadline-exceeded',
            'retry-limit-exceeded',
          }.contains(error.code));
}

/// Owns one account's bounded cloud verification and foreground recovery.
/// Local storage and navigation never wait for this controller.
class CloudSessionRecovery {
  CloudSessionRecovery({
    required this.verify,
    required this.onReady,
    required this.onFailure,
    this.timeout = const Duration(seconds: 10),
  });

  final Future<CloudSessionState> Function(bool Function() isCurrent) verify;
  final Future<void> Function(bool Function() isCurrent) onReady;
  final void Function(Object, StackTrace) onFailure;
  final Duration timeout;
  final state = ValueNotifier(CloudSessionState.pending);
  final activity = ValueNotifier(CloudRecoveryActivity.idle);
  final sessionRevision = ValueNotifier(0);
  bool get hasSession => _uid != null;
  final _retry = ExponentialBackoffRetryController(
    delayForAttempt: (attempt) =>
        Duration(seconds: const [5, 15, 30, 60][attempt.clamp(0, 3)]),
  );
  String? _uid;
  int _generation = 0;
  int _accountGeneration = 0;
  bool _foreground = true;
  Future<CloudSessionState>? _running;
  Future<void>? _resuming;
  bool _needsResume = true;

  bool Function() captureSession() {
    final generation = _accountGeneration;
    final uid = _uid;
    return () => uid != null && uid == _uid && generation == _accountGeneration;
  }

  void start(String uid) {
    if (_uid == uid) return;
    stop();
    _uid = uid;
    state.value = CloudSessionState.pending;
  }

  Future<CloudSessionState> check() {
    if (_uid == null) return Future.value(CloudSessionState.blocked);
    final running = _running;
    if (running != null) return running;
    final generation = ++_generation;
    var active = true;
    bool isCurrent() => active && generation == _generation && _uid != null;
    activity.value = CloudRecoveryActivity.verifying;
    late final Future<CloudSessionState> operation;
    operation = (() async {
      try {
        final result = await verify(isCurrent).timeout(timeout);
        if (!isCurrent()) return CloudSessionState.pending;
        state.value = result;
        if (result == CloudSessionState.ready) {
          _resumeServices();
        } else if (result == CloudSessionState.unavailable ||
            result == CloudSessionState.pending) {
          _needsResume = true;
          _schedule();
        }
        return result;
      } catch (error, stack) {
        if (!isCurrent()) return CloudSessionState.pending;
        onFailure(error, stack);
        state.value = isCloudConnectionFailure(error)
            ? CloudSessionState.unavailable
            : CloudSessionState.blocked;
        if (state.value == CloudSessionState.unavailable) {
          _needsResume = true;
          _schedule();
        }
        return state.value;
      } finally {
        active = false;
        if (identical(_running, operation)) {
          _running = null;
          _updateActivity();
        }
      }
    })();
    _running = operation;
    return operation;
  }

  void connectionLost() {
    if (_uid == null || state.value == CloudSessionState.blocked) return;
    _needsResume = true;
    state.value = CloudSessionState.unavailable;
    _updateActivity();
    _schedule();
  }

  void _resumeServices() {
    if (!_needsResume) {
      _retry.succeeded();
      return;
    }
    if (_resuming != null) return;
    _needsResume = false;
    activity.value = CloudRecoveryActivity.resuming;
    final isCurrent = captureSession();
    late final Future<void> operation;
    operation = Future<void>.sync(() => onReady(isCurrent))
        .catchError((Object error, StackTrace stack) {
          if (!isCurrent()) return;
          _needsResume = true;
          // A cancelled partial restart is still unfinished for this account.
          // whenComplete schedules the next coalesced recovery attempt.
          if (error is CloudOperationCancelled) return;
          onFailure(error, stack);
          if (isCloudConnectionFailure(error)) {
            connectionLost();
          } else {
            _schedule();
          }
        })
        .whenComplete(() {
          if (!identical(_resuming, operation)) return;
          _resuming = null;
          _updateActivity();
          if (isCurrent()) {
            if (_needsResume) {
              _schedule();
            } else {
              _retry.succeeded();
            }
          }
        });
    _resuming = operation;
  }

  void _updateActivity() {
    activity.value = _running != null
        ? CloudRecoveryActivity.verifying
        : _resuming != null && state.value == CloudSessionState.ready
        ? CloudRecoveryActivity.resuming
        : CloudRecoveryActivity.idle;
  }

  void _schedule() {
    if (_foreground && _uid != null) _retry.schedule(check);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) {
      _retry.cancel();
    } else if (_uid != null) {
      unawaited(check());
    }
  }

  void stop() {
    _generation++;
    _accountGeneration++;
    _uid = null;
    _running = null;
    _resuming = null;
    _needsResume = true;
    _retry.cancel();
    state.value = CloudSessionState.pending;
    activity.value = CloudRecoveryActivity.idle;
    sessionRevision.value++;
  }
}
