import 'dart:async';
import 'dart:convert';

import 'package:better_keep/services/external_sync/storage_authorization.dart';
import 'package:better_keep/services/external_sync/storage_pkce.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'Google disconnect revokes the refresh grant without a refresh exchange',
    () async {
      final client = StorageAuthorizationClient(
        exchangeCall: (_, _) async => fail('No refresh while disconnecting'),
        createClient: () => MockClient((request) async {
          expect(
            request.url.toString(),
            'https://oauth2.googleapis.com/revoke',
          );
          expect(request.bodyFields, {'token': 'refresh-secret'});
          return http.Response('', 200);
        }),
      );
      addTearDown(client.dispose);
      expect(
        await client.revoke('google_drive', {
          'grant': 'oauth_exchange',
          'refreshToken': 'refresh-secret',
          'expiresAt': 1,
        }),
        true,
      );
    },
  );

  test('hosted storage callback follows the selected environment', () {
    expect(
      hostedStorageRedirect(useEmulator: false).toString(),
      'https://betterkeep.app/oauth/storage/callback',
    );
    expect(
      hostedStorageRedirect(
        useEmulator: true,
        developmentOrigin: 'https://dev.example.test/',
      ).toString(),
      'https://dev.example.test/oauth/storage/callback',
    );
    for (final invalid in [
      '',
      'http://localhost:4321',
      'https://user@host.test',
      'https://host.test/path',
      'https://host.test/?x=1',
      'https://host.test/#x',
    ]) {
      expect(
        () => hostedStorageRedirect(
          useEmulator: true,
          developmentOrigin: invalid,
        ),
        throwsA(isA<SyncProviderFailure>()),
      );
    }
  });

  test(
    'hosted PKCE validates the local return but exchanges the HTTPS redirect',
    () {
      final hosted = Uri.parse(
        'https://dev.example.test/oauth/storage/callback',
      );
      for (final target in [
        Uri.parse('betterkeep-storage://oauth/callback'),
        Uri.parse('http://127.0.0.1:23456/storage-oauth'),
      ]) {
        final flow = StoragePkce(
          provider: 'dropbox',
          clientId: 'public-client',
          redirect: hosted,
          offline: true,
          returnUri: target,
        );
        expect(
          flow.authorizationUri.queryParameters['redirect_uri'],
          hosted.toString(),
        );
        expect(
          flow.state,
          matches(
            target.scheme == 'http'
                ? r'^loopback\.23456\.[A-Za-z0-9_-]{43}$'
                : r'^app\.[A-Za-z0-9_-]{43}$',
          ),
        );
        final result = target.replace(
          queryParameters: {'state': flow.state, 'code': 'one-time'},
        );
        final form = flow.exchangeForm(result);
        expect(form['redirect_uri'], hosted.toString());
        expect(form['code_verifier'], flow.verifier);
        final denial = result.replace(
          queryParameters: {'state': flow.state, 'error': 'access_denied'},
        );
        expect(() => flow.validateCallback(denial), returnsNormally);
        expect(
          () => flow.exchangeForm(denial),
          throwsA(isA<SyncProviderFailure>()),
        );
        expect(
          () => flow.validateCallback(
            denial.replace(query: 'state=wrong&error=access_denied'),
          ),
          throwsA(isA<SyncProviderFailure>()),
        );
        for (final bad in [
          result.replace(host: 'attacker.test'),
          result.replace(path: '/other'),
          result.replace(fragment: 'extra'),
          result.replace(query: 'state=${flow.state}&code=a&code=b'),
          result.replace(query: 'state=app.wrong&code=a'),
          hosted.replace(query: result.query),
          result.replace(query: 'state=${flow.state}&error=access_denied'),
        ]) {
          expect(
            () => flow.exchangeForm(bad),
            throwsA(isA<SyncProviderFailure>()),
          );
        }
      }
      for (final invalid in [
        'https://attacker.test',
        'http://127.0.0.1:80/storage-oauth',
        'http://localhost:23456/storage-oauth',
        'betterkeep-storage://oauth/other',
      ]) {
        expect(
          () => StoragePkce(
            provider: 'dropbox',
            clientId: 'public-client',
            redirect: hosted,
            offline: true,
            returnUri: Uri.parse(invalid),
          ),
          throwsA(isA<SyncProviderFailure>()),
        );
      }
    },
  );

  test('PKCE binds a random state, verifier, client and exact callback', () {
    for (final provider in ['google_drive', 'dropbox']) {
      final redirect = Uri.parse('http://127.0.0.1:12345/storage-oauth');
      final flow = StoragePkce(
        provider: provider,
        clientId: 'public-client',
        redirect: redirect,
        offline: true,
      );
      final second = StoragePkce(
        provider: provider,
        clientId: 'public-client',
        redirect: redirect,
        offline: true,
      );
      expect(flow.state, isNot(second.state));
      expect(flow.verifier, isNot(second.verifier));
      expect(
        flow.authorizationUri.queryParameters['code_challenge'],
        base64UrlEncode(sha256.convert(ascii.encode(flow.verifier)).bytes)
            .replaceAll('=', ''),
      );
      final callback = redirect.replace(
        queryParameters: {'code': 'single-use', 'state': flow.state},
      );
      expect(flow.exchangeForm(callback)['code_verifier'], flow.verifier);
      expect(flow.exchangeForm(callback), isNot(contains('client_secret')));
      for (final invalid in [
        callback.replace(host: 'attacker.invalid'),
        callback.replace(port: 12346),
        callback.replace(path: '/other'),
        callback.replace(scheme: 'https'),
        callback.replace(userInfo: 'user'),
        callback.replace(fragment: 'extra'),
        callback.replace(query: 'state=${flow.state}&code=a&code=b'),
        callback.replace(
          query: 'state=${flow.state}&state=${flow.state}&code=a',
        ),
        callback.replace(query: 'state=${second.state}&code=a'),
        callback.replace(
          query: 'state=${flow.state}&code=a&error=access_denied',
        ),
      ]) {
        expect(
          () => flow.exchangeForm(invalid),
          throwsA(isA<SyncProviderFailure>()),
        );
      }
    }
  });
  test(
    'cancellation discards a late consent result and closes callback resources',
    () async {
      final result = Completer<Map<String, dynamic>>();
      var closed = 0;
      final flow = StorageAuthorizationOperation(
        () => result.future,
        onCancel: () async {
          closed++;
        },
      );
      final waiting = expectLater(
        flow.authorize(),
        throwsA(isA<SyncProviderFailure>()),
      );
      await flow.cancel();
      result.complete({'accessToken': 'late-private-token'});
      await waiting;
      expect(closed, greaterThanOrEqualTo(1));
      await expectLater(flow.authorize(), throwsA(isA<SyncProviderFailure>()));
    },
  );
  test('token exchange uses fixed provider endpoint with no redirects or client secret', () async {
    final client = StorageAuthorizationClient(
      createClient: () => MockClient((request) async {
        expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
        expect(request.followRedirects, false);
        expect(request.bodyFields, {
          'client_id': 'public',
          'grant_type': 'refresh_token',
          'refresh_token': 'synthetic',
        });
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'rotated',
            'expires_in': 3600,
            'token_type': 'Bearer',
          }),
          200,
        );
      }),
    );
    final grant = await client.tokenRequest('google_drive', {
      'client_id': 'public',
      'grant_type': 'refresh_token',
      'refresh_token': 'synthetic',
    });
    expect(grant['refreshToken'], 'rotated');
    client.dispose();
  });
  test(
    'declined Drive scope and unexpected account require fresh authorization',
    () async {
      final paths = <String>[];
      final client = StorageAuthorizationClient(
        createClient: () => MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('userinfo')) {
            return http.Response(
              '{"id":"account","email":"test@example.invalid"}',
              200,
            );
          }
          return http.Response('{}', 403);
        }),
      );
      await expectLater(
        client.enrich('google_drive', {
          'accessToken': 'synthetic',
        }, expectedAccountId: 'different'),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(paths, ['/oauth2/v2/userinfo']);
      await expectLater(
        client.enrich('google_drive', {'accessToken': 'synthetic'}),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(paths.last, '/drive/v3/files');
      client.dispose();
    },
  );
  test(
    'dispose rejects a late provider response and never returns its token',
    () async {
      final response = Completer<http.Response>();
      final client = StorageAuthorizationClient(
        createClient: () => MockClient((_) => response.future),
      );
      final waiting = expectLater(
        client.tokenRequest('dropbox', {'code': 'synthetic'}),
        throwsStateError,
      );
      client.dispose();
      response.complete(
        http.Response(
          '{"access_token":"late","expires_in":3600,"token_type":"bearer"}',
          200,
        ),
      );
      await waiting;
    },
  );
}
