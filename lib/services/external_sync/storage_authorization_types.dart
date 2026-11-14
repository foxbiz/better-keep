import 'dart:async';

import 'sync_provider_adapter.dart';

const googleStorageScopes = [
  'https://www.googleapis.com/auth/drive.appdata',
  'https://www.googleapis.com/auth/userinfo.email',
];

const googleDesktopStorageClientId = String.fromEnvironment(
  'GOOGLE_DRIVE_DESKTOP_CLIENT_ID',
);
const googleWebStorageClientId = String.fromEnvironment(
  'GOOGLE_DRIVE_WEB_CLIENT_ID',
);

/// An account binding, not a refresh grant. Each device authorizes this account
/// with Google directly. Only this identity is encrypted into the shared record.
bool isDeviceStorageGrant(String provider, Map<String, dynamic> credentials) =>
    provider == 'google_drive' &&
    credentials['type'] == 'oauth' &&
    credentials['grant'] == 'google_device' &&
    credentials['clientId'] == 'google-device-v1' &&
    credentials['accountId'] is String &&
    (credentials['accountId'] as String).isNotEmpty &&
    credentials['accountLabel'] is String &&
    (credentials['accountLabel'] as String).isNotEmpty;

const dropboxStorageClientId = String.fromEnvironment('DROPBOX_CLIENT_ID');

/// The encrypted issuing client ID travels with its grant. Refresh never uses
/// this device's OAuth configuration or requires its own provider sign-in.
bool isSharedStorageGrant(String provider, Map<String, dynamic> credentials) {
  if (['nextcloud', 'webdav'].contains(provider)) {
    return credentials['type'] == 'app_password';
  }
  bool nonempty(String key) =>
      credentials[key] is String && (credentials[key] as String).isNotEmpty;
  if (credentials['type'] != 'oauth' ||
      !nonempty('clientId') ||
      !nonempty('accountId') ||
      !nonempty('refreshToken')) {
    return false;
  }
  return switch (provider) {
    'google_drive' => const [
      'oauth_exchange',
      'google_apple',
      'google_desktop',
    ].contains(credentials['grant']),
    'dropbox' => const [
      'dropbox_native',
      'dropbox_web',
    ].contains(credentials['grant']),
    _ => false,
  };
}

abstract class PreparedStorageAuthorization {
  Future<Map<String, dynamic>> authorize();
  Future<void> cancel();
}

Never storageConsentRequired() =>
    throw const SyncProviderFailure(SyncProviderFailureKind.reconnectRequired);

/// A bounded, cancellable authorization owned by one controller session.
class StorageAuthorizationOperation implements PreparedStorageAuthorization {
  StorageAuthorizationOperation(this.run, {this.onCancel});
  final Future<Map<String, dynamic>> Function() run;
  final Future<void> Function()? onCancel;
  final _cancelled = Completer<Map<String, dynamic>>();
  bool _started = false;
  bool _closed = false;

  void requireActive() {
    if (_closed) storageConsentRequired();
  }

  @override
  Future<Map<String, dynamic>> authorize() async {
    if (_started || _closed) storageConsentRequired();
    _started = true;
    try {
      final result = await Future.any([run(), _cancelled.future])
          .timeout(const Duration(minutes: 10));
      if (_closed) storageConsentRequired();
      return result;
    } finally {
      _closed = true;
      await onCancel?.call();
    }
  }

  @override
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    // No unhandled error when cancelled before authorize starts.
    if (_started && !_cancelled.isCompleted) _cancelled.complete({});
    await onCancel?.call();
  }
}
