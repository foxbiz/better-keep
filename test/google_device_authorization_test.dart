import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/storage_authorization.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/storage_credential_broker.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class DeviceAuthorization extends StorageAuthorizationClient {
  DeviceAuthorization({required super.createClient});
  Future<Map<String, dynamic>> Function(Map<String, dynamic>, String?)? renew;
  @override
  Future<Map<String, dynamic>> renewDeviceGrant(
    Map<String, dynamic> credentials, {
    String? rejectedToken,
  }) async {
    if (renew == null) storageConsentRequired();
    return renew!(credentials, rejectedToken);
  }
}

void main() {
  final identity = <String, dynamic>{
    'type': 'oauth',
    'grant': 'google_device',
    'clientId': 'google-device-v1',
    'accountId': 'drive-owner',
    'accountLabel': 'owner@example.test',
  };
  Map<String, dynamic> grant(String token) => {
    ...identity,
    'accessToken': token,
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  };

  test('device consent and renewal never publish credentials or acquire a shared lease', () async {
    final cipher = await SyncCipher.create('qa-user', Uint8List(32));
    addTearDown(cipher.dispose);
    final connection = StorageConnection(
      provider: 'google_drive',
      libraryId: cipher.libraryId,
      clientId: 'google-device-v1',
      accountLabel: '',
      generation: 1,
      enabled: true,
      state: 'ready',
      encryptedCapability: await cipher.encryptCapability(
        'google_drive',
        SyncCipher.newCapability(),
      ),
    );
    final record = {
      'generation': 1,
      'clientId': connection.clientId,
      'revision': 1,
      'encryptedCredentials': await cipher.encryptCredentials(
        provider: 'google_drive',
        generation: 1,
        clientId: connection.clientId,
        credentials: identity,
      ),
    };
    final authorization = DeviceAuthorization(
      createClient: () => MockClient((request) async {
        expect(
          request.headers['Authorization'],
          'Bearer renewed-private-token',
        );
        if (request.url.path == '/oauth2/v2/userinfo') {
          return http.Response(
            jsonEncode({'id': 'drive-owner', 'email': 'owner@example.test'}),
            200,
          );
        }
        expect(request.url.path, '/drive/v3/files');
        return http.Response('{"files":[]}', 200);
      }),
    );
    addTearDown(authorization.dispose);
    var renewals = 0;
    authorization.renew = (saved, rejected) async {
      expect(saved, identity);
      expect(rejected, 'initial-private-token');
      renewals++;
      return grant('renewed-private-token');
    };
    authorization.rememberDeviceGrant(grant('initial-private-token'));
    final operations = <String>[];
    StorageCredentialBroker broker(StorageAuthorizationClient auth) =>
        StorageCredentialBroker(
          connection: connection,
          cipher: cipher,
          deviceId: 'qa-device',
          authorization: auth,
          isCurrent: () => true,
          call: (name, data) async {
            operations.add(name);
            expect(name, 'getEncryptedStorageCredentials');
            expect(jsonEncode(data), isNot(contains('private-token')));
            expect(jsonEncode(data), isNot(contains('drive-owner')));
            return record;
          },
        );
    final first = broker(authorization);
    addTearDown(first.dispose);
    expect(await first.accessToken(), 'initial-private-token');
    expect(
      await Future.wait([
        first.accessToken(rejectedToken: 'initial-private-token'),
        first.accessToken(rejectedToken: 'initial-private-token'),
      ]),
      ['renewed-private-token', 'renewed-private-token'],
    );
    expect(renewals, 1);
    expect(operations, everyElement('getEncryptedStorageCredentials'));
    expect(
      authorization.credentialsForStorage('google_drive', grant('secret')),
      identity,
    );
    final secondAuth = DeviceAuthorization(createClient: http.Client.new);
    addTearDown(secondAuth.dispose);
    final second = broker(secondAuth);
    addTearDown(second.dispose);
    await expectLater(
      second.accessToken(),
      throwsA(isA<SyncProviderFailure>()),
    );
    secondAuth.rememberDeviceGrant(grant('second-device-token'));
    expect(await second.accessToken(), 'second-device-token');
  });

  test('silent authorization rejects a different Google account', () async {
    final authorization = DeviceAuthorization(
      createClient: () => MockClient((request) async {
        expect(request.url.path, '/oauth2/v2/userinfo');
        return http.Response(
          '{"id":"wrong-owner","email":"other@example.test"}',
          200,
        );
      }),
    );
    addTearDown(authorization.dispose);
    authorization.renew = (_, _) async => grant('wrong-account-token');
    await expectLater(
      authorization.deviceAccess(identity),
      throwsA(isA<SyncProviderFailure>()),
    );
  });

  test('logout discards an in-flight local grant before using it', () async {
    final pending = Completer<Map<String, dynamic>>();
    final authorization = DeviceAuthorization(
      createClient: () => MockClient((_) async {
        fail('Logged-out authorization must not access the provider');
      }),
    );
    authorization.renew = (_, _) => pending.future;
    final result = authorization.deviceAccess(identity);
    authorization.dispose();
    pending.complete(grant('late-private-token'));
    await expectLater(result, throwsStateError);
  });
}
