import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

import 'storage_authorization.dart';

import 'storage_connection.dart';
import 'storage_access_cache.dart';
import 'sync_cipher.dart';
import 'sync_provider_adapter.dart';

typedef StorageBrokerCall = Future<dynamic> Function(
  String name,
  Map<String, dynamic> data,
);

sealed class StorageAccess {}

class StorageOAuthAccess extends StorageAccess {
  StorageOAuthAccess(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
}

class StorageDavAccess extends StorageAccess {
  StorageDavAccess(this.server, this.username, this.password, {this.davUserId});
  final String? davUserId;
  final Uri server;
  final String username;
  final String password;
}

/// Lives only for one account/key/connection generation. The owner must dispose
/// it when metadata, authentication or device authorization changes.
/// Web credentials remain in memory and no secret is included in exceptions.
class StorageCredentialBroker {
  StorageCredentialBroker({
    required this.connection,
    this.clearing = false,
    required this.cipher,
    required this.deviceId,
    required this.call,
    required this.isCurrent,
    this.cache,
    StorageAuthorizationClient? authorization,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       _ownsAuthorization = authorization == null,
       authorization =
           authorization ??
           StorageAuthorizationClient(
             exchangeCall: (name, data) =>
                 call(name, {...data, 'deviceId': deviceId}),
           );
  final StorageConnection connection;
  final bool clearing;
  final StorageAuthorizationClient authorization;
  final bool _ownsAuthorization;
  final SyncCipher cipher;
  final String deviceId;
  final StorageBrokerCall call;
  final StorageAccessCache? cache;
  final bool Function() isCurrent;
  final DateTime Function() now;
  StorageAccess? _cached;
  Future<StorageAccess>? _pending;
  bool _disposed = false;
  Map<String, dynamic>? _pendingRefreshCommit;
  StorageAccess? _pendingRefreshAccess;

  void _guard() {
    if (_disposed ||
        !isCurrent() ||
        (!connection.isReady &&
            !(clearing &&
                connection.state == 'clearing' &&
                connection.clearOperationId.isNotEmpty)) ||
        connection.libraryId != cipher.libraryId) {
      throw StateError('Storage connection session has ended');
    }
  }

  Future<StorageAccess> access({String? rejectedToken}) async {
    _guard();
    final cached = _cached;
    if (cached is StorageDavAccess) return cached;
    if (cached is StorageOAuthAccess &&
        cached.token != rejectedToken &&
        cached.expiresAt.isAfter(now().add(const Duration(seconds: 60)))) {
      return cached;
    }
    // Join a refresh already in flight. If that request returned the same token
    // rejected by this caller, make one explicit rejection request afterwards.
    final pending = _pending;
    if (pending != null) {
      final result = await pending;
      _guard();
      if (rejectedToken != null &&
          result is StorageOAuthAccess &&
          result.token == rejectedToken) {
        if (identical(_pending, pending)) _pending = null;
        return access(rejectedToken: rejectedToken);
      }
      return result;
    }
    final task = _load(rejectedToken);
    _pending = task;
    try {
      return await task;
    } finally {
      if (identical(_pending, task)) _pending = null;
    }
  }

  Future<StorageAccess> _load(String? rejectedToken) async {
    try {
      if (_pendingRefreshCommit != null) {
        final result = await _finishPendingRefresh();
        if (result is! StorageOAuthAccess || result.token != rejectedToken) {
          _cached = result;
          return result;
        }
        // The retained commit must be acknowledged before refreshing again,
        // but a caller's explicitly rejected token must never be reused.
      }
      final capability = await cipher.decryptCapability(
        connection.provider,
        connection.encryptedCapability,
      );
      _guard();
      final base = {
        'provider': connection.provider,
        'deviceId': deviceId,
        'capability': capability,
        'generation': connection.generation,
      };
      var envelope = await call('getEncryptedStorageCredentials', base);
      _guard();
      var credentials = await _decrypt(envelope);
      _guard();
      if (!await authorization.supports(connection.provider, credentials)) {
        throw SyncProviderFailure(
          connection.provider == 'google_drive'
              ? SyncProviderFailureKind.sharedSetupRequired
              : SyncProviderFailureKind.reconnectRequired,
        );
      }
      _guard();
      if (isDeviceStorageGrant(connection.provider, credentials)) {
        // Device-local access never uses the shared refresh lease and is never
        // published to another device, even as an encrypted short-lived token.
        final local = await authorization.deviceAccess(
          credentials,
          rejectedToken: rejectedToken,
        );
        _guard();
        return _cached = _decode(local);
      }
      if (rejectedToken == null && !kIsWeb) {
        final restored = await _restoreCache();
        _guard();
        if (restored != null) {
          _cached = restored;
          return restored;
        }
      } else {
        await _clearCache();
        _guard();
      }
      late StorageAccess result;
      if (['nextcloud', 'webdav'].contains(connection.provider)) {
        result = _decode(credentials);
      } else {
        final expiry = credentials['expiresAt'];
        if (credentials['accessToken'] is String &&
            credentials['accessToken'] != rejectedToken &&
            expiry is num &&
            expiry > now().millisecondsSinceEpoch + 60000) {
          result = _decode(credentials);
        } else {
          // The lease/store service handles ciphertext. A provider exchange
          // endpoint may see tokens transiently when its OAuth flow requires it.
          var lease = await call('acquireStorageRefreshLease', {
            ...base,
            'revision': envelope['revision'],
          });
          _guard();
          if (lease is! Map) throw const FormatException();
          if (lease['status'] == 'changed') {
            envelope = lease;
            credentials = await _decrypt(envelope);
            _guard();
            if (!await authorization.supports(
              connection.provider,
              credentials,
            )) {
              storageConsentRequired();
            }
            _guard();
            final changedExpiry = credentials['expiresAt'];
            if (credentials['accessToken'] is String &&
                credentials['accessToken'] != rejectedToken &&
                changedExpiry is num &&
                changedExpiry > now().millisecondsSinceEpoch + 60000) {
              result = _decode(credentials);
              _cached = result;
              try {
                if (!kIsWeb) await cache?.write(_encode(result));
              } catch (_) {
                /* Optional native cache. */
              }
              _guard();
              return result;
            }
            lease = await call('acquireStorageRefreshLease', {
              ...base,
              'revision': envelope['revision'],
            });
            _guard();
          }
          if (lease is! Map ||
              lease['status'] != 'acquired' ||
              lease['leaseId'] is! String ||
              lease['fence'] is! int) {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.rateLimited,
            );
          }
          final leaseId = lease['leaseId'] as String;
          try {
            credentials = await _decrypt(lease);
            _guard();
            final refreshed = await authorization.refresh(
              connection.provider,
              credentials,
              rejectedToken: rejectedToken,
              exchangeContext: {
                ...base,
                'revision': lease['revision'],
                'leaseId': leaseId,
                'fence': lease['fence'],
              },
            );
            _guard();
            result = _decode(refreshed);
            final encrypted = await cipher.encryptCredentials(
              provider: connection.provider,
              generation: connection.generation,
              clientId: connection.clientId,
              credentials: refreshed,
            );
            _guard();
            final update = {
              ...base,
              'revision': lease['revision'],
              'leaseId': leaseId,
              'fence': lease['fence'],
              'encryptedCredentials': encrypted,
            };
            _pendingRefreshCommit = update;
            _pendingRefreshAccess = result;
            await _finishPendingRefresh();
            _guard();
          } catch (_) {
            if (!_disposed && isCurrent() && _pendingRefreshCommit == null) {
              try {
                await call('releaseStorageRefreshLease', {
                  'provider': connection.provider,
                  'deviceId': deviceId,
                  'capability': capability,
                  'leaseId': leaseId,
                });
              } catch (_) {
                /* Lease expires without exposing credentials. */
              }
            }
            rethrow;
          }
        }
      }
      _guard();
      _cached = result;
      try {
        if (!kIsWeb) await cache?.write(_encode(result));
      } catch (_) {
        /* Optional native cache. */
      }
      _guard();
      return result;
    } on FirebaseFunctionsException catch (error) {
      await _clearCache();
      _guard();
      throw SyncProviderFailure(switch (error.code) {
        'failed-precondition' ||
        'permission-denied' ||
        'unauthenticated' => SyncProviderFailureKind.reconnectRequired,
        'resource-exhausted' ||
        'aborted' => SyncProviderFailureKind.rateLimited,
        _ => SyncProviderFailureKind.unavailable,
      });
    } on SyncProviderFailure {
      rethrow;
    } on ArgumentError {
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    } on SecretBoxAuthenticationError {
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    } on FormatException {
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    } on StateError {
      rethrow;
    } catch (_) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
  }

  Future<StorageAccess> _finishPendingRefresh() async {
    _guard();
    final update = _pendingRefreshCommit!;
    final access = _pendingRefreshAccess!;
    try {
      try {
        await call('finishStorageRefresh', update);
      } on FirebaseFunctionsException catch (error) {
        _guard();
        if (![
          'unavailable',
          'deadline-exceeded',
          'internal',
        ].contains(error.code)) {
          rethrow;
        }
        await call('finishStorageRefresh', update);
      }
      _guard();
      _pendingRefreshCommit = null;
      _pendingRefreshAccess = null;
      return access;
    } on FirebaseFunctionsException catch (error) {
      if (![
        'unavailable',
        'deadline-exceeded',
        'internal',
      ].contains(error.code)) {
        _pendingRefreshCommit = null;
        _pendingRefreshAccess = null;
      }
      // Keep a rotating refresh's encrypted commit in this session until an
      // exact retry succeeds or the server rejects its generation/lease. Never
      // refresh again with the superseded provider token after a lost response.
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _decrypt(dynamic envelope) async {
    if (envelope is! Map ||
        envelope['generation'] != connection.generation ||
        envelope['clientId'] != connection.clientId ||
        envelope['revision'] is! int ||
        (envelope['revision'] as int) < 1 ||
        envelope['encryptedCredentials'] is! String) {
      throw const FormatException('Invalid encrypted credential record');
    }
    return cipher.decryptCredentials(
      provider: connection.provider,
      generation: connection.generation,
      clientId: connection.clientId,
      encrypted: envelope['encryptedCredentials'] as String,
    );
  }

  StorageAccess _decode(dynamic data) {
    if (data is! Map) throw const FormatException();
    late StorageAccess result;
    if (data['type'] == 'oauth' &&
        !['nextcloud', 'webdav'].contains(connection.provider) &&
        _isSecret(data['accessToken']) &&
        data['expiresAt'] is num) {
      final expiry = data['expiresAt'] as num;
      if (!expiry.isFinite ||
          expiry <= now().millisecondsSinceEpoch ||
          expiry > 8640000000000000) {
        throw const FormatException();
      }
      result = StorageOAuthAccess(
        data['accessToken'] as String,
        DateTime.fromMillisecondsSinceEpoch(expiry.toInt(), isUtc: true),
      );
    } else if (data['type'] == 'app_password' &&
        ['nextcloud', 'webdav'].contains(connection.provider) &&
        _isSecret(data['server']) &&
        _isSecret(data['username']) &&
        _isSecret(data['appPassword'])) {
      final server = Uri.parse(data['server'] as String);
      final username = data['username'] as String;
      final davUserId = data['davUserId'];
      if (server.scheme != 'https' ||
          server.host.isEmpty ||
          server.userInfo.isNotEmpty ||
          server.hasQuery ||
          server.hasFragment ||
          username.contains(':') ||
          (davUserId != null &&
              (!_isSecret(davUserId) ||
                  davUserId == '.' ||
                  davUserId == '..' ||
                  (davUserId as String).contains('/')))) {
        throw const FormatException();
      }
      result = StorageDavAccess(
        server,
        username,
        data['appPassword'] as String,
        davUserId: davUserId as String?,
      );
    } else {
      throw const FormatException();
    }
    return result;
  }

  Map<String, dynamic> _encode(StorageAccess access) => switch (access) {
    StorageOAuthAccess() => {
      'type': 'oauth',
      'accessToken': access.token,
      'expiresAt': access.expiresAt.millisecondsSinceEpoch,
    },
    StorageDavAccess() => {
      'type': 'app_password',
      'server': access.server.toString(),
      'username': access.username,
      'appPassword': access.password,
      'davUserId': ?access.davUserId,
    },
  };

  Future<StorageAccess?> _restoreCache() async {
    if (cache == null) return null;
    try {
      final data = await cache!.read();
      _guard();
      if (data == null) return null;
      final value = _decode(data);
      if (value is! StorageOAuthAccess ||
          value.expiresAt.isAfter(now().add(const Duration(seconds: 60)))) {
        return value;
      }
    } catch (_) {
      _guard();
    }
    await _clearCache();
    return null;
  }

  Future<void> _clearCache() async {
    try {
      await cache?.clear();
    } catch (_) {
      /* Never expose a secure storage error's contents. */
    }
  }

  Future<String> accessToken({String? rejectedToken}) async {
    final value = await access(rejectedToken: rejectedToken);
    _guard();
    if (value is! StorageOAuthAccess) {
      throw StateError('OAuth connection required');
    }
    return value.token;
  }

  void dispose() {
    _disposed = true;
    _cached = null;
    _pendingRefreshCommit = null;
    _pendingRefreshAccess = null;
    if (_ownsAuthorization) authorization.dispose();
    unawaited(_clearCache());
  }

  static bool _isSecret(dynamic value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 16384 &&
      !value.codeUnits.any((c) => c < 32);
}
