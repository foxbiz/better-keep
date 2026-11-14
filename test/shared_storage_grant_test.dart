import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/storage_authorization.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/storage_credential_broker.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final grantType in [
    'google_apple',
    'dropbox_native',
    'oauth_exchange',
  ]) {
    final provider = grantType == 'dropbox_native' ? 'dropbox' : 'google_drive';
    test(
      '$grantType restores and refreshes an encrypted native grant on another device and after reload',
      () async {
        final ownerCipher = await SyncCipher.create('owner', Uint8List(32));
        final recipientCipher = await SyncCipher.create('owner', Uint8List(32));
        addTearDown(ownerCipher.dispose);
        addTearDown(recipientCipher.dispose);
        final clientId = provider == 'google_drive'
            ? 'issuing-ios-client.apps.googleusercontent.com'
            : 'issuing-dropbox-client';
        final capability = SyncCipher.newCapability();
        final credentials = <String, dynamic>{
          'type': 'oauth',
          'grant': grantType,
          'clientId': clientId,
          'accountId': 'provider-account',
          'accessToken': 'expired-access',
          'expiresAt': 1,
          'refreshToken': 'private-refresh-0',
        };
        final connection = StorageConnection(
          provider: provider,
          libraryId: ownerCipher.libraryId,
          accountLabel: '',
          generation: 1,
          enabled: true,
          state: 'ready',
          clientId: clientId,
          encryptedCapability: await ownerCipher.encryptCapability(
            provider,
            capability,
          ),
        );
        var record = <String, dynamic>{
          'generation': 1,
          'clientId': clientId,
          'revision': 1,
          'encryptedCredentials': await ownerCipher.encryptCredentials(
            provider: provider,
            generation: 1,
            clientId: clientId,
            credentials: credentials,
          ),
        };
        var refreshes = 0;
        var commits = 0;
        var leased = false;
        final firstTokenRequest = Completer<void>();
        final releaseFirstToken = Completer<void>();
        final clients = <StorageAuthorizationClient>[];
        final brokers = <StorageCredentialBroker>[];
        addTearDown(() {
          for (final broker in brokers) {
            broker.dispose();
          }
          for (final client in clients) {
            client.dispose();
          }
        });
        Future<dynamic> cloud(String name, Map<String, dynamic> data) async {
          if (name == 'exchangeStorageOAuthToken') {
            expect(grantType, 'oauth_exchange');
            expect(leased, true);
            expect(data['operation'], 'refresh');
            expect(data['capability'], capability);
            expect(data['leaseId'], 'lease');
            expect(data['revision'], record['revision']);
            expect(data['fence'], record['revision']);
            expect(data['clientId'], clientId);
            expect(data['refreshToken'], 'private-refresh-$refreshes');
            refreshes++;
            if (refreshes == 1) {
              firstTokenRequest.complete();
              await releaseFirstToken.future;
            }
            return {
              'type': 'oauth',
              'accessToken': 'private-access-$refreshes',
              'refreshToken': 'private-refresh-$refreshes',
              'expiresAt': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
            };
          }
          final serialized = jsonEncode(data);
          expect(serialized, isNot(contains('private-refresh')));
          expect(serialized, isNot(contains('private-access')));
          expect(serialized, isNot(contains('provider-account')));
          expect(data['capability'], capability);
          switch (name) {
            case 'getEncryptedStorageCredentials':
              return record;
            case 'acquireStorageRefreshLease':
              if (leased) {
                throw FirebaseFunctionsException(
                  code: 'aborted',
                  message: 'Refresh lease is busy',
                );
              }
              leased = true;
              return {
                ...record,
                'status': 'acquired',
                'leaseId': 'lease',
                'fence': record['revision'],
              };
            case 'finishStorageRefresh':
              commits++;
              expect(data['generation'], 1);
              expect(data['revision'], record['revision']);
              record = {
                ...record,
                'revision': (record['revision'] as int) + 1,
                'encryptedCredentials': data['encryptedCredentials'],
              };
              leased = false;
              return {'revision': record['revision']};
            default:
              fail('Unexpected cloud operation: $name');
          }
        }

        StorageCredentialBroker device(String deviceId) {
          // Real authorization policy, no platform-specific compatibility stub
          // and no prepare/authorize/remember-grant call on the new device.
          final client = StorageAuthorizationClient(
            exchangeCall: cloud,
            createClient: () => MockClient((request) async {
              expect(
                request.url.toString(),
                provider == 'google_drive'
                    ? 'https://oauth2.googleapis.com/token'
                    : 'https://api.dropboxapi.com/oauth2/token',
              );
              expect(request.bodyFields, {
                'grant_type': 'refresh_token',
                'client_id': clientId,
                'refresh_token': 'private-refresh-$refreshes',
              });
              expect(request.followRedirects, false);
              refreshes++;
              if (refreshes == 1) {
                firstTokenRequest.complete();
                await releaseFirstToken.future;
              }
              return http.Response(
                jsonEncode({
                  'access_token': 'private-access-$refreshes',
                  'refresh_token': 'private-refresh-$refreshes',
                  'expires_in': 3600,
                  'token_type': 'Bearer',
                }),
                200,
              );
            }),
          );
          clients.add(client);
          final broker = StorageCredentialBroker(
            connection: connection,
            cipher: recipientCipher,
            deviceId: deviceId,
            call: cloud,
            isCurrent: () => true,
            authorization: client,
          );
          brokers.add(broker);
          return broker;
        }

        final newDevice = device('approved-browser');
        final initialRefresh = newDevice.accessToken();
        await firstTokenRequest.future;
        final other = device('another-approved-device');
        await expectLater(
          other.accessToken(),
          throwsA(
            isA<SyncProviderFailure>().having(
              (error) => error.kind,
              'kind',
              SyncProviderFailureKind.rateLimited,
            ),
          ),
        );
        expect(refreshes, 1);
        expect(commits, 0);
        releaseFirstToken.complete();
        expect(await initialRefresh, 'private-access-1');
        expect(refreshes, 1);
        expect(commits, 1);
        expect(await other.accessToken(), 'private-access-1');
        expect(refreshes, 1);
        expect(
          await other.accessToken(rejectedToken: 'private-access-1'),
          'private-access-2',
        );
        expect(commits, 2);
        newDevice.dispose();
        final reloaded = device('browser-after-key-approval');
        expect(await reloaded.accessToken(), 'private-access-2');
        expect(refreshes, 2);
        final decrypted = await ownerCipher.decryptCredentials(
          provider: provider,
          generation: 1,
          clientId: clientId,
          encrypted: record['encryptedCredentials'] as String,
        );
        expect(decrypted['refreshToken'], 'private-refresh-2');
        expect(decrypted['clientId'], clientId);
      },
    );
  }

  test('only durable public-client grants are shared, independent of receiver platform', () async {
    final client = StorageAuthorizationClient();
    addTearDown(client.dispose);
    final grant = <String, dynamic>{
      'type': 'oauth',
      'clientId': 'issuer',
      'accountId': 'account',
      'refreshToken': 'secret',
    };
    for (final kind in ['google_apple', 'google_desktop', 'oauth_exchange']) {
      expect(
        await client.supports('google_drive', {...grant, 'grant': kind}),
        true,
      );
    }
    for (final kind in ['dropbox_native', 'dropbox_web']) {
      expect(await client.supports('dropbox', {...grant, 'grant': kind}), true);
    }
    for (final kind in [
      'google_web',
      'google_android',
      'unknown',
      'dropbox_native',
    ]) {
      expect(
        await client.supports('google_drive', {...grant, 'grant': kind}),
        false,
      );
    }
    expect(
      await client.supports('google_drive', {
        ...grant,
        'grant': 'google_apple',
        'refreshToken': '',
      }),
      false,
    );
    expect(
      await client.supports('google_drive', {
        ...grant,
        'grant': 'google_apple',
        'clientId': '',
      }),
      false,
    );
    expect(await client.supports('nextcloud', {'type': 'app_password'}), true);
    if (kIsWeb) {
      await expectLater(
        client.prepare('google_drive'),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
    }
  });
}
