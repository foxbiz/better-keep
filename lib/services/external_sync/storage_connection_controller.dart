import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../cloud_functions_helper.dart';
import '../firebase_backend.dart';
import '../firebase_sync_preference.dart';
import 'nextcloud_sync_transport.dart';
import 'webdav_sync_transport.dart';
import 'nextcloud_login_flow.dart';
import 'provider_http.dart';
import 'storage_connection.dart';
import 'storage_authorization.dart';
import 'storage_access_cache.dart';
import 'storage_credential_broker.dart';
import 'storage_provider_session.dart';
import 'sync_cipher.dart';
import 'sync_provider_adapter.dart';
import 'storage_usage.dart';

enum StorageConnectionAction {
  preparing,
  awaitingConsent,
  authorizing,
  connecting,
  pausing,
  enabling,
  disconnecting,
  clearing,
  cancelling,
  cancelPending,
}

/// One approved account/key session. All secrets used to complete browser
/// authorization live here in memory, never in routes or persistent web storage.
class StorageConnectionController extends ChangeNotifier {
  StorageConnectionController({
    required this.cipher,
    required this.deviceId,
    required this.isCurrent,
    required this.call,
    required this.readConnection,
    required Stream<Map<String, Map<String, dynamic>>> metadata,
    required this.launchAuthorization,
    this.preference,
    http.Client Function()? createClient,
    this.createAccessCache,
    StorageAuthorizationClient? authorization,
    Future<void> Function(StorageDavAccess access)? probeNextcloud,
    DateTime Function()? now,
  }) : createClient = createClient ?? http.Client.new,
       now = now ?? DateTime.now,
       authorization =
           authorization ??
           StorageAuthorizationClient(
             createClient: createClient,
             exchangeCall: (name, data) async {
               if (!isCurrent()) storageConsentRequired();
               final result = await call(name, {...data, 'deviceId': deviceId});
               if (!isCurrent()) storageConsentRequired();
               return result;
             },
           ) {
    _probeNextcloud = probeNextcloud ?? _probe;
    preference?.addListener(_selectionChanged);
    _subscription = metadata.listen(
      _receiveMetadata,
      onError: (Object _) {
        if (!_active) return;
        metadataFailure = SyncProviderFailureKind.unavailable;
        notifyListeners();
      },
    );
  }

  factory StorageConnectionController.firebase({
    required String uid,
    required SyncCipher cipher,
    required String deviceId,
    required bool Function() isCurrent,
  }) {
    final collection = FirebaseBackend.firestore
        .collection('users')
        .doc(uid)
        .collection('storage_connections');
    return StorageConnectionController(
      cipher: cipher,
      preference: FirebaseSyncPreference.instance,
      deviceId: deviceId,
      isCurrent: isCurrent,
      call: (name, data) async => (await callCloudFunction(name, data)).data,
      readConnection: (provider) async =>
          (await collection
                  .doc(provider)
                  .get(const GetOptions(source: Source.server)))
              .data(),
      metadata: collection
          .snapshots(includeMetadataChanges: true)
          .where(
            (snapshot) =>
                !snapshot.metadata.isFromCache || snapshot.docs.isNotEmpty,
          )
          .map(
            (snapshot) => {for (final doc in snapshot.docs) doc.id: doc.data()},
          ),
      launchAuthorization: (uri) =>
          launchUrl(uri, mode: LaunchMode.externalApplication),
      createAccessCache: (connection, current) => SecureStorageAccessCache(
        namespace: FirebaseBackend.localDataScope.secureStorageKey(
          'external_sync.access',
        ),
        uid: uid,
        deviceId: deviceId,
        libraryId: cipher.libraryId,
        provider: connection.provider,
        generation: connection.generation,
        isCurrent: current,
      ),
    );
  }

  static const providers = ['google_drive', 'dropbox', 'nextcloud', 'webdav'];
  final SyncCipher cipher;
  final String deviceId;
  final bool Function() isCurrent;
  final StorageBrokerCall call;
  final StorageAuthorizationClient authorization;
  final _labels = <String, String>{};
  final _labelLoads = <String>{};
  final Future<Map<String, dynamic>?> Function(String provider) readConnection;
  final Future<bool> Function(Uri uri) launchAuthorization;
  final FirebaseSyncPreference? preference;

  bool isSelected(String provider) =>
      preference?.allowsProvider(provider) ?? true;

  void _selectionChanged() {
    if (!_active) return;
    for (final provider in providers) {
      _reconcile(provider);
    }
    notifyListeners();
  }

  final http.Client Function() createClient;
  final StorageAccessCache? Function(
    StorageConnection connection,
    bool Function() isCurrent,
  )?
  createAccessCache;
  final DateTime Function() now;
  late final Future<void> Function(StorageDavAccess access) _probeNextcloud;
  late final StreamSubscription<Map<String, Map<String, dynamic>>>
  _subscription;
  final _connections = <String, StorageConnection>{};
  final _sessions = <String, StorageProviderSession>{};
  final _actions = <String, StorageConnectionAction>{};
  final _errors = <String, SyncProviderFailureKind>{};
  final _authorizations = <String, _StorageAuthorization>{};
  final _busy = <String>{};
  final _awaitingMetadata = <String>{};
  final _localStops = <String, int>{};
  final _invalidMetadata = <String>{};
  final _closed = Completer<void>();
  final _metadataReady = Completer<void>();
  bool get hasMetadata => _metadataReady.isCompleted;
  bool get hasInvalidMetadata => _invalidMetadata.isNotEmpty;
  final _nextcloudLogins = <NextcloudLoginFlow>{};
  bool _disposed = false;
  SyncProviderFailureKind? metadataFailure;

  bool get _active => !_disposed && isCurrent();
  Map<String, StorageConnection> get connections =>
      Map.unmodifiable(_connections);
  Map<String, StorageConnectionAction> get actions =>
      Map.unmodifiable(_actions);
  Map<String, SyncProviderFailureKind> get errors => Map.unmodifiable(_errors);
  bool isBusy(String provider) => _busy.contains(provider);
  bool canCancelOAuth(String provider) => _authorizations.containsKey(provider);
  bool isLocallyStopped(String provider) => _localStops.containsKey(provider);
  bool needsKeyRecovery(String provider) =>
      _connections[provider]?.libraryId != null &&
      _connections[provider]!.libraryId != cipher.libraryId;

  List<SyncProviderAdapter> get adapters {
    _guard();
    return List.unmodifiable(_sessions.values);
  }

  void _guard() {
    if (!_active) throw StateError('Storage account session has ended');
  }

  void _checkProvider(String provider) {
    _guard();
    if (!providers.contains(provider)) {
      throw ArgumentError('Unsupported storage provider');
    }
  }

  Future<void> waitForMetadata() async {
    _guard();
    if (metadataFailure != null) throw SyncProviderFailure(metadataFailure!);
    await Future.any([_metadataReady.future, _closed.future])
        .timeout(const Duration(seconds: 10));
    _guard();
    if (metadataFailure != null) throw SyncProviderFailure(metadataFailure!);
  }

  void _receiveMetadata(Map<String, Map<String, dynamic>> values) {
    if (!_active) return;
    metadataFailure = null;
    if (!_metadataReady.isCompleted) _metadataReady.complete();
    for (final provider in providers) {
      final data = values[provider];
      if (data == null) {
        if (_awaitingMetadata.contains(provider)) continue;
        _connections.remove(provider);
        _invalidMetadata.remove(provider);
        if (_errors[provider] == SyncProviderFailureKind.corruptData) {
          _errors.remove(provider);
        }
        _sessions.remove(provider)?.dispose();
        continue;
      }
      try {
        _adopt(provider, data, fromStream: true);
      } catch (_) {
        _invalidMetadata.add(provider);
        _errors[provider] = SyncProviderFailureKind.corruptData;
        _sessions.remove(provider)?.dispose();
      }
    }
    notifyListeners();
  }

  void _adopt(
    String provider,
    Map<String, dynamic> data, {
    bool fromStream = false,
  }) {
    var next = StorageConnection.fromJson(data);
    final label = _labels[next.replicaId];
    if (label != null) next = next.withAccountLabel(label);
    if (next.provider != provider) throw const FormatException();
    final current = _connections[provider];
    if (current != null &&
        (next.generation < current.generation ||
            (next.generation == current.generation &&
                next.updatedAt < current.updatedAt))) {
      return;
    }
    _invalidMetadata.remove(provider);
    if (fromStream) {
      _awaitingMetadata.remove(provider);
    } else {
      _awaitingMetadata.add(provider);
    }
    final stoppedAt = _localStops[provider];
    if (stoppedAt != null && next.updatedAt > stoppedAt) {
      _localStops.remove(provider);
    }
    // Errors belong to the previous connection, not a new grant restored from
    // another device. Ordinary metadata updates must retain actionable errors.
    if (_errors[provider] == SyncProviderFailureKind.corruptData ||
        current == null ||
        !current.hasSameSession(next)) {
      _errors.remove(provider);
    }
    _connections[provider] = next;
    _reconcile(provider);
    if (next.hasEncryptedCredentials &&
        next.state == 'ready' &&
        next.libraryId == cipher.libraryId &&
        label == null &&
        _labelLoads.add(next.replicaId)) {
      unawaited(_hydrateLabel(next));
    }
  }

  void _reconcile(String provider) {
    final next = _connections[provider];
    final existing = _sessions[provider];
    if (!_active ||
        next == null ||
        !next.isReady ||
        !isSelected(provider) ||
        needsKeyRecovery(provider) ||
        isBusy(provider) ||
        _authorizations[provider]?.cancelRequested == true ||
        _invalidMetadata.contains(provider) ||
        isLocallyStopped(provider)) {
      _sessions.remove(provider)?.dispose();
      return;
    }
    if (existing != null && existing.connection.hasSameSession(next)) return;
    existing?.dispose();
    late StorageProviderSession session;
    bool currentSession() => _active && identical(_sessions[provider], session);
    session = StorageProviderSession(
      connection: next,
      cipher: cipher,
      deviceId: deviceId,
      call: call,
      authorization: authorization,
      client: createClient(),
      isCurrent: currentSession,
      cache: createAccessCache?.call(next, currentSession),
    );
    _sessions[provider] = session;
  }

  Future<T> _perform<T>(
    String provider,
    StorageConnectionAction action,
    Future<T> Function() operation,
  ) async {
    _checkProvider(provider);
    if (isBusy(provider)) {
      throw StateError('Storage action already in progress');
    }
    _busy.add(provider);
    _actions[provider] = action;
    _errors.remove(provider);
    _reconcile(provider);
    notifyListeners();
    try {
      final result = await operation();
      _guard();
      return result;
    } catch (error) {
      if (error is _StorageAuthorizationCancelled) rethrow;
      if (!_active) throw StateError('Storage account session has ended');
      final failure = _failure(error);
      _errors[provider] = failure.kind;
      throw failure;
    } finally {
      _busy.remove(provider);
      if (_active) {
        _settleAction(provider);
        _reconcile(provider);
        notifyListeners();
      }
    }
  }

  void _settleAction(String provider) {
    if (!_busy.contains(provider)) {
      final flow = _authorizations[provider];
      if (flow == null) {
        _actions.remove(provider);
      } else {
        _actions[provider] = flow.cancelRequested
            ? StorageConnectionAction.cancelPending
            : StorageConnectionAction.awaitingConsent;
      }
    }
  }

  void _guardAuthorization(_StorageAuthorization flow) {
    _guard();
    if (flow.cancelRequested) throw const _StorageAuthorizationCancelled();
    if (!flow.expiresAt.isAfter(now())) storageConsentRequired();
  }

  /// The grant never goes through the backend. Cancelling before registration
  /// discards it locally; if registration has started, await its exact outcome.
  Future<bool> cancelOAuth(String provider) async {
    _checkProvider(provider);
    final flow = _authorizations[provider];
    if (flow == null) return true;
    if (flow.sent) {
      try {
        await flow.registering;
        return false;
      } catch (_) {
        _guard();
        // Registration already settled with an error; cancellation must not
        // rethrow that old future or leave the dialog permanently blocked.
      }
    }
    flow.cancel();
    await flow.authorization.cancel();
    if (identical(_authorizations[provider], flow)) {
      _authorizations.remove(provider);
    }
    if (_active) {
      _settleAction(provider);
      _reconcile(provider);
      notifyListeners();
    }
    return true;
  }

  Future<void> prepareOAuth(String provider) =>
      _perform(provider, StorageConnectionAction.preparing, () async {
        if (['nextcloud', 'webdav'].contains(provider)) {
          throw const FormatException();
        }
        final previous = _authorizations.remove(provider);
        await previous?.authorization.cancel();
        final expectedConnection = _connections[provider];
        final prepared = await authorization.prepare(provider);
        if (!_active) {
          await prepared.cancel();
          _guard();
        }
        _authorizations[provider] = _StorageAuthorization(
          prepared,
          now().add(const Duration(minutes: 10)),
          expectedConnection: expectedConnection,
        );
      });

  Future<void> authorizeOAuth(String provider) async {
    _StorageAuthorization? ownedFlow;
    try {
      await _perform(provider, StorageConnectionAction.authorizing, () async {
        final flow = _authorizations[provider];
        ownedFlow = flow;
        if (flow == null || !flow.expiresAt.isAfter(now())) {
          storageConsentRequired();
        }
        _guardAuthorization(flow);
        late Map<String, dynamic> grant;
        try {
          grant = await flow.authorization.authorize();
        } finally {
          _guardAuthorization(flow);
        }
        final registration = _registerCredentials(
          provider,
          grant,
          pinConnection: provider == 'google_drive',
          expectedConnection: flow.expectedConnection,
          beforeSend: () {
            _guardAuthorization(flow);
            flow.sent = true;
          },
        );
        flow.registering = registration;
        await registration;
        _guardAuthorization(flow);
        if (identical(_authorizations[provider], flow)) {
          _authorizations.remove(provider);
        }
      });
    } on _StorageAuthorizationCancelled {
      // User cancellation never registers a late provider response.
    } finally {
      // A rejected duplicate invocation never owns the active consent. Nor may
      // an old completion discard a replacement prepared while it was pending.
      if (ownedFlow != null &&
          identical(_authorizations[provider], ownedFlow)) {
        await _discardAuthorization(provider);
      }
      if (_active && ownedFlow != null && !isBusy(provider)) {
        _settleAction(provider);
        notifyListeners();
      }
    }
  }

  Future<void> _discardAuthorization(String provider) async {
    final flow = _authorizations.remove(provider);
    if (flow == null) return;
    flow.cancel();
    await flow.authorization.cancel();
  }

  Future<void> _registerCredentials(
    String provider,
    Map<String, dynamic> credentials, {
    void Function()? beforeSend,
    bool pinConnection = false,
    StorageConnection? expectedConnection,
  }) async {
    if (!await authorization.supports(provider, credentials)) {
      throw SyncProviderFailure(
        provider == 'google_drive'
            ? SyncProviderFailureKind.sharedSetupRequired
            : SyncProviderFailureKind.reconnectRequired,
      );
    }
    _guard();
    final capability = SyncCipher.newCapability();
    final previous = await _capability(provider, optional: true);
    final currentData = await readConnection(provider);
    _guard();
    if (pinConnection &&
        (expectedConnection == null
            ? currentData != null && currentData['state'] != 'disconnected'
            : currentData == null ||
                  !StorageConnection.fromJson(currentData)
                      .hasSameSession(expectedConnection))) {
      storageConsentRequired();
    }
    if (provider == 'google_drive' &&
        currentData != null &&
        currentData['state'] == 'ready' &&
        previous != null) {
      final existing = StorageConnection.fromJson(currentData);
      final saved = await _credentials(existing, previous);
      _guard();
      if (credentials['accountId'] != saved['accountId']) {
        storageConsentRequired();
      }
      if (isDeviceStorageGrant(provider, saved) &&
          isDeviceStorageGrant(provider, credentials)) {
        final latest = await readConnection(provider);
        _guard();
        if (credentials['accountId'] != saved['accountId'] ||
            latest == null ||
            !StorageConnection.fromJson(latest).hasSameSession(existing)) {
          storageConsentRequired();
        }
        beforeSend?.call();
        authorization.rememberDeviceGrant(credentials);
        _adopt(provider, latest);
        return;
      }
    }
    final generation = (currentData?['generation'] as int? ?? 0) + 1;
    final clientId = credentials['clientId'] as String? ?? '';
    final encryptedCapability = await cipher.encryptCapability(
      provider,
      capability,
    );
    final encryptedCredentials = await cipher.encryptCredentials(
      provider: provider,
      generation: generation,
      clientId: clientId,
      credentials: authorization.credentialsForStorage(provider, credentials),
    );
    _guard();
    beforeSend?.call();
    final registration = <String, dynamic>{
      'provider': provider,
      'deviceId': deviceId,
      'libraryId': cipher.libraryId,
      'capability': capability,
      'previousCapability': ?previous,
      'exchangeProof': ?credentials['exchangeProof'],
      'encryptedCapability': encryptedCapability,
      'encryptedCredentials': encryptedCredentials,
      'generation': generation,
      'clientId': clientId,
    };
    dynamic result;
    try {
      result = await call('registerEncryptedStorageConnection', registration);
    } on FirebaseFunctionsException catch (error) {
      _guard();
      if (![
        'unavailable',
        'deadline-exceeded',
        'internal',
      ].contains(error.code)) {
        rethrow;
      }
      // Same capability, generation and ciphertext: recover a lost response
      // without reauthorizing or registering a different connection.
      result = await call('registerEncryptedStorageConnection', registration);
    }
    _guard();
    if (result is! Map) throw const FormatException();
    final data = Map<String, dynamic>.from(result);
    await _validateGrant(provider, capability, data);
    _guard();
    if (isDeviceStorageGrant(provider, credentials)) {
      authorization.rememberDeviceGrant(credentials);
    }
    _labels.removeWhere((key, _) => key.startsWith('$provider:'));
    _labels[StorageConnection.fromJson(data).replicaId] =
        credentials['accountLabel'] as String? ?? '';
    _adopt(provider, data);
  }

  Future<Map<String, dynamic>> _credentials(
    StorageConnection connection,
    String capability,
  ) async {
    final result = await call('getEncryptedStorageCredentials', {
      'provider': connection.provider,
      'deviceId': deviceId,
      'capability': capability,
      'generation': connection.generation,
    });
    _guard();
    if (result is! Map ||
        result['generation'] != connection.generation ||
        result['clientId'] != connection.clientId ||
        result['encryptedCredentials'] is! String) {
      throw const FormatException();
    }
    final value = await cipher.decryptCredentials(
      provider: connection.provider,
      generation: connection.generation,
      clientId: connection.clientId,
      encrypted: result['encryptedCredentials'] as String,
    );
    _guard();
    return value;
  }

  Future<void> _hydrateLabel(StorageConnection connection) async {
    try {
      final capability = await cipher.decryptCapability(
        connection.provider,
        connection.encryptedCapability,
      );
      _guard();
      final credentials = await _credentials(connection, capability);
      if (_connections[connection.provider]?.generation !=
          connection.generation) {
        return;
      }
      final label = credentials['accountLabel'];
      if (label is! String || label.length > 512) return;
      _labels[connection.replicaId] = label;
      _connections[connection.provider] = _connections[connection.provider]!
          .withAccountLabel(label);
      notifyListeners();
    } catch (_) {
      _labelLoads.remove(connection.replicaId);
    }
  }

  NextcloudLoginFlow createNextcloudLogin(Uri server) {
    _guard();
    // Validate before allocating an HTTP client.
    NextcloudLoginFlow.normalizeServer(server);
    late final NextcloudLoginFlow flow;
    flow = NextcloudLoginFlow(
      server: server,
      client: createClient(),
      isCurrent: () => _active,
      launch: launchAuthorization,
      now: now,
      onDispose: () => _nextcloudLogins.remove(flow),
    );
    _nextcloudLogins.add(flow);
    return flow;
  }

  Future<void> connectNextcloud(StorageDavAccess access) =>
      _connectDav('nextcloud', access);

  Future<void> connectWebDav(StorageDavAccess access) =>
      _connectDav('webdav', access);

  Future<void> _connectDav(String provider, StorageDavAccess access) =>
      _perform(provider, StorageConnectionAction.connecting, () async {
        if (provider == 'nextcloud') {
          await _probeNextcloud(access);
        } else {
          await _probe(access, generic: true);
        }
        _guard();
        await _registerCredentials(provider, {
          'type': 'app_password',
          'clientId': '',
          'server': access.server.toString(),
          'username': access.username,
          'appPassword': access.password,
          'davUserId': ?access.davUserId,
          'accountLabel': access.username,
        });
      });

  Future<void> _validateGrant(
    String provider,
    String capability,
    Map<String, dynamic> data,
  ) async {
    final connection = StorageConnection.fromJson(data);
    if (connection.provider != provider ||
        connection.libraryId != cipher.libraryId ||
        await cipher.decryptCapability(
              provider,
              connection.encryptedCapability,
            ) !=
            capability) {
      throw const FormatException('Wrong storage grant context');
    }
  }

  Future<void> _probe(StorageDavAccess access, {bool generic = false}) async {
    final client = createClient();
    try {
      final httpClient = ProviderHttp(client, isCurrent: () => _active);
      Future<String> password() async {
        _guard();
        return access.password;
      }

      final transport = generic
          ? WebDavSyncTransport(
              httpClient: httpClient,
              server: access.server,
              username: access.username,
              appPassword: password,
              libraryId: cipher.libraryId,
            )
          : NextcloudSyncTransport(
              httpClient: httpClient,
              server: access.server,
              username: access.username,
              davUserId: access.davUserId,
              appPassword: password,
              libraryId: cipher.libraryId,
            );
      await transport.probeImmutableWrites(verifyMetadata: generic);
    } finally {
      client.close();
    }
  }

  Future<void> setEnabled(String provider, bool enabled) => _perform(
    provider,
    enabled
        ? StorageConnectionAction.enabling
        : StorageConnectionAction.pausing,
    () async {
      await _discardAuthorization(provider);
      _guard();
      if (!enabled) {
        _localStops[provider] = _connections[provider]?.updatedAt ?? 0;
      }
      final capability = await _capability(provider);
      _guard();
      await call('setStorageConnectionEnabled', {
        'provider': provider,
        'deviceId': deviceId,
        'capability': capability,
        'enabled': enabled,
      });
      _guard();
      await _reload(provider);
    },
  );

  /// False means the local connection is removed but provider-side revocation
  /// was unavailable; the UI must tell the user how to revoke it manually.
  Future<bool> disconnect(String provider) =>
      _perform(provider, StorageConnectionAction.disconnecting, () async {
        await _discardAuthorization(provider);
        _guard();
        _localStops[provider] = _connections[provider]?.updatedAt ?? 0;
        final capability = await _capability(provider);
        _guard();
        final connection = _connections[provider];
        if (connection == null) storageConsentRequired();
        final credentials = connection.hasEncryptedCredentials
            ? await _credentials(connection, capability!)
            : null;
        _guard();
        await call('beginStorageDisconnect', {
          'provider': provider,
          'deviceId': deviceId,
          'capability': capability,
        });
        _guard();
        final revoked =
            credentials != null &&
            await authorization.revoke(provider, credentials);
        _guard();
        await call('disconnectStorageConnection', {
          'provider': provider,
          'deviceId': deviceId,
          'capability': capability,
        });
        _guard();
        await _reload(provider);
        _authorizations.remove(provider);
        _labels.removeWhere((key, _) => key.startsWith('$provider:'));
        return revoked;
      });

  /// Optional settings metadata. Failure never changes sync/connection status.
  Future<StorageUsage?> readStorageUsage(String provider) async {
    _checkProvider(provider);
    final connection = _connections[provider];
    if (connection == null ||
        !connection.isReady ||
        isBusy(provider) ||
        needsKeyRecovery(provider)) {
      return null;
    }
    bool current() =>
        _active &&
        !isBusy(provider) &&
        _connections[provider]?.hasSameSession(connection) == true;
    final existing = _sessions[provider];
    final reader =
        existing ??
        StorageProviderSession(
          connection: connection,
          cipher: cipher,
          deviceId: deviceId,
          call: call,
          isCurrent: current,
          client: createClient(),
          authorization: authorization,
          cache: createAccessCache?.call(connection, current),
        );
    try {
      final usage = await reader.readStorageUsage();
      return current() ? usage : null;
    } catch (_) {
      return null;
    } finally {
      if (existing == null) reader.dispose();
    }
  }

  Future<Map<String, dynamic>> requestClearOtp(String provider) async {
    _checkProvider(provider);
    final capability = await _capability(provider);
    _guard();
    final result = await call('requestStorageClearOtp', {
      'provider': provider,
      'deviceId': deviceId,
      'capability': capability,
    });
    _guard();
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> clearSyncedData(
    String provider,
    String requestId,
    String code,
    Future<void> Function() drain,
  ) => _perform(provider, StorageConnectionAction.clearing, () async {
    await _discardAuthorization(provider);
    final capability = await _capability(provider);
    _guard();
    final result = await call('beginStorageClear', {
      'provider': provider,
      'deviceId': deviceId,
      'capability': capability,
      'requestId': requestId,
      'code': code,
    });
    _guard();
    final operationId = result['operationId'] as String;
    await _reload(provider);
    await drain();
    _guard();
    final connection = _connections[provider];
    if (connection == null) {
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    }
    bool current() =>
        _active &&
        _connections[provider]?.state == 'clearing' &&
        _connections[provider]?.clearOperationId == operationId;
    if (!current()) throw StateError('Clear operation replaced');
    final cleanup = StorageProviderSession(
      connection: connection,
      clearing: true,
      cipher: cipher,
      deviceId: deviceId,
      call: call,
      isCurrent: current,
      client: createClient(),
      authorization: authorization,
    );
    try {
      await cleanup.clearLibrary();
      if (!current()) throw StateError('Clear operation replaced');
      await call('finishStorageClear', {
        'provider': provider,
        'deviceId': deviceId,
        'capability': capability,
        'operationId': operationId,
      });
      _guard();
      await _reload(provider);
    } finally {
      cleanup.dispose();
    }
  });

  Future<String?> _capability(String provider, {bool optional = false}) async {
    final connection = _connections[provider];
    if (connection == null && optional) return null;
    if (connection == null || needsKeyRecovery(provider)) {
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    }
    final capability = await cipher.decryptCapability(
      provider,
      connection.encryptedCapability,
    );
    _guard();
    return capability;
  }

  Future<void> _reload(String provider) async {
    final data = await readConnection(provider);
    _guard();
    if (data == null) {
      _awaitingMetadata.remove(provider);
      _connections.remove(provider);
      _sessions.remove(provider)?.dispose();
    } else {
      _adopt(provider, data);
    }
  }

  static SyncProviderFailure _failure(Object error) {
    if (error is SyncProviderFailure) return error;
    return SyncProviderFailure(switch (error) {
      FirebaseFunctionsException(
        code: 'permission-denied' || 'unauthenticated' || 'failed-precondition',
      ) =>
        SyncProviderFailureKind.reconnectRequired,
      FirebaseFunctionsException(code: 'resource-exhausted' || 'aborted') =>
        SyncProviderFailureKind.rateLimited,
      FormatException() ||
      ArgumentError() => SyncProviderFailureKind.corruptData,
      _ => SyncProviderFailureKind.unavailable,
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    preference?.removeListener(_selectionChanged);
    _closed.complete();
    for (final flow in _nextcloudLogins.toList()) {
      flow.dispose();
    }
    unawaited(_subscription.cancel());
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    for (final flow in _authorizations.values) {
      flow.cancel();
      unawaited(flow.authorization.cancel());
    }
    _authorizations.clear();
    authorization.dispose();
    _labels.clear();
    _connections.clear();
    super.dispose();
  }
}

class _StorageAuthorization {
  _StorageAuthorization(
    this.authorization,
    this.expiresAt, {
    this.expectedConnection,
  });
  final StorageConnection? expectedConnection;
  final PreparedStorageAuthorization authorization;
  final DateTime expiresAt;
  Future<void>? registering;
  bool sent = false;
  bool cancelRequested = false;
  void cancel() {
    cancelRequested = true;
  }
}

class _StorageAuthorizationCancelled implements Exception {
  const _StorageAuthorizationCancelled();
}
