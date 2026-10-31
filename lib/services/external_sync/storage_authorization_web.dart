import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'storage_authorization.dart';
import 'storage_pkce.dart';
import 'sync_provider_adapter.dart';

Future<PreparedStorageAuthorization> prepareStorageAuthorization(
  String provider,
  StorageAuthorizationClient client,
) async {
  final exchangeConfig = provider == 'google_drive'
      ? await client.prepareExchange(provider)
      : null;
  final clientId =
      exchangeConfig?['clientId'] as String? ?? dropboxStorageClientId;
  if (!['google_drive', 'dropbox'].contains(provider) || clientId.isEmpty) {
    storageConsentRequired();
  }
  final redirect = exchangeConfig == null
      ? Uri.parse(web.document.baseURI).resolve('/oauth/storage/callback')
      : Uri.parse(exchangeConfig['redirectUri'] as String);
  // postMessage delivery is restricted to the application origin.
  if ((exchangeConfig != null &&
          redirect.origin != web.window.location.origin) ||
      (redirect.scheme != 'https' &&
          !(redirect.scheme == 'http' && redirect.host == 'localhost'))) {
    storageConsentRequired();
  }
  final pkce = StoragePkce(
    provider: provider,
    clientId: clientId,
    redirect: redirect,
    offline: true,
  );
  web.Window? popup;
  JSFunction? listener;
  Timer? closedPoll;
  late StorageAuthorizationOperation operation;
  operation = StorageAuthorizationOperation(
    () async {
      final completer = Completer<Uri>();
      listener = ((web.MessageEvent event) {
        if (event.origin != redirect.origin ||
            event.source != popup ||
            completer.isCompleted) {
          return;
        }
        final raw = event.data.dartify();
        if (raw is! Map ||
            raw['type'] != 'betterkeep-storage-oauth' ||
            raw['url'] is! String) {
          return;
        }
        try {
          final uri = Uri.parse(raw['url'] as String);
          pkce.exchangeForm(uri);
          completer.complete(uri);
        } catch (_) {
          completer.completeError(
            StateError('Invalid storage authorization callback'),
          );
        }
      }).toJS;
      web.window.addEventListener('message', listener);
      popup = web.window.open(
        pkce.authorizationUri.toString(),
        '_blank',
        // Let the browser open a regular tab. Embedded browsers can return a
        // window handle for popup-only windows without ever displaying them.
        '',
      );
      if (popup == null) storageConsentRequired();
      closedPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (completer.isCompleted) {
          closedPoll?.cancel();
        } else if (popup!.closed) {
          completer.completeError(
            const SyncProviderFailure(
              SyncProviderFailureKind.reconnectRequired,
            ),
          );
        }
      });
      final result = await completer.future;
      operation.requireActive();
      final grant = exchangeConfig != null
          ? await client.exchangeCode(provider, pkce.exchangeForm(result))
          : await client.tokenRequest(provider, pkce.exchangeForm(result));
      operation.requireActive();
      if (grant['refreshToken'] is! String) storageConsentRequired();
      return client.enrich(provider, {
        ...grant,
        'clientId': clientId,
        'grant': exchangeConfig != null ? 'oauth_exchange' : 'dropbox_web',
      });
    },
    onCancel: () async {
      closedPoll?.cancel();
      if (listener != null) web.window.removeEventListener('message', listener);
      popup?.close();
    },
  );
  return operation;
}

Future<Map<String, dynamic>> refreshDeviceAuthorization(
  Map<String, dynamic> credentials, {
  String? rejectedToken,
}) async => storageConsentRequired();

Future<void> clearDeviceToken(String token) async {}
