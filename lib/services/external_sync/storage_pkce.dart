import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_cipher.dart';
import 'storage_authorization_types.dart';

/// Reuse the configured development origin; never send emulator callbacks to
/// production or expose a private development hostname in source code.
Uri hostedStorageRedirect({
  required bool useEmulator,
  String developmentOrigin = const String.fromEnvironment(
    'EMULATOR_WEB_ORIGIN',
  ),
}) {
  final origin = Uri.tryParse(
    useEmulator ? developmentOrigin.trim() : 'https://betterkeep.app',
  );
  if (origin == null ||
      origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      (origin.path.isNotEmpty && origin.path != '/')) {
    storageConsentRequired();
  }
  return origin.resolve('/oauth/storage/callback');
}

class StoragePkce {
  StoragePkce({
    required this.provider,
    required this.clientId,
    required this.redirect,
    required this.offline,
    this.returnUri,
  }) : verifier = SyncCipher.newCapability() {
    if (!['google_drive', 'dropbox'].contains(provider) || clientId.isEmpty) {
      storageConsentRequired();
    }
    var prefix = '';
    final target = returnUri;
    if (target != null) {
      if (redirect.scheme != 'https') {
        storageConsentRequired();
      }
      if (target.toString() == 'betterkeep-storage://oauth/callback') {
        prefix = 'app.';
      } else if (target.scheme == 'http' &&
          target.host == '127.0.0.1' &&
          target.port >= 1024 &&
          target.port <= 65535 &&
          target.path == '/storage-oauth' &&
          target.userInfo.isEmpty &&
          !target.hasQuery &&
          !target.hasFragment) {
        prefix = 'loopback.${target.port}.';
      } else {
        storageConsentRequired();
      }
    }
    // The relay destination is public routing data; all 256 random bits remain.
    state = '$prefix${SyncCipher.newCapability()}';
  }
  final String provider;
  final String clientId;
  final Uri redirect;
  final bool offline;

  /// Local delivery endpoint, distinct from the provider's registered HTTPS URI.
  final Uri? returnUri;
  late final String state;
  final String verifier;

  Uri get authorizationUri => Uri.https(
    provider == 'google_drive' ? 'accounts.google.com' : 'www.dropbox.com',
    provider == 'google_drive' ? '/o/oauth2/v2/auth' : '/oauth2/authorize',
    {
      'client_id': clientId,
      'redirect_uri': redirect.toString(),
      'response_type': 'code',
      'state': state,
      'code_challenge_method': 'S256',
      'code_challenge': base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', ''),
      if (provider == 'google_drive') ...{
        'scope': googleStorageScopes.join(' '),
        'access_type': 'offline',
        'prompt': 'consent',
      } else ...{
        'scope': 'account_info.read files.metadata.read files.content.read files.content.write',
        'token_access_type': offline ? 'offline' : 'online',
      },
    },
  );

  /// Accept a well-formed denial too, so local listeners can finish immediately
  /// instead of leaving the app waiting until authorization times out.
  void validateCallback(Uri callback) {
    final expected = returnUri ?? redirect;
    if (callback.scheme != expected.scheme ||
        callback.host != expected.host ||
        callback.port != expected.port ||
        (callback.path != expected.path &&
            !(expected.path.endsWith('.html') &&
                callback.path ==
                    expected.path.substring(0, expected.path.length - 5))) ||
        callback.userInfo.isNotEmpty ||
        callback.hasFragment ||
        callback.queryParametersAll['state']?.length != 1 ||
        callback.queryParameters['state'] != state) {
      storageConsentRequired();
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      if (callback.queryParametersAll['error']?.length != 1 ||
          error.isEmpty ||
          error.length > 128 ||
          callback.queryParameters.containsKey('code')) {
        storageConsentRequired();
      }
      return;
    }
    final code = callback.queryParameters['code'];
    if (callback.queryParametersAll['code']?.length != 1 ||
        code == null ||
        code.isEmpty ||
        code.length > 8192) {
      storageConsentRequired();
    }
  }

  Map<String, String> exchangeForm(Uri callback) {
    validateCallback(callback);
    if (callback.queryParameters.containsKey('error')) storageConsentRequired();
    return {
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'redirect_uri': redirect.toString(),
      'code': callback.queryParameters['code']!,
      'code_verifier': verifier,
    };
  }
}
