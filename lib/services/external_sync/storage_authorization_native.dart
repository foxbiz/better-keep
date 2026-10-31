import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_web_auth_2_platform_interface/flutter_web_auth_2_platform_interface.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import '../google_sign_in_initialization.dart';
import '../firebase_emulator_config.dart';
import 'storage_authorization.dart';
import 'storage_pkce.dart';

const _googleChannel = MethodChannel('com.betterkeep/storage_google');

Future<PreparedStorageAuthorization> prepareStorageAuthorization(
  String provider,
  StorageAuthorizationClient client,
) async {
  final exchangeConfig = provider == 'google_drive'
      ? await client.prepareExchange(provider)
      : null;
  final clientId =
      exchangeConfig?['clientId'] as String? ?? dropboxStorageClientId;
  if (clientId.isEmpty) storageConsentRequired();
  final desktop = Platform.isWindows || Platform.isLinux;
  final hostedRedirect = exchangeConfig == null
      ? hostedStorageRedirect(
          useEmulator: FirebaseEmulatorConfig.isUsingEmulators,
        )
      : Uri.parse(exchangeConfig['redirectUri'] as String);
  HttpServer? server;
  late Uri callbackEndpoint;
  if (desktop) {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    callbackEndpoint = Uri.parse(
      'http://127.0.0.1:${server.port}/storage-oauth',
    );
  } else {
    callbackEndpoint = Uri.parse('betterkeep-storage://oauth/callback');
  }
  final pkce = StoragePkce(
    provider: provider,
    clientId: clientId,
    redirect: hostedRedirect,
    returnUri: callbackEndpoint,
    offline: true,
  );
  final boundServer = server;
  StreamSubscription<HttpRequest>? subscription;
  final callback = Completer<Uri>();
  if (boundServer != null) {
    subscription = boundServer.listen((request) async {
      final uri = callbackEndpoint.replace(
        path: request.uri.path,
        query: request.uri.query,
      );
      try {
        if (request.method != 'GET' ||
            request.uri.path != callbackEndpoint.path ||
            request.headers.value('host') != callbackEndpoint.authority) {
          throw const FormatException();
        }
        pkce.validateCallback(uri);
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.headers.set('Referrer-Policy', 'no-referrer');
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><meta name="viewport" content="width=device-width">'
          '<title>Better Keep</title><p>Return to Better Keep to finish connecting.</p>'
          '<script>history.replaceState(null,"","/storage-oauth");window.close();</script>',
        );
        await request.response.close();
        if (!callback.isCompleted) callback.complete(uri);
      } catch (_) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          'Invalid authorization callback. Return to Better Keep.',
        );
        await request.response.close();
      }
    });
  }
  late StorageAuthorizationOperation operation;
  operation = StorageAuthorizationOperation(
    () async {
      final Uri result;
      if (boundServer != null) {
        if (!await launchUrl(
          pkce.authorizationUri,
          mode: LaunchMode.externalApplication,
        )) {
          storageConsentRequired();
        }
        result = await callback.future;
      } else {
        result = Uri.parse(
          await FlutterWebAuth2.authenticate(
            url: pkce.authorizationUri.toString(),
            callbackUrlScheme: callbackEndpoint.scheme,
          ),
        );
      }
      operation.requireActive();
      final grant = exchangeConfig != null
          ? await client.exchangeCode(provider, pkce.exchangeForm(result))
          : await client.tokenRequest(provider, pkce.exchangeForm(result));
      operation.requireActive();
      if (grant['refreshToken'] is! String) storageConsentRequired();
      return client.enrich(provider, {
        ...grant,
        'clientId': pkce.clientId,
        'grant': provider == 'google_drive'
            ? 'oauth_exchange'
            : 'dropbox_native',
      });
    },
    onCancel: () async {
      await subscription?.cancel();
      await boundServer?.close(force: true);
      if (boundServer == null) {
        await FlutterWebAuth2Platform.instance.clearAllDanglingCalls();
      }
    },
  );
  return operation;
}

Future<Map<String, dynamic>> _appleGrant() async {
  final value = await _googleChannel.invokeMapMethod<String, dynamic>('grant');
  if (value == null ||
      value['refreshToken'] is! String ||
      value['clientId'] is! String) {
    storageConsentRequired();
  }
  return {...value, 'type': 'oauth', 'grant': 'google_apple'};
}

/// Uses authorization only: it does not sign in/out of Firebase or switch the
/// Google authentication account. Silent renewal is pinned to the Drive owner.
Future<Map<String, dynamic>> androidGoogleGrant({
  required bool prompt,
  Map<String, dynamic>? credentials,
  String? rejectedToken,
}) async {
  await initializeNativeGoogleSignIn();
  final sdk = GoogleSignInPlatform.instance;
  if (rejectedToken != null) {
    await sdk.clearAuthorizationToken(
      ClearAuthorizationTokenParams(accessToken: rejectedToken),
    );
  }
  final result = await sdk.clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters(
      request: AuthorizationRequestDetails(
        scopes: googleStorageScopes,
        userId: credentials?['accountId'] as String?,
        email: credentials?['accountLabel'] as String?,
        promptIfUnauthorized: prompt,
      ),
    ),
  );
  if (result == null || result.accessToken.isEmpty) storageConsentRequired();
  return {
    'type': 'oauth',
    'grant': 'google_device',
    'clientId': 'google-device-v1',
    'accessToken': result.accessToken,
    // Play Services may return a cached token. Use a conservative cache window;
    // a rejected token is explicitly cleared before the single retry.
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  };
}

Future<Map<String, dynamic>> refreshDeviceAuthorization(
  Map<String, dynamic> credentials, {
  String? rejectedToken,
}) async {
  if (Platform.isAndroid) {
    return androidGoogleGrant(
      prompt: false,
      credentials: credentials,
      rejectedToken: rejectedToken,
    );
  }
  if (Platform.isIOS || Platform.isMacOS) {
    await initializeNativeGoogleSignIn();
    return _appleGrant();
  }
  storageConsentRequired();
}

// Native consent belongs to Google's SDK, not a persisted app token cache.
Future<void> clearDeviceToken(String token) async {}
