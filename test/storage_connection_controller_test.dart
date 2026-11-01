import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/storage_credential_broker.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/storage_authorization.dart';
import 'support/webdav_server.dart';

void main() {
  late SyncCipher cipher;
  late StorageConnectionController controller;
  late StreamController<Map<String, Map<String, dynamic>>> metadata;
  late Map<String, Map<String, dynamic>> server;
  late Map<String, Map<String, dynamic>> records;
  late FakeStorageAuthorization authorization;
  late List<String> calls;
  late bool current;
  late StorageBrokerCall invoke;
  late Future<void> Function(StorageDavAccess) probe;
  Map<String, dynamic> grant() => {
    'type': 'oauth',
    'grant': 'test',
    'clientId': 'client',
    'accountId': 'account',
    'accountLabel': 'private@example.com',
    'accessToken': 'private-access',
    'refreshToken': 'private-refresh',
    'expiresAt': DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch,
  };
  Future<Map<String, dynamic>> connection(
    String provider, {
    int generation = 1,
    bool enabled = true,
    String state = 'ready',
  }) async => {
    'provider': provider,
    'connectionId': provider,
    'libraryId': cipher.libraryId,
    'generation': generation,
    'enabled': enabled,
    'state': state,
    'updatedAt': generation,
    'accountLabel': '',
    'credentialVersion': 2,
    'clientId': provider == 'nextcloud' ? '' : 'client',
    'encryptedCapability': await cipher.encryptCapability(
      provider,
      SyncCipher.newCapability(),
    ),
  };
  StorageConnectionController create({
    FirebaseSyncPreference? preference,
    http.Client Function()? client,
  }) => StorageConnectionController(
    cipher: cipher,
    deviceId: 'device',
    isCurrent: () => current,
    call: (n, d) => invoke(n, d),
    readConnection: (provider) async => server[provider],
    metadata: metadata.stream,
    launchAuthorization: (_) async => true,
    authorization: authorization,
    preference: preference,
    createClient: client,
    probeNextcloud: (access) => probe(access),
  );
  setUp(() async {
    cipher = await SyncCipher.create('user', Uint8List(32));
    current = true;
    metadata = StreamController.broadcast(sync: true);
    server = {};
    records = {};
    calls = [];
    authorization = FakeStorageAuthorization()..consent = () async => grant();
    probe = (_) async {};
    invoke = (name, data) async {
      calls.add(name);
      expect(jsonEncode(data), isNot(contains('private-access')));
      expect(jsonEncode(data), isNot(contains('private-refresh')));
      expect(jsonEncode(data), isNot(contains('private@example.com')));
      final provider = data['provider'] as String;
      if (name == 'registerEncryptedStorageConnection') {
        final value = {
          ...await connection(provider, generation: data['generation']),
          'encryptedCapability': data['encryptedCapability'],
          'clientId': data['clientId'],
        };
        records[provider] = {
          'generation': data['generation'],
          'clientId': data['clientId'],
          'revision': 1,
          'encryptedCredentials': data['encryptedCredentials'],
        };
        server[provider] = value;
        return value;
      }
      if (name == 'getEncryptedStorageCredentials') return records[provider];
      if (name == 'setStorageConnectionEnabled') {
        server[provider] = {
          ...server[provider]!,
          'enabled': data['enabled'],
          'updatedAt': 10,
        };
        return {'success': true};
      }
      if (name == 'beginStorageDisconnect' ||
          name == 'disconnectStorageConnection') {
        server[provider] = {
          ...server[provider]!,
          'enabled': false,
          'state': name == 'beginStorageDisconnect'
              ? 'disconnecting'
              : 'disconnected',
          'updatedAt': 20,
        };
        return {'success': true};
      }
      throw StateError('Unexpected call');
    };
    controller = create();
  });
  tearDown(() async {
    controller.dispose();
    await metadata.close();
    cipher.dispose();
  });

  test('passes the exchange receipt with encrypted registration', () async {
    authorization.consent = () async => {
      ...grant(),
      'exchangeProof': 'signed-receipt',
    };
    final original = invoke;
    Map<String, dynamic>? registration;
    invoke = (name, data) async {
      if (name == 'registerEncryptedStorageConnection') {
        registration = Map.of(data);
      }
      return original(name, data);
    };
    await controller.prepareOAuth('google_drive');
    await controller.authorizeOAuth('google_drive');
    expect(registration?['exchangeProof'], 'signed-receipt');
    expect(registration, isNot(contains('refreshToken')));
    final stored = await cipher.decryptCredentials(
      provider: 'google_drive',
      generation: 1,
      clientId: 'client',
      encrypted: records['google_drive']!['encryptedCredentials'],
    );
    expect(stored, isNot(contains('exchangeProof')));
    expect(stored['refreshToken'], 'private-refresh');
  });

  test('capacity failures do not stop sync or request reconnection', () async {
    var status = 200, requests = 0;
    controller.dispose();
    controller = create(
      client: () => MockClient((request) async {
        requests++;
        expect(request.url.path, '/2/users/get_space_usage');
        return http.Response(
          '{"used":100,"allocation":{".tag":"individual","allocated":1000}}',
          status,
        );
      }),
    );
    await controller.prepareOAuth('dropbox');
    await controller.authorizeOAuth('dropbox');
    expect((await controller.readStorageUsage('dropbox'))!.freeBytes, 900);
    status = 503;
    expect(await controller.readStorageUsage('dropbox'), isNull);
    expect(controller.errors, isEmpty);
    expect(controller.adapters, isNotEmpty);
    await controller.setEnabled('dropbox', false);
    expect(await controller.readStorageUsage('dropbox'), isNull);
    expect(requests, 2);
  });

  test(
    'OTP rejection cannot delete; verified clear drains sync and leaves it off',
    () async {
      var deletes = 0;
      var rejectDelete = true;
      var finishes = 0;
      var drained = false;
      controller.dispose();
      controller = create(
        client: () => MockClient((request) async {
          expect(drained, true);
          expect(request.url.path, '/2/files/delete_v2');
          deletes++;
          return http.Response('{}', rejectDelete ? 503 : 200);
        }),
      );
      await controller.prepareOAuth('dropbox');
      await controller.authorizeOAuth('dropbox');
      final base = invoke;
      final operation = 'c' * 64;
      invoke = (name, data) async {
        if (name == 'requestStorageClearOtp') return {'requestId': 'request'};
        if (name == 'beginStorageClear') {
          if (data['code'] != '123456') {
            throw FirebaseFunctionsException(
              code: 'permission-denied',
              message: 'Invalid code',
            );
          }
          server['dropbox'] = {
            ...server['dropbox']!,
            'state': 'clearing',
            'enabled': false,
            'clearOperationId': operation,
            'updatedAt': 10,
          };
          metadata.add(server);
          return {'operationId': operation};
        }
        if (name == 'finishStorageClear') {
          finishes++;
          expect(deletes, 2);
          server['dropbox'] = {
            ...server['dropbox']!,
            'state': 'ready',
            'enabled': false,
            'clearOperationId': '',
            'storageEpoch': 'd' * 64,
            'credentialVersion': 3,
            'updatedAt': 20,
          };
          metadata.add(server);
          return {'success': true};
        }
        return base(name, data);
      };
      await controller.requestClearOtp('dropbox');
      await expectLater(
        controller.clearSyncedData('dropbox', 'request', '000000', () async {
          drained = true;
        }),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(deletes, 0);
      expect(drained, false);
      await expectLater(
        controller.clearSyncedData('dropbox', 'request', '123456', () async {
          drained = true;
        }),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(deletes, 1);
      expect(finishes, 0);
      expect(controller.connections['dropbox']!.state, 'clearing');
      expect(controller.connections['dropbox']!.enabled, false);
      expect(controller.adapters, isEmpty);
      rejectDelete = false;
      await controller.requestClearOtp('dropbox');
      await controller.clearSyncedData(
        'dropbox',
        'request',
        '123456',
        () async {
          drained = true;
        },
      );
      expect(deletes, 2);
      expect(finishes, 1);
      expect(controller.connections['dropbox']!.enabled, false);
      expect(
        controller.connections['dropbox']!.replicaId,
        'dropbox:1:${'d' * 64}',
      );
      expect(controller.adapters, isEmpty);
    },
  );

  test(
    'connection removed during clear drain aborts before provider deletion',
    () async {
      await controller.prepareOAuth('dropbox');
      await controller.authorizeOAuth('dropbox');
      final base = invoke;
      invoke = (name, data) async => name == 'beginStorageClear'
          ? {'operationId': 'c' * 64}
          : base(name, data);
      await expectLater(
        controller.clearSyncedData('dropbox', 'request', '123456', () async {
          metadata.add(server); // Confirm the reload before its later deletion.
          server.clear();
          metadata.add(server);
        }),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
      expect(calls, isNot(contains('finishStorageClear')));
    },
  );

  test(
    'duplicate Connect rejects only the second call and preserves consent',
    () async {
      final consent = Completer<Map<String, dynamic>>();
      authorization.consent = () => consent.future;
      await controller.prepareOAuth('dropbox');
      final first = controller.authorizeOAuth('dropbox');
      await expectLater(controller.authorizeOAuth('dropbox'), throwsStateError);
      expect(authorization.cancellations, 0);
      expect(controller.canCancelOAuth('dropbox'), true);
      consent.complete(grant());
      await first;
      expect(
        calls.where((name) => name == 'registerEncryptedStorageConnection'),
        hasLength(1),
      );
      expect(controller.canCancelOAuth('dropbox'), false);
    },
  );
  test('failed registration clears its consumed authorization', () async {
    invoke = (_, _) async => throw FirebaseFunctionsException(
      code: 'permission-denied',
      message: 'Test failure',
    );
    await controller.prepareOAuth('dropbox');
    await expectLater(
      controller.authorizeOAuth('dropbox'),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(controller.canCancelOAuth('dropbox'), false);
    expect(controller.actions['dropbox'], null);
    expect(await controller.cancelOAuth('dropbox'), true);
  });

  test('pausing disposes prepared authorization resources', () async {
    server['dropbox'] = await connection('dropbox');
    metadata.add(server);
    await controller.prepareOAuth('dropbox');
    await controller.setEnabled('dropbox', false);
    expect(authorization.cancellations, 1);
    expect(controller.canCancelOAuth('dropbox'), false);
  });

  test(
    'interrupted disconnect can finish after recreating the controller',
    () async {
      await controller.prepareOAuth('dropbox');
      await controller.authorizeOAuth('dropbox');
      final base = invoke;
      invoke = (name, data) async {
        if (name == 'disconnectStorageConnection') {
          throw FirebaseFunctionsException(
            code: 'unavailable',
            message: 'Test failure',
          );
        }
        return base(name, data);
      };
      await expectLater(
        controller.disconnect('dropbox'),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(server['dropbox']!['state'], 'disconnecting');
      controller.dispose();
      controller = create();
      metadata.add(server);
      invoke = base;
      await controller.disconnect('dropbox');
      expect(server['dropbox']!['state'], 'disconnected');
    },
  );

  test('Android device grant stores only encrypted identity and reauthorization preserves the replica', () async {
    Map<String, dynamic> deviceGrant() =>
        {...grant(), 'grant': 'google_device', 'clientId': 'google-device-v1'}
          ..remove('refreshToken');
    authorization.consent = () async => deviceGrant();
    await controller.prepareOAuth('google_drive');
    await controller.authorizeOAuth('google_drive');
    final original = Map<String, dynamic>.of(server['google_drive']!);
    final record = records['google_drive']!;
    final decoded = await cipher.decryptCredentials(
      provider: 'google_drive',
      generation: 1,
      clientId: 'google-device-v1',
      encrypted: record['encryptedCredentials'],
    );
    expect(decoded['accountId'], 'account');
    expect(decoded.containsKey('accessToken'), false);
    expect(decoded.containsKey('refreshToken'), false);
    calls.clear();
    await controller.prepareOAuth('google_drive');
    await controller.authorizeOAuth('google_drive');
    expect(server['google_drive'], original);
    expect(calls, isNot(contains('registerEncryptedStorageConnection')));
    expect(calls, isNot(contains('acquireStorageRefreshLease')));

    authorization.consent = () async => {
      ...deviceGrant(),
      'accountId': 'wrong-account',
    };
    await controller.prepareOAuth('google_drive');
    await expectLater(
      controller.authorizeOAuth('google_drive'),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(server['google_drive'], original);
  });

  test(
    'legacy device consent upgrades to a shared grant for the same account',
    () async {
      authorization.consent = () async =>
          {...grant(), 'grant': 'google_device', 'clientId': 'google-device-v1'}
            ..remove('refreshToken');
      await controller.prepareOAuth('google_drive');
      await controller.authorizeOAuth('google_drive');
      final originalLibrary = server['google_drive']!['libraryId'];
      authorization.consent = () async => {
        ...grant(),
        'grant': 'oauth_exchange',
      };
      await controller.prepareOAuth('google_drive');
      await controller.authorizeOAuth('google_drive');
      expect(server['google_drive']!['generation'], 2);
      expect(server['google_drive']!['libraryId'], originalLibrary);
      final decoded = await cipher.decryptCredentials(
        provider: 'google_drive',
        generation: 2,
        clientId: 'client',
        encrypted: records['google_drive']!['encryptedCredentials'],
      );
      expect(decoded['grant'], 'oauth_exchange');
      expect(decoded['refreshToken'], isNotEmpty);
    },
  );

  test('a new remote grant clears the previous connection error', () async {
    await controller.prepareOAuth('google_drive');
    await controller.authorizeOAuth('google_drive');
    final original = Map<String, dynamic>.of(server['google_drive']!);
    authorization.consent = () async => throw const SyncProviderFailure(
      SyncProviderFailureKind.reconnectRequired,
    );
    await controller.prepareOAuth('google_drive');
    await expectLater(
      controller.authorizeOAuth('google_drive'),
      throwsA(isA<SyncProviderFailure>()),
    );
    metadata.add({
      'google_drive': {...original, 'updatedAt': 10},
    });
    expect(
      controller.errors['google_drive'],
      SyncProviderFailureKind.reconnectRequired,
    );
    metadata.add({
      'google_drive': await connection('google_drive', generation: 2),
    });
    expect(controller.errors['google_drive'], isNull);
    expect(controller.connections['google_drive']!.generation, 2);
  });

  test(
    'Google authorization cannot replace a connection changed during consent',
    () async {
      await controller.prepareOAuth('google_drive');
      server['google_drive'] = await connection('google_drive', generation: 2);
      await expectLater(
        controller.authorizeOAuth('google_drive'),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(calls, isNot(contains('registerEncryptedStorageConnection')));
      expect(server['google_drive']!['generation'], 2);
    },
  );

  test('direct consent encrypts credentials and account details before registration', () async {
    await controller.prepareOAuth('google_drive');
    expect(calls, isEmpty);
    await controller.authorizeOAuth('google_drive');
    expect(calls, contains('registerEncryptedStorageConnection'));
    expect(calls, isNot(contains('prepareStorageOAuth')));
    final record = records['google_drive']!;
    final decoded = await cipher.decryptCredentials(
      provider: 'google_drive',
      generation: 1,
      clientId: 'client',
      encrypted: record['encryptedCredentials'],
    );
    expect(decoded['refreshToken'], 'private-refresh');
    expect(
      controller.connections['google_drive']!.accountLabel,
      'private@example.com',
    );
    expect(controller.adapters.single.connectionId, 'google_drive:1');
    expect(server['google_drive']!['accountLabel'], '');
  });
  test('cancelling consent never registers a late grant', () async {
    final grantReady = Completer<Map<String, dynamic>>();
    authorization.consent = () => grantReady.future;
    await controller.prepareOAuth('dropbox');
    final pending = controller.authorizeOAuth('dropbox');
    await pumpEventQueue();
    expect(await controller.cancelOAuth('dropbox'), true);
    grantReady.complete(grant());
    await pending;
    expect(calls, isEmpty);
    expect(controller.connections, isEmpty);
  });
  test('non-shareable grants are rejected before registration', () async {
    authorization.compatible = false;
    await controller.prepareOAuth('google_drive');
    await expectLater(
      controller.authorizeOAuth('google_drive'),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.sharedSetupRequired,
        ),
      ),
    );
    expect(calls, isEmpty);
    expect(server, isEmpty);
  });
  test('registration that won cancellation is reported as connected', () async {
    final base = invoke;
    final response = Completer<void>();
    final started = Completer<void>();
    invoke = (name, data) async {
      final result = await base(name, data);
      if (name == 'registerEncryptedStorageConnection') {
        started.complete();
        await response.future;
      }
      return result;
    };
    await controller.prepareOAuth('dropbox');
    final pending = controller.authorizeOAuth('dropbox');
    await started.future;
    final cancellation = controller.cancelOAuth('dropbox');
    response.complete();
    await pending;
    expect(await cancellation, false);
    expect(controller.connections['dropbox']!.isReady, true);
  });
  test(
    'account changes discard late consent without backend registration',
    () async {
      final grantReady = Completer<Map<String, dynamic>>();
      authorization.consent = () => grantReady.future;
      await controller.prepareOAuth('google_drive');
      final pending = controller.authorizeOAuth('google_drive');
      final rejected = expectLater(pending, throwsStateError);
      await pumpEventQueue();
      current = false;
      grantReady.complete(grant());
      await rejected;
      expect(calls, isEmpty);
    },
  );
  test('legacy connections require fresh consent and preserve generation on upgrade', () async {
    server['dropbox'] = await connection('dropbox', generation: 4)
      ..remove('credentialVersion');
    metadata.add({...server});
    expect(controller.connections['dropbox']!.state, 'reconnect_required');
    expect(controller.adapters, isEmpty);
    await controller.prepareOAuth('dropbox');
    await controller.authorizeOAuth('dropbox');
    expect(controller.connections['dropbox']!.generation, 5);
    expect(controller.connections['dropbox']!.credentialVersion, 2);
  });
  test(
    'WebDAV probes the supplied root before publishing encrypted credentials',
    () async {
      controller.dispose();
      final dav = WebDavServer()..omitEtags = true;
      controller = create(client: dav.client);
      final access = StorageDavAccess(dav.root, 'user', 'private-refresh');
      await expectLater(
        controller.connectWebDav(access),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(calls, isEmpty);
      dav.omitEtags = false;
      await controller.connectWebDav(access);
      final decoded = await cipher.decryptCredentials(
        provider: 'webdav',
        generation: 1,
        clientId: '',
        encrypted: records['webdav']!['encryptedCredentials'],
      );
      expect(decoded['server'], dav.root.toString());
      expect(decoded['appPassword'], 'private-refresh');
      expect(controller.connections['webdav']!.isReady, true);
      expect(dav.files, isEmpty);
    },
  );
  test('Nextcloud probes immutable writes before storing only encrypted credentials', () async {
    final access = StorageDavAccess(
      Uri.parse('https://cloud.example'),
      'user',
      'private-refresh',
      davUserId: 'canonical',
    );
    probe = (_) async =>
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    await expectLater(
      controller.connectNextcloud(access),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(calls, isEmpty);
    probe = (_) async {};
    await controller.connectNextcloud(access);
    final decoded = await cipher.decryptCredentials(
      provider: 'nextcloud',
      generation: 1,
      clientId: '',
      encrypted: records['nextcloud']!['encryptedCredentials'],
    );
    expect(decoded['appPassword'], 'private-refresh');
    expect(decoded['davUserId'], 'canonical');
  });
  test(
    'shared radio selection retires the previous provider immediately',
    () async {
      final selections = StreamController<FirebaseSyncSelection>.broadcast(
        sync: true,
      );
      final preference = FirebaseSyncPreference(
        currentUid: () => 'user',
        watch: (_) => selections.stream,
        write: (_, _) async => throw StateError('Unexpected'),
      );
      preference.bind('user');
      controller.dispose();
      controller = create(preference: preference);
      addTearDown(() async {
        preference.dispose();
        await selections.close();
      });
      server['google_drive'] = await connection('google_drive');
      server['dropbox'] = await connection('dropbox');
      metadata.add({...server});
      expect(controller.adapters, isEmpty);
      selections.add(
        const FirebaseSyncSelection(
          false,
          provider: 'google_drive',
          confirmed: true,
          revision: 1,
        ),
      );
      final old = controller.adapters.single;
      selections.add(
        const FirebaseSyncSelection(
          false,
          provider: 'dropbox',
          confirmed: true,
          revision: 2,
        ),
      );
      expect(controller.adapters.single.connectionId, 'dropbox:1');
      await expectLater(old.changes(null), throwsStateError);
      selections.add(
        const FirebaseSyncSelection(true, confirmed: true, revision: 3),
      );
      expect(controller.adapters, isEmpty);
    },
  );
  test(
    'failed pause remains locally stopped until explicit successful enable',
    () async {
      server['dropbox'] = await connection('dropbox');
      metadata.add({...server});
      final base = invoke;
      invoke = (_, _) async => throw FirebaseFunctionsException(
        code: 'unavailable',
        message: 'offline',
      );
      await expectLater(
        controller.setEnabled('dropbox', false),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(controller.adapters, isEmpty);
      metadata.add({...server});
      expect(controller.adapters, isEmpty);
      invoke = base;
      await controller.setEnabled('dropbox', true);
      expect(controller.adapters, hasLength(1));
    },
  );
  test('disconnect stops adapters and reports provider revocation failure honestly', () async {
    await controller.prepareOAuth('dropbox');
    await controller.authorizeOAuth('dropbox');
    authorization.revoked = false;
    expect(await controller.disconnect('dropbox'), false);
    expect(controller.adapters, isEmpty);
    expect(controller.connections['dropbox']!.state, 'disconnected');
    expect(
      calls,
      containsAllInOrder([
        'beginStorageDisconnect',
        'disconnectStorageConnection',
      ]),
    );
  });
  test(
    'wrong library and out-of-order metadata cannot start a provider',
    () async {
      server['dropbox'] = {
        ...await connection('dropbox'),
        'libraryId': 'a' * 64,
      };
      metadata.add({...server});
      expect(controller.needsKeyRecovery('dropbox'), true);
      expect(controller.adapters, isEmpty);
      server['dropbox'] = await connection('dropbox', generation: 3);
      metadata.add({...server});
      final old = controller.adapters.single;
      metadata.add({'dropbox': await connection('dropbox', generation: 2)});
      expect(controller.adapters.single, same(old));
      metadata.add({
        'dropbox': {'invalid': true},
      });
      expect(controller.adapters, isEmpty);
    },
  );
}
