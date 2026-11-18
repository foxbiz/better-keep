import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../firebase_backend.dart';
import 'storage_connection.dart';
import 'sync_replica_store.dart';

/// One small, rate-limited hint per provider, never note data or credentials.
/// Provider cursors still determine what changed. Resume/manual sync reconcile
/// even when a hint was missed or another client does not publish hints yet.
class SyncChangeSignals {
  SyncChangeSignals({
    required this.deviceId,
    required this.store,
    required this.isCurrent,
    required this.watch,
    required this.publish,
    required this.onRemoteChange,
    this.refreshAuthorization,
    this.batchDelay = const Duration(seconds: 15),
  });

  factory SyncChangeSignals.firebase({
    required String uid,
    required String deviceId,
    required SyncReplicaStore store,
    required bool Function() isCurrent,
    required void Function(String) onRemoteChange,
    FirebaseFirestore? firestore,
  }) {
    final collection = (firestore ?? FirebaseBackend.firestore)
        .collection('users')
        .doc(uid)
        .collection('storage_sync_signals');
    return SyncChangeSignals(
      deviceId: deviceId,
      store: store,
      isCurrent: isCurrent,
      onRemoteChange: onRemoteChange,
      refreshAuthorization: () async {
        if (!isCurrent()) return;
        final user = FirebaseBackend.auth.currentUser;
        if (user != null && user.uid == uid) await user.getIdToken(true);
      },
      watch: (connection) => collection
          .doc(connection.provider)
          .snapshots()
          .where(
            (snapshot) =>
                !snapshot.metadata.hasPendingWrites &&
                !snapshot.metadata.isFromCache,
          )
          .map((snapshot) => snapshot.data()),
      publish: (connection, token) => collection.doc(connection.provider).set({
        'libraryId': connection.libraryId,
        'generation': connection.generation,
        'storageEpoch': connection.storageEpoch,
        'deviceId': deviceId,
        'token': token,
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  final String deviceId;
  final SyncReplicaStore store;
  final bool Function() isCurrent;
  final Stream<Map<String, dynamic>?> Function(StorageConnection) watch;
  final Future<void> Function(StorageConnection, String token) publish;
  final void Function(String connectionId) onRemoteChange;
  final Future<void> Function()? refreshAuthorization;
  final Duration batchDelay;
  final _entries = <String, _SignalEntry>{};
  final _tasks = <Future<void>>{};
  bool _disposed = false;
  Future<void>? _authorizationRefresh;

  bool _owns(_SignalEntry entry) =>
      !_disposed &&
      isCurrent() &&
      identical(_entries[entry.connection.replicaId], entry);

  /// Call with an empty list while backgrounded or without automatic access.
  void setConnections(Iterable<StorageConnection> connections) {
    if (_disposed || !isCurrent()) return;
    final next = {for (final c in connections) c.replicaId: c};
    _entries.removeWhere((id, entry) {
      if (next[id]?.libraryId == entry.connection.libraryId) return false;
      entry.close();
      return true;
    });
    for (final c in next.values) {
      if (_entries.containsKey(c.replicaId)) continue;
      final entry = _SignalEntry(c);
      _entries[c.replicaId] = entry;
      _listen(entry);
      // Retry durable notifications left by a previous process/session.
      _schedule(entry);
    }
  }

  void _listen(_SignalEntry entry) {
    if (!_owns(entry)) return;
    entry.subscription = watch(entry.connection).listen(
      (data) {
        if (!_owns(entry)) return;
        entry.listenFailures = 0;
        if (data == null) return;
        final c = entry.connection;
        if (data['libraryId'] != c.libraryId ||
            data['generation'] != c.generation ||
            data['storageEpoch'] != c.storageEpoch ||
            data['deviceId'] == deviceId ||
            data['token'] is! String ||
            data['token'] == entry.lastToken) {
          return;
        }
        entry.lastToken = data['token'] as String;
        onRemoteChange(c.replicaId);
      },
      onError: (Object error) {
        if (!_owns(entry)) return;
        // Permission can lag a purchase's token refresh. Retry with a bound;
        // Firebase handles ordinary network reconnects on its own.
        unawaited(entry.subscription?.cancel());
        entry.listenRetry?.cancel();
        final permissionFailure = _permissionFailure(error);
        if (permissionFailure && ++entry.listenFailures >= 3) return;
        entry.listenRetry = Timer(const Duration(minutes: 1), () async {
          if (permissionFailure) await _refreshAuthorization(entry);
          _listen(entry);
        });
      },
    );
  }

  static bool _permissionFailure(Object error) =>
      error is FirebaseException &&
      (error.code == 'permission-denied' || error.code == 'unauthenticated');

  // Subscription documents can arrive before the server updates claims. A
  // delayed retry must obtain a new token instead of reusing the rejected one.
  Future<void> _refreshAuthorization(_SignalEntry entry) async {
    if (!_owns(entry) || refreshAuthorization == null) return;
    final pending = _authorizationRefresh;
    if (pending != null) return pending;
    final refresh = Future<void>.sync(refreshAuthorization!)
        .timeout(const Duration(seconds: 10))
        .catchError((Object _) {});
    _authorizationRefresh = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_authorizationRefresh, refresh)) {
        _authorizationRefresh = null;
      }
    }
  }

  void published(String connectionId) {
    final entry = _entries[connectionId];
    if (entry != null) _schedule(entry);
  }

  void _schedule(_SignalEntry entry) {
    if (!_owns(entry) ||
        entry.timer?.isActive == true ||
        entry.writeFailures >= 3) {
      return;
    }
    final delay = Duration(
      microseconds: (batchDelay.inMicroseconds * (1 << entry.transientFailures))
          .clamp(0, const Duration(minutes: 5).inMicroseconds),
    );
    entry.timer = Timer(delay, () {
      if (!_owns(entry)) return;
      if (entry.running) {
        _schedule(entry);
        return;
      }
      late final Future<void> task;
      task = _flush(entry).whenComplete(() => _tasks.remove(task));
      _tasks.add(task);
    });
  }

  Future<void> _flush(_SignalEntry entry) async {
    entry.running = true;
    try {
      final pendingToken = await store.pendingSignal(
        entry.connection.replicaId,
      );
      final token = entry.write?.$1 ?? pendingToken;
      if (!_owns(entry) || token == null) return;
      final write = entry.write ??= (token, publish(entry.connection, token));
      try {
        await write.$2.timeout(const Duration(seconds: 10));
        entry.write = null;
      } on TimeoutException {
        // Keep the same in-flight write instead of queuing another offline
        // Firestore write every time the timeout fires.
        rethrow;
      } catch (_) {
        entry.write = null;
        rethrow;
      }
      if (!_owns(entry)) return;
      entry.writeFailures = 0;
      await store.acknowledgeSignal(entry.connection.replicaId, token);
      entry.transientFailures = 0;
      if (_owns(entry) &&
          await store.pendingSignal(entry.connection.replicaId) != null) {
        _schedule(entry);
      }
    } catch (error) {
      if (error is FirebaseException &&
          const {
            'invalid-argument',
            'failed-precondition',
            'not-found',
            'unimplemented',
            'data-loss',
          }.contains(error.code)) {
        // Keep the durable hint for a repaired/new session, without polling a
        // terminal failure. Provider uploads remain successful.
        entry.writeFailures = 3;
      } else if (_permissionFailure(error)) {
        entry.writeFailures++;
        if (entry.writeFailures < 3) await _refreshAuthorization(entry);
      } else {
        entry.transientFailures = (entry.transientFailures + 1).clamp(0, 5);
      }
      // Notification failures never turn a successful provider upload into a
      // failed sync. The outbox survives, and retries remain bounded.
      _schedule(entry);
    } finally {
      entry.running = false;
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.close();
    }
    _entries.clear();
  }

  Future<void> waitForIdle() async {
    while (_tasks.isNotEmpty) {
      await Future.wait(_tasks.toList());
    }
  }
}

class _SignalEntry {
  _SignalEntry(this.connection);
  final StorageConnection connection;
  StreamSubscription<Map<String, dynamic>?>? subscription;
  Timer? timer, listenRetry;
  String? lastToken;
  bool running = false;
  int listenFailures = 0, writeFailures = 0, transientFailures = 0;
  (String, Future<void>)? write;

  void close() {
    timer?.cancel();
    listenRetry?.cancel();
    unawaited(subscription?.cancel());
  }
}
