import 'dart:async';

import 'package:better_keep/services/external_sync/storage_access_cache.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _SecretStore store;
  setUp(() {
    store = _SecretStore();
  });
  SecureStorageAccessCache cache({
    String uid = 'account-a',
    String device = 'device',
    String library = 'library',
    String provider = 'google_drive',
    int generation = 1,
    bool persistent = true,
    bool Function()? current,
  }) => SecureStorageAccessCache(
    namespace: 'synthetic',
    uid: uid,
    deviceId: device,
    libraryId: library,
    provider: provider,
    generation: generation,
    persistent: persistent,
    storage: store,
    isCurrent: current ?? () => true,
  );

  test('secure cache keys isolate accounts, devices, libraries, providers and reconnects', () async {
    await cache().write({'accessToken': 'private'});
    expect(await cache().read(), {'accessToken': 'private'});
    for (final other in [
      cache(uid: 'account-b'),
      cache(device: 'other'),
      cache(library: 'rotated'),
      cache(provider: 'dropbox'),
      cache(generation: 2),
    ]) {
      expect(await other.read(), isNull);
    }
    expect(store.values.keys.single, isNot(contains('account-a')));
  });

  test(
    'memory-only mode never reads, writes or deletes persistent storage',
    () async {
      final client = cache(persistent: false);
      await client.write({'accessToken': 'private'});
      expect(await client.read(), isNull);
      await client.clear();
      expect(store.calls, 0);
    },
  );

  test('retirement during secure write removes the stale credential before replacement reads', () async {
    var current = true;
    final started = Completer<void>(), release = Completer<void>();
    store.beforeWrite = () async {
      started.complete();
      await release.future;
    };
    final old = cache(current: () => current);
    final write = old.write({'accessToken': 'old'});
    await started.future;
    current = false;
    final clear = old.clear();
    final replacement = cache();
    final read = replacement.read();
    release.complete();
    await Future.wait([write, clear]);
    expect(await read, isNull);
    store.beforeWrite = null;
    await replacement.write({'accessToken': 'new'});
    expect(await replacement.read(), {'accessToken': 'new'});
  });
}

/// In-memory keychain boundary only; these tests never access an OS keychain.
class _SecretStore implements FlutterSecureStorage {
  final values = <String, String>{};
  int calls = 0;
  Future<void> Function()? beforeWrite;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    final key = invocation.namedArguments[#key] as String;
    if (invocation.memberName == #read) {
      return Future<String?>.value(values[key]);
    }
    if (invocation.memberName == #delete) {
      return Future<void>.sync(() {
        values.remove(key);
      });
    }
    if (invocation.memberName == #write) {
      return (() async {
        await beforeWrite?.call();
        values[key] = invocation.namedArguments[#value] as String;
      })();
    }
    return super.noSuchMethod(invocation);
  }
}
