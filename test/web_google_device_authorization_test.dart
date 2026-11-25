@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/external_sync/storage_authorization.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('Google configuration is prepared before the gesture and blocked popup cannot exchange', () async {
    final original = web.window.getProperty<JSAny?>('open'.toJS);
    String? opened;
    web.window.setProperty(
      'open'.toJS,
      ((String url, String target, String features) {
        opened = url;
        return null;
      }).toJS,
    );
    addTearDown(() => web.window.setProperty('open'.toJS, original));
    var calls = 0;
    final client = StorageAuthorizationClient(
      exchangeCall: (name, data) async {
        calls++;
        expect(name, 'prepareStorageTokenExchange');
        return {
          'clientId': 'shared-web-client',
          'redirectUri': 'https://wrong-origin.test/oauth/storage/callback',
        };
      },
    );
    addTearDown(client.dispose);
    await expectLater(
      client.prepare('google_drive'),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(calls, 1);
    expect(opened, isNull);
  });
  test(
    'Google opens authorization synchronously from the explicit gesture',
    () async {
      final original = web.window.getProperty<JSAny?>('open'.toJS);
      String? opened;
      web.window.setProperty(
        'open'.toJS,
        ((String url, String target, String features) {
          opened = url;
          return null;
        }).toJS,
      );
      addTearDown(() => web.window.setProperty('open'.toJS, original));
      final client = StorageAuthorizationClient(
        exchangeCall: (name, data) async {
          expect(name, 'prepareStorageTokenExchange');
          return {
            'clientId': 'shared-web-client',
            'redirectUri':
                '${web.window.location.origin}/oauth/storage/callback',
          };
        },
      );
      addTearDown(client.dispose);
      final prepared = await client.prepare('google_drive');
      expect(opened, isNull);
      final result = prepared.authorize();
      expect(Uri.parse(opened!).host, 'accounts.google.com');
      expect(
        Uri.parse(opened!).queryParameters['client_id'],
        'shared-web-client',
      );
      expect(Uri.parse(opened!).queryParameters['access_type'], 'offline');
      expect(
        Uri.parse(opened!).queryParameters['code_challenge_method'],
        'S256',
      );
      await expectLater(result, throwsA(isA<SyncProviderFailure>()));
    },
  );
}
