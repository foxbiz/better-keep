import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/storage_credential_broker.dart';
import 'package:better_keep/services/external_sync/storage_access_cache.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/storage_authorization.dart';

void main() {
  late SyncCipher cipher;
  late StorageConnection connection;
  late FakeStorageAuthorization authorization;
  late String capability;
  late Map<String, dynamic> record;
  late List<Map<String, dynamic>> writes;
  late bool current;
  late int reads;
  final clock = DateTime.fromMillisecondsSinceEpoch(1000);
  Map<String, dynamic> grant(String token, {int expiry = 1000000}) => {
    'type': 'oauth',
    'grant': 'test',
    'clientId': 'client',
    'accountId': 'account',
    'accessToken': token,
    'expiresAt': expiry,
    'refreshToken': 'private-refresh-token',
  };
  Future<Map<String, dynamic>> envelope(
    Map<String, dynamic> credentials, {
    int revision = 1,
  }) async => {
    'generation': 1,
    'clientId': connection.clientId,
    'revision': revision,
    'encryptedCredentials': await cipher.encryptCredentials(
      provider: connection.provider,
      generation: 1,
      clientId: connection.clientId,
      credentials: credentials,
    ),
  };
  setUp(() async {
    cipher = await SyncCipher.create('user', Uint8List(32));
    capability = SyncCipher.newCapability();
    connection = StorageConnection(
      provider: 'google_drive',
      libraryId: cipher.libraryId,
      clientId: 'client',
      accountLabel: '',
      encryptedCapability: await cipher.encryptCapability(
        'google_drive',
        capability,
      ),
      generation: 1,
      enabled: true,
      state: 'ready',
    );
    authorization = FakeStorageAuthorization();
    current = true;
    reads = 0;
    writes = [];
    record = await envelope(grant('private-access-token'));
  });
  tearDown(() => cipher.dispose());
  Future<dynamic> call(String name, Map<String, dynamic> data) async {
    expect(jsonEncode(data), isNot(contains('private-access-token')));
    expect(jsonEncode(data), isNot(contains('private-refresh-token')));
    expect(data['capability'], capability);
    switch (name) {
      case 'getEncryptedStorageCredentials':
        reads++;
        return record;
      case 'acquireStorageRefreshLease':
        return {
          ...record,
          'status': 'acquired',
          'leaseId': 'lease',
          'fence': 1,
        };
      case 'finishStorageRefresh':
        writes.add(data);
        record = {
          ...record,
          'revision': 2,
          'encryptedCredentials': data['encryptedCredentials'],
        };
        return {'revision': 2};
      case 'releaseStorageRefreshLease':
        return {'success': true};
    }
    throw StateError('Unexpected backend operation');
  }

  StorageCredentialBroker broker({
    StorageBrokerCall? invoke,
    StorageAccessCache? cache,
  }) => StorageCredentialBroker(
    connection: connection,
    cipher: cipher,
    deviceId: 'device',
    call: invoke ?? call,
    isCurrent: () => current,
    now: () => clock,
    authorization: authorization,
    cache: cache,
  );

  test(
    'invalid encrypted credentials require reconnect without token refresh',
    () async {
      record['encryptedCredentials'] = 'invalid envelope';
      final client = broker();
      addTearDown(client.dispose);
      await expectLater(
        client.accessToken(),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
      expect(authorization.refreshes, 0);
      expect(writes, isEmpty);
    },
  );

  test(
    'decrypts locally; coalesces requests and caches valid tokens',
    () async {
      final client = broker();
      expect(await Future.wait([client.accessToken(), client.accessToken()]), [
        'private-access-token',
        'private-access-token',
      ]);
      expect(reads, 1);
      expect(authorization.refreshes, 0);
      client.dispose();
    },
  );
  test('rejected token refreshes on device and only encrypted rotation reaches Firebase', () async {
    authorization.refreshGrant = (value, rejected) async {
      expect(rejected, 'private-access-token');
      return {...grant('new-access'), 'refreshToken': 'new-private-refresh'};
    };
    final client = broker();
    await client.accessToken();
    expect(
      await client.accessToken(rejectedToken: 'private-access-token'),
      'new-access',
    );
    expect(authorization.refreshes, 1);
    expect(writes, hasLength(1));
    expect(jsonEncode(writes), isNot(contains('new-private-refresh')));
    expect(
      (await cipher.decryptCredentials(
        provider: 'google_drive',
        generation: 1,
        clientId: 'client',
        encrypted: record['encryptedCredentials'],
      ))['refreshToken'],
      'new-private-refresh',
    );
    client.dispose();
  });
  test(
    'uses another device refresh instead of refreshing the rotated token again',
    () async {
      record = await envelope(grant('expired', expiry: 900));
      final changed = await envelope(grant('other-device-token'), revision: 2);
      final cache = _MemoryAccessCache();
      final client = broker(
        cache: cache,
        invoke: (name, data) async {
          if (name == 'acquireStorageRefreshLease') {
            return {...changed, 'status': 'changed'};
          }
          return await call(name, data);
        },
      );
      expect(await client.accessToken(), 'other-device-token');
      expect(
        cache.value?['accessToken'],
        kIsWeb ? isNull : 'other-device-token',
      );
      expect(authorization.refreshes, 0);
      client.dispose();
    },
  );
  test(
    'a retained refresh commit never returns a token explicitly rejected later',
    () async {
      record = await envelope(grant('expired', expiry: 900));
      authorization.refreshGrant = (_, _) async =>
          grant('rotated-${authorization.refreshes}');
      var unavailable = true;
      final client = broker(
        invoke: (name, data) async {
          if (name == 'finishStorageRefresh' && unavailable) {
            throw FirebaseFunctionsException(
              code: 'unavailable',
              message: 'Test failure',
            );
          }
          return call(name, data);
        },
      );
      await expectLater(
        client.accessToken(),
        throwsA(isA<SyncProviderFailure>()),
      );
      unavailable = false;
      expect(await client.accessToken(rejectedToken: 'rotated-1'), 'rotated-2');
      expect(authorization.refreshes, 2);
      client.dispose();
    },
  );

  test(
    'non-shareable grants require account setup before using any cached access',
    () async {
      authorization.compatible = false;
      final client = broker();
      await expectLater(
        client.accessToken(),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.sharedSetupRequired,
          ),
        ),
      );
      client.dispose();
    },
  );
  test(
    'logout or disconnect fences a refresh before ciphertext publication',
    () async {
      record = await envelope(grant('expired', expiry: 900));
      final refreshed = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      authorization.refreshGrant = (_, _) {
        started.complete();
        return refreshed.future;
      };
      final client = broker();
      final pending = client.accessToken();
      final check = expectLater(pending, throwsStateError);
      await started.future;
      current = false;
      client.dispose();
      refreshed.complete(grant('late-token'));
      await check;
      expect(writes, isEmpty);
    },
  );
  test('lost commit response retries identical ciphertext without another provider refresh', () async {
    record = await envelope(grant('expired', expiry: 900));
    authorization.refreshGrant = (_, _) async => grant('refreshed');
    var commits = 0;
    final client = broker(
      invoke: (name, data) async {
        final result = await call(name, data);
        if (name == 'finishStorageRefresh' && commits++ == 0) {
          throw FirebaseFunctionsException(
            code: 'unavailable',
            message: 'offline',
          );
        }
        return result;
      },
    );
    expect(await client.accessToken(), 'refreshed');
    expect(authorization.refreshes, 1);
    expect(writes[0], writes[1]);
    client.dispose();
  });
  test(
    'transient commit failures retain rotating credentials for the next retry',
    () async {
      record = await envelope(grant('expired', expiry: 900));
      authorization.refreshGrant = (_, _) async => grant('rotated');
      var unavailable = true;
      final client = broker(
        invoke: (name, data) async {
          if (name == 'finishStorageRefresh' && unavailable) {
            throw FirebaseFunctionsException(
              code: 'unavailable',
              message: 'offline',
            );
          }
          return await call(name, data);
        },
      );
      await expectLater(
        client.accessToken(),
        throwsA(isA<SyncProviderFailure>()),
      );
      unavailable = false;
      expect(await client.accessToken(), 'rotated');
      expect(authorization.refreshes, 1);
      expect(writes, hasLength(1));
      client.dispose();
    },
  );
  test(
    'tampered ciphertext and backend errors cannot expose credential contents',
    () async {
      record = {...record, 'encryptedCredentials': 'corrupt'};
      final client = broker();
      await expectLater(
        client.accessToken(),
        throwsA(isA<SyncProviderFailure>()),
      );
      client.dispose();
      final unavailable = broker(
        invoke: (_, _) async => throw FirebaseFunctionsException(
          code: 'unavailable',
          message: 'private-token',
        ),
      );
      await expectLater(
        unavailable.accessToken(),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('private-token')),
          ),
        ),
      );
      unavailable.dispose();
    },
  );
  for (final provider in ['nextcloud', 'webdav']) {
    test(
      '$provider account identity and password are only decrypted locally',
      () async {
        connection = StorageConnection(
          provider: provider,
          libraryId: cipher.libraryId,
          accountLabel: '',
          encryptedCapability: await cipher.encryptCapability(
            provider,
            capability,
          ),
          generation: 1,
          enabled: true,
          state: 'ready',
        );
        record = await envelope({
          'type': 'app_password',
          'server': 'https://cloud.example',
          'username': 'email@example.invalid',
          'appPassword': 'private-refresh-token',
          'davUserId': 'canonical-user',
        });
        final client = broker();
        final access = await client.access() as StorageDavAccess;
        expect(access.davUserId, 'canonical-user');
        expect(access.password, 'private-refresh-token');
        client.dispose();
      },
    );
  }
  test('provider HTTP refreshes a rejected bearer once and preserves request bytes', () async {
    var calls = 0;
    var refreshes = 0;
    final client = ProviderHttp(
      MockClient((request) async {
        calls++;
        expect(request.followRedirects, false);
        expect(request.bodyBytes, [1, 2]);
        expect(
          request.headers['Authorization'],
          calls == 1 ? 'Bearer old' : 'Bearer new',
        );
        return http.Response('', 401);
      }),
      refreshRejectedToken: (token) async {
        refreshes++;
        expect(token, 'old');
        return 'new';
      },
    );
    final result = await client.send(
      'POST',
      Uri.https('example.invalid', '/objects'),
      headers: {'Authorization': 'Bearer old'},
      body: Uint8List.fromList([1, 2]),
    );
    expect(result.statusCode, 401);
    expect(calls, 2);
    expect(refreshes, 1);
  });
}

class _MemoryAccessCache implements StorageAccessCache {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    this.value = value;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}
