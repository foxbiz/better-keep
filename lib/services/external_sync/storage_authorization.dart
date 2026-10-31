import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'provider_http.dart';
import 'storage_authorization_types.dart';
import 'storage_authorization_native.dart'
    if (dart.library.js_interop) 'storage_authorization_web.dart'
    as platform;

export 'storage_authorization_types.dart';

typedef StorageOAuthCall = Future<dynamic> Function(
  String name,
  Map<String, dynamic> data,
);

/// Tokens are encrypted locally for storage. Confidential-client grants use
/// the authenticated exchange function transiently; other grants stay direct.
class StorageAuthorizationClient {
  StorageAuthorizationClient({
    http.Client Function()? createClient,
    this.exchangeCall,
  }) : createClient = createClient ?? http.Client.new;
  final http.Client Function() createClient;
  final StorageOAuthCall? exchangeCall;

  Future<Map<String, dynamic>> exchange(
    String name,
    Map<String, dynamic> data,
  ) async {
    _guard();
    final call = exchangeCall;
    if (call == null) storageConsentRequired();
    final result = await call(name, data);
    _guard();
    if (result is! Map) storageConsentRequired();
    return Map<String, dynamic>.from(result);
  }

  Future<Map<String, dynamic>> prepareExchange(String provider) =>
      exchange('prepareStorageTokenExchange', {'provider': provider});

  Future<Map<String, dynamic>> exchangeCode(
    String provider,
    Map<String, String> form,
  ) => exchange('exchangeStorageOAuthToken', {
    'provider': provider,
    'operation': 'code',
    'clientId': form['client_id'],
    'code': form['code'],
    'verifier': form['code_verifier'],
    'redirectUri': form['redirect_uri'],
  });
  bool _disposed = false;
  final _clients = <http.Client>{};
  final _deviceGrants = <String, Map<String, dynamic>>{};
  final _deviceTokens = <String>{};

  void rememberDeviceGrant(Map<String, dynamic> grant) {
    _guard();
    if (grant['accountId'] is! String || grant['accessToken'] is! String) {
      storageConsentRequired();
    }
    _deviceGrants[grant['accountId'] as String] = Map.of(grant);
  }

  Map<String, dynamic> credentialsForStorage(
    String provider,
    Map<String, dynamic> grant,
  ) => isDeviceStorageGrant(provider, grant)
      ? {
          for (final key in [
            'type',
            'grant',
            'clientId',
            'accountId',
            'accountLabel',
          ])
            key: grant[key],
        }
      : (Map<String, dynamic>.of(grant)..remove('exchangeProof'));

  Future<Map<String, dynamic>> deviceAccess(
    Map<String, dynamic> credentials, {
    String? rejectedToken,
  }) async {
    _guard();
    final id = credentials['accountId'] as String;
    final local = _deviceGrants[id];
    final expiry = local?['expiresAt'];
    if (local != null &&
        local['accessToken'] != rejectedToken &&
        expiry is num &&
        expiry > DateTime.now().millisecondsSinceEpoch + 60000) {
      return local;
    }
    final fresh = local != null && isSharedStorageGrant('google_drive', local)
        ? await refresh('google_drive', local, rejectedToken: rejectedToken)
        : await renewDeviceGrant(credentials, rejectedToken: rejectedToken);
    _guard();
    final verified = await enrich('google_drive', fresh, expectedAccountId: id);
    _guard();
    rememberDeviceGrant(verified);
    return verified;
  }

  Future<Map<String, dynamic>> renewDeviceGrant(
    Map<String, dynamic> credentials, {
    String? rejectedToken,
  }) => platform.refreshDeviceAuthorization(
    credentials,
    rejectedToken: rejectedToken,
  );

  void _guard() {
    if (_disposed) throw StateError('Storage authorization session ended');
  }

  Future<PreparedStorageAuthorization> prepare(String provider) {
    _guard();
    return platform.prepareStorageAuthorization(provider, this);
  }

  Future<bool> supports(
    String provider,
    Map<String, dynamic> credentials,
  ) async =>
      isSharedStorageGrant(provider, credentials) ||
      isDeviceStorageGrant(provider, credentials);

  Future<Map<String, dynamic>> refresh(
    String provider,
    Map<String, dynamic> credentials, {
    String? rejectedToken,
    Map<String, dynamic>? exchangeContext,
  }) async {
    _guard();
    if (['nextcloud', 'webdav'].contains(provider)) return credentials;
    if (isDeviceStorageGrant(provider, credentials)) {
      return deviceAccess(credentials, rejectedToken: rejectedToken);
    }
    if (!await supports(provider, credentials)) {
      storageConsentRequired();
    }
    final current = credentials;
    final expiry = current['expiresAt'];
    if (current['accessToken'] is String &&
        current['accessToken'] != rejectedToken &&
        expiry is num &&
        expiry > DateTime.now().millisecondsSinceEpoch + 60000) {
      return current;
    }
    if (current['refreshToken'] is! String) storageConsentRequired();
    final fresh = current['grant'] == 'oauth_exchange'
        ? await exchange('exchangeStorageOAuthToken', {
            ...?exchangeContext,
            'provider': provider,
            'operation': 'refresh',
            'clientId': current['clientId'],
            'refreshToken': current['refreshToken'],
          })
        : await tokenRequest(provider, {
            'grant_type': 'refresh_token',
            'refresh_token': current['refreshToken'] as String,
            'client_id': current['clientId'] as String,
          });
    return {...current, ...fresh};
  }

  Future<Map<String, dynamic>> tokenRequest(
    String provider,
    Map<String, String> form,
  ) async {
    final endpoint = switch (provider) {
      'google_drive' => Uri.https('oauth2.googleapis.com', '/token'),
      'dropbox' => Uri.https('api.dropboxapi.com', '/oauth2/token'),
      _ => throw const FormatException('Unsupported token provider'),
    };
    final response = await _request(
      'POST',
      endpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: Uint8List.fromList(utf8.encode(Uri(queryParameters: form).query)),
    );
    if (response.statusCode == 400 || response.statusCode == 401) {
      storageConsentRequired();
    }
    if (response.statusCode != 200) ProviderHttp.fail(response);
    final data = jsonDecode(response.body);
    if (data is! Map ||
        data['access_token'] is! String ||
        (data['access_token'] as String).isEmpty ||
        data['expires_in'] is! num ||
        !(data['expires_in'] as num).isFinite ||
        (data['expires_in'] as num) <= 0 ||
        (data['expires_in'] as num) > 86400 ||
        (data['token_type'] as String?)?.toLowerCase() != 'bearer') {
      storageConsentRequired();
    }
    return {
      'type': 'oauth',
      'accessToken': data['access_token'],
      'expiresAt':
          DateTime.now().millisecondsSinceEpoch +
          ((data['expires_in'] as num) * 1000).toInt(),
      if (data['refresh_token'] is String)
        'refreshToken': data['refresh_token'],
    };
  }

  /// Pin the provider's stable account ID, not an email or whatever Google
  /// account happens to be selected by a platform SDK during a later refresh.
  Future<Map<String, dynamic>> enrich(
    String provider,
    Map<String, dynamic> data, {
    String? expectedAccountId,
  }) async {
    final token = data['accessToken'];
    if (token is! String || token.isEmpty) storageConsentRequired();
    if (data['grant'] == 'google_device') _deviceTokens.add(token);
    final headers = {'Authorization': 'Bearer $token'};
    final response = provider == 'google_drive'
        ? await _request(
            'GET',
            Uri.https('www.googleapis.com', '/oauth2/v2/userinfo'),
            headers: headers,
          )
        : await _request(
            'POST',
            Uri.https('api.dropboxapi.com', '/2/users/get_current_account'),
            headers: headers,
          );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    final account = jsonDecode(response.body);
    if (account is! Map) storageConsentRequired();
    final accountId = account[provider == 'google_drive' ? 'id' : 'account_id'];
    if (accountId is! String ||
        accountId.isEmpty ||
        (expectedAccountId != null && accountId != expectedAccountId)) {
      storageConsentRequired();
    }
    if (provider == 'google_drive') {
      // Google may return a token when the user declines the Drive checkbox.
      final probe = await _request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'pageSize': '1',
          'fields': 'files(id)',
        }),
        headers: headers,
      );
      if (probe.statusCode != 200) storageConsentRequired();
    }
    return {
      ...data,
      'accountId': accountId,
      'accountLabel': account['email'] is String ? account['email'] : accountId,
    };
  }

  Future<bool> revoke(String provider, Map<String, dynamic> credentials) async {
    try {
      if (['nextcloud', 'webdav'].contains(provider)) {
        // DAV app passwords are revoked in the storage server's security page.
        // Never send a guessed revocation request to an arbitrary endpoint.
        return false;
      }
      // Google accepts the refresh token itself for revocation, including when
      // the access token expired or the connection is already disconnecting.
      final current =
          provider == 'google_drive' && credentials['refreshToken'] is String
          ? credentials
          : await refresh(provider, credentials);
      final token = current['accessToken'] as String? ?? '';
      final response = provider == 'google_drive'
          ? await _request(
              'POST',
              Uri.https('oauth2.googleapis.com', '/revoke'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: Uint8List.fromList(
                utf8.encode(
                  Uri(
                    queryParameters: {
                      'token': current['refreshToken'] as String? ?? token,
                    },
                  ).query,
                ),
              ),
            )
          : await _request(
              'POST',
              Uri.https('api.dropboxapi.com', '/2/auth/token/revoke'),
              headers: {'Authorization': 'Bearer $token'},
            );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
  }) async {
    _guard();
    final client = createClient();
    _clients.add(client);
    try {
      final response = await ProviderHttp(
        client,
        timeout: const Duration(seconds: 20),
      ).send(method, uri, headers: headers, body: body);
      _guard();
      return response;
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  void dispose() {
    _disposed = true;
    _deviceGrants.clear();
    for (final token in _deviceTokens) {
      unawaited(platform.clearDeviceToken(token).catchError((Object _) {}));
    }
    _deviceTokens.clear();
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
  }
}
