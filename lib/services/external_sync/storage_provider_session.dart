import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'dropbox_sync_transport.dart';
import 'file_sync_adapter.dart';
import 'google_drive_sync_transport.dart';
import 'nextcloud_sync_transport.dart';
import 'webdav_sync_transport.dart';
import 'provider_http.dart';
import 'portable_sync_codec.dart';
import 'storage_connection.dart';
import 'storage_authorization.dart';
import 'storage_access_cache.dart';
import 'storage_credential_broker.dart';
import 'sync_cipher.dart';
import 'sync_provider_adapter.dart';
import 'sync_revision.dart';
import 'storage_usage.dart';

/// Owns the network client and broker for exactly one connection generation.
/// Retained adapter references stop working as soon as this session is retired.
class StorageProviderSession implements SyncProviderAdapter {
  StorageProviderSession({
    required this.connection,
    this.clearing = false,
    required this.cipher,
    required String deviceId,
    required StorageBrokerCall call,
    required this.isCurrent,
    required http.Client client,
    StorageAccessCache? cache,
    StorageAuthorizationClient? authorization,
  }) {
    _client = _SessionHttpClient(client, _guard);
    _broker = StorageCredentialBroker(
      connection: connection,
      clearing: clearing,
      cipher: cipher,
      deviceId: deviceId,
      call: call,
      isCurrent: () => !_disposed && isCurrent(),
      cache: cache,
      authorization: authorization,
    );
  }

  final StorageConnection connection;
  final bool clearing;
  final SyncCipher cipher;
  final bool Function() isCurrent;
  late final http.Client _client;
  late final StorageCredentialBroker _broker;
  Future<FileSyncAdapter>? _adapter;
  bool _disposed = false;

  @override
  String get connectionId => connection.replicaId;

  void _guard() {
    if (_disposed ||
        !isCurrent() ||
        (!connection.isReady &&
            !(clearing &&
                connection.state == 'clearing' &&
                connection.clearOperationId.isNotEmpty)) ||
        connection.libraryId != cipher.libraryId) {
      throw StateError('Storage provider session has ended');
    }
  }

  Future<FileSyncAdapter> _initialize() async {
    _guard();
    final client = ProviderHttp(
      _client,
      refreshRejectedToken: (token) =>
          _broker.accessToken(rejectedToken: token),
    );
    final namespace = cipher.storageNamespace(
      connection.provider,
      connection.storageEpoch,
    );
    final SyncFileTransport transport;
    switch (connection.provider) {
      case 'google_drive':
        transport = GoogleDriveSyncTransport(
          httpClient: client,
          accessToken: _broker.accessToken,
          libraryId: namespace,
        );
      case 'dropbox':
        transport = DropboxSyncTransport(
          httpClient: client,
          accessToken: _broker.accessToken,
          libraryId: namespace,
        );
      case 'nextcloud':
      case 'webdav':
        final access = await _broker.access();
        _guard();
        if (access is! StorageDavAccess) throw const FormatException();
        Future<String> password() async {
          _guard();
          return access.password;
        }
        transport = connection.provider == 'webdav'
            ? WebDavSyncTransport(
                httpClient: client,
                server: access.server,
                username: access.username,
                appPassword: password,
                libraryId: namespace,
              )
            : NextcloudSyncTransport(
                httpClient: client,
                server: access.server,
                username: access.username,
                davUserId: access.davUserId,
                appPassword: password,
                libraryId: namespace,
              );
      default:
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    _guard();
    return FileSyncAdapter(
      connectionId: connectionId,
      transport: transport,
      cipher: cipher,
      normalizeLegacyRevision: (revision, readObject) async {
        final encrypted = await readObject(revision.payloadObjectId!);
        _guard();
        final plaintext = await cipher.decryptObject(encrypted);
        _guard();
        return PortableSyncCodec.normalizeFingerprint(
          cipher,
          revision,
          plaintext,
        );
      },
    );
  }

  Future<T> _use<T>(
    Future<T> Function(FileSyncAdapter adapter) operation,
  ) async {
    _guard();
    final pending = _adapter ??= _initialize();
    late FileSyncAdapter adapter;
    try {
      adapter = await pending;
    } catch (_) {
      if (identical(_adapter, pending)) _adapter = null;
      rethrow;
    }
    _guard();
    final result = await operation(adapter);
    _guard();
    return result;
  }

  @override
  Future<SyncChangePage> changes(String? cursor) =>
      _use((a) => a.changes(cursor));
  @override
  Future<Uint8List> readObject(String objectId) =>
      _use((a) => a.readObject(objectId));
  @override
  Future<void> putObject(String objectId, Uint8List encryptedBytes) =>
      _use((a) => a.putObject(objectId, encryptedBytes));
  @override
  Future<void> publish(SyncRevision revision) =>
      _use((a) => a.publish(revision));

  Future<StorageUsage?> readStorageUsage() => _use((adapter) async {
    final transport = adapter.transport;
    return transport is StorageUsageReader
        ? await (transport as StorageUsageReader).readStorageUsage()
        : null;
  });

  Future<void> clearLibrary() => _use((adapter) async {
    if (!clearing || adapter.transport is! SyncFileCleanup) {
      throw StateError('Cleanup was not authorized');
    }
    await (adapter.transport as SyncFileCleanup).clearLibrary();
  });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _broker.dispose();
    _client.close();
    _adapter = null;
  }
}

class _SessionHttpClient extends http.BaseClient {
  _SessionHttpClient(this.client, this.guard);
  final http.Client client;
  final void Function() guard;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    guard();
    final result = await client.send(request);
    guard();
    return result;
  }

  @override
  void close() => client.close();
}
