import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/sync_change_signals.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

const connection = StorageConnection(
  provider: 'webdav',
  libraryId: 'library',
  accountLabel: '',
  encryptedCapability: '',
  generation: 1,
  enabled: true,
  state: 'ready',
);

void main() {
  for (final receiving in [true, false]) {
    testWidgets(
      'refreshes stale claims before retrying ${receiving ? "a listener" : "a pending notification"}',
      (tester) async {
        var freshClaims = false;
        var refreshes = 0, changes = 0, writes = 0;
        final store = _Store()..token = receiving ? null : 'pending';
        final denied = FirebaseException(
          plugin: 'firestore',
          code: 'permission-denied',
        );
        final signals = SyncChangeSignals(
          deviceId: 'local',
          store: store,
          isCurrent: () => true,
          watch: (_) {
            if (!receiving) return const Stream.empty();
            if (!freshClaims) return Stream.error(denied);
            return Stream.value({
              'libraryId': connection.libraryId,
              'generation': connection.generation,
              'storageEpoch': connection.storageEpoch,
              'deviceId': 'remote',
              'token': 'remote-change',
            });
          },
          publish: (_, _) async {
            if (!freshClaims) throw denied;
            writes++;
          },
          refreshAuthorization: () async {
            refreshes++;
            freshClaims = true;
          },
          onRemoteChange: (_) => changes++,
        );
        addTearDown(signals.dispose);
        signals.setConnections([connection]);
        await tester.pump();
        await tester.pump(const Duration(seconds: 15));
        await tester.pump(const Duration(minutes: 1));
        await tester.pump(const Duration(seconds: 15));
        expect(refreshes, 1);
        expect(changes, receiving ? 1 : 0);
        expect(writes, receiving ? 0 : 1);
        expect(store.token, isNull);
        await tester.pump(const Duration(hours: 1));
        expect(refreshes, 1);
        signals.dispose();
      },
    );
  }

  testWidgets(
    'permission failures stop retrying and resume with a fresh session',
    (tester) async {
      var listens = 0, writes = 0, refreshes = 0;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: _Store()..token = 'pending',
        isCurrent: () => true,
        watch: (_) {
          listens++;
          return Stream.error(
            FirebaseException(plugin: 'firestore', code: 'permission-denied'),
          );
        },
        publish: (_, _) async {
          writes++;
          throw FirebaseException(
            plugin: 'firestore',
            code: 'permission-denied',
          );
        },
        onRemoteChange: (_) {},
        refreshAuthorization: () async {
          refreshes++;
          throw StateError('Token refresh unavailable');
        },
      );
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      expect(listens, 3);
      expect(writes, 3);
      expect(refreshes, inInclusiveRange(2, 4));
      signals.setConnections([]);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      expect(listens, 4);
      expect(writes, 4);
      signals.dispose();
    },
  );

  for (final code in ['invalid-argument', 'failed-precondition', 'data-loss']) {
    testWidgets('terminal $code keeps the hint without retry polling', (
      tester,
    ) async {
      final store = _Store()..token = 'pending';
      var writes = 0;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: store,
        isCurrent: () => true,
        watch: (_) => const Stream.empty(),
        onRemoteChange: (_) {},
        publish: (_, _) async {
          writes++;
          throw FirebaseException(plugin: 'firestore', code: code);
        },
      );
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      expect(writes, 1);
      expect(store.token, 'pending');
      signals.setConnections([]);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      expect(writes, 2);
    });
  }

  for (final code in [
    'unavailable',
    'resource-exhausted',
    'internal',
    'non-firebase',
  ]) {
    testWidgets('transient $code backs off, caps delay and resets on success', (
      tester,
    ) async {
      final store = _Store()..token = 'pending';
      var writes = 0, fail = true;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: store,
        isCurrent: () => true,
        watch: (_) => const Stream.empty(),
        onRemoteChange: (_) {},
        publish: (_, _) async {
          writes++;
          if (fail) {
            if (code == 'non-firebase') {
              throw StateError('temporary fixture failure');
            }
            throw FirebaseException(plugin: 'firestore', code: code);
          }
        },
      );
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      expect(writes, 1);
      for (final seconds in [30, 60, 120, 240, 300, 300]) {
        final before = writes;
        await tester.pump(Duration(seconds: seconds - 1));
        expect(writes, before);
        expect(store.token, 'pending');
        await tester.pump(const Duration(seconds: 1));
        expect(writes, before + 1);
      }
      fail = false;
      await tester.pump(const Duration(minutes: 5));
      expect(store.token, isNull);
      final before = writes;
      store.token = 'next';
      signals.published(connection.replicaId);
      await tester.pump(const Duration(seconds: 15));
      expect(writes, before + 1);
      expect(store.token, isNull);
    });
  }

  testWidgets('retiring during token refresh cannot restart a listener', (
    tester,
  ) async {
    final release = Completer<void>();
    var listens = 0, refreshes = 0;
    final signals = SyncChangeSignals(
      deviceId: 'local',
      store: _Store(),
      isCurrent: () => true,
      watch: (_) {
        listens++;
        return Stream.error(
          FirebaseException(plugin: 'firestore', code: 'unauthenticated'),
        );
      },
      publish: (_, _) async {},
      onRemoteChange: (_) => fail('Retired session must not receive changes'),
      refreshAuthorization: () {
        refreshes++;
        return release.future;
      },
    );
    addTearDown(signals.dispose);
    signals.setConnections([connection]);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 1);
    signals.dispose();
    release.complete();
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(listens, 1);
  });

  testWidgets('batches committed changes without sending idle notifications', (
    tester,
  ) async {
    final store = _Store();
    final stream = StreamController<Map<String, dynamic>?>.broadcast();
    final sent = <String>[];
    final signals = SyncChangeSignals(
      deviceId: 'local',
      store: store,
      isCurrent: () => true,
      watch: (_) => stream.stream,
      publish: (_, token) async {
        sent.add(token);
      },
      onRemoteChange: (_) => fail('Local updates must not echo'),
    );
    addTearDown(stream.close);
    addTearDown(signals.dispose);
    signals.setConnections([connection]);
    await tester.pump(const Duration(minutes: 1));
    expect(sent, isEmpty);
    store.token = 'first';
    signals.published(connection.replicaId);
    store.token = 'second';
    signals.published(connection.replicaId);
    await tester.pump(const Duration(seconds: 15));
    expect(sent, ['second']);
    expect(store.token, isNull);
    await tester.pump(const Duration(hours: 1));
    expect(sent, ['second']);
    signals.dispose();
  });

  testWidgets(
    'filters own, duplicate, stale generation and foreign library hints',
    (tester) async {
      final stream = StreamController<Map<String, dynamic>?>.broadcast();
      var changes = 0;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: _Store(),
        isCurrent: () => true,
        watch: (_) => stream.stream,
        publish: (_, _) async {},
        onRemoteChange: (id) {
          expectSync(id, connection.replicaId);
          changes++;
        },
      );
      addTearDown(stream.close);
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      final data = <String, dynamic>{
        'libraryId': 'library',
        'generation': 1,
        'storageEpoch': '',
        'deviceId': 'remote',
        'token': 'a',
      };
      stream.add({...data, 'deviceId': 'local'});
      stream.add({...data, 'generation': 2});
      stream.add({...data, 'libraryId': 'other'});
      stream.add({...data, 'storageEpoch': 'cleared'});
      stream.add(data);
      stream.add(data);
      await tester.pump();
      expect(changes, 1);
      signals.setConnections([]);
      stream.add({...data, 'token': 'b'});
      await tester.pump();
      expect(changes, 1);
      signals.dispose();
    },
  );

  testWidgets(
    'retries durable hints and preserves a newer commit during publish',
    (tester) async {
      final store = _Store()..token = 'first';
      final release = Completer<void>();
      var writes = 0;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: store,
        isCurrent: () => true,
        watch: (_) => const Stream.empty(),
        onRemoteChange: (_) {},
        publish: (_, token) async {
          writes++;
          if (writes == 1) throw StateError('offline');
          if (writes == 2) await release.future;
        },
      );
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      expect(store.token, 'first');
      await tester.pump(const Duration(seconds: 30));
      expect(writes, 2);
      store.token = 'newer';
      release.complete();
      await tester.pump();
      expect(store.token, 'newer');
      await tester.pump(const Duration(seconds: 15));
      expect(store.token, isNull);
      expect(writes, 3);
      signals.dispose();
    },
  );

  testWidgets(
    'offline writes are not repeatedly enqueued and retirement keeps the outbox',
    (tester) async {
      final store = _Store()..token = 'pending';
      final release = Completer<void>();
      var writes = 0;
      var current = true;
      final signals = SyncChangeSignals(
        deviceId: 'local',
        store: store,
        isCurrent: () => current,
        watch: (_) => const Stream.empty(),
        onRemoteChange: (_) {},
        publish: (_, _) {
          writes++;
          return release.future;
        },
      );
      addTearDown(signals.dispose);
      signals.setConnections([connection]);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 15));
      expect(writes, 1);
      current = false;
      signals.dispose();
      release.complete();
      await tester.pump();
      await signals.waitForIdle();
      expect(store.token, 'pending');
    },
  );
}

class _Store extends SyncReplicaStore {
  _Store() : super(_UnusedDatabase(), scope: 'test');
  String? token;
  @override
  Future<String?> pendingSignal(String connectionId) async => token;
  @override
  Future<void> acknowledgeSignal(String connectionId, String sent) async {
    if (token == sent) token = null;
  }
}

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
