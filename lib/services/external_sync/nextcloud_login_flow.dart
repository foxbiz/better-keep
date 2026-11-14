import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'provider_http.dart';
import 'storage_credential_broker.dart';
import 'sync_provider_adapter.dart';

/// Nextcloud Login Flow v2. The poll token and one-use result stay in memory.
/// Requests cannot leave the server/installation chosen by the user.
class NextcloudLoginFlow {
  NextcloudLoginFlow({
    required Uri server,
    required http.Client client,
    required this.isCurrent,
    required this.launch,
    this.onDispose,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 2),
  }) : server = normalizeServer(server),
       _client = client,
       now = now ?? DateTime.now {
    _http = ProviderHttp(client, isCurrent: () => !_disposed && isCurrent());
  }

  final Uri server;
  final http.Client _client;
  final bool Function() isCurrent;
  final Future<bool> Function(Uri) launch;
  final VoidCallback? onDispose;
  final DateTime Function() now;
  final Duration pollInterval;
  late final ProviderHttp _http;
  final _closed = Completer<void>();
  Uri? _login, _endpoint;
  String? _token;
  DateTime? _expiresAt;
  StorageDavAccess? _access;
  bool _disposed = false, _launched = false, _busy = false;

  static Uri normalizeServer(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        value.pathSegments.any((part) => part == '..' || part == '.')) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    return value.replace(path: value.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  void _guard() {
    if (_disposed || !isCurrent()) {
      throw StateError('Storage account session has ended');
    }
  }

  Uri _path(String suffix) => server.replace(path: '${server.path}$suffix');

  Uri _endpointUri(Object? value, {required bool login}) {
    if (value is! String) throw const FormatException();
    final uri = normalizeServer(Uri.parse(value));
    if (uri.origin != server.origin) throw const FormatException();
    final paths = [
      '${server.path}/login/v2/${login ? 'flow/' : 'poll'}',
      '${server.path}/index.php/login/v2/${login ? 'flow/' : 'poll'}',
    ];
    if (!paths.any(
      (path) => login
          ? uri.path.startsWith(path) &&
                uri.path.substring(path.length).isNotEmpty &&
                !uri.path.substring(path.length).contains('/')
          : uri.path == path,
    )) {
      throw const FormatException();
    }
    return uri;
  }

  Map<String, dynamic> _json(http.Response response) {
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  bool _secret(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 16384 &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  Future<T> _run<T>(Future<T> Function() operation) async {
    _guard();
    if (_busy) throw StateError('Nextcloud login already in progress');
    _busy = true;
    try {
      final result = await operation();
      _guard();
      return result;
    } on SyncProviderFailure {
      rethrow;
    } catch (_) {
      _guard();
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    } finally {
      _busy = false;
    }
  }

  Future<void> prepare() => _run(() async {
    if (_login != null) return;
    final startedAt = now();
    final response = await _http.send(
      'POST',
      _path('/index.php/login/v2'),
      headers: {
        'Accept': 'application/json',
        if (!kIsWeb) 'User-Agent': 'Better Keep',
      },
    );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    final data = _json(response);
    final poll = data['poll'];
    if (poll is! Map || !_secret(poll['token'])) throw const FormatException();
    final endpoint = _endpointUri(poll['endpoint'], login: false);
    final login = _endpointUri(data['login'], login: true);
    _endpoint = endpoint;
    _login = login;
    _token = poll['token'] as String;
    _expiresAt = startedAt.add(const Duration(minutes: 20));
  });

  /// Invoke directly from a new user gesture so web popup blockers allow launch.
  /// Retry reuses the one-use credentials if account lookup previously failed.
  Future<StorageDavAccess> authorize() => _run(() async {
    if (_access == null) {
      if (_token == null ||
          _expiresAt == null ||
          !now().isBefore(_expiresAt!)) {
        throw const SyncProviderFailure(
          SyncProviderFailureKind.reconnectRequired,
        );
      }
      if (!_launched) {
        final opened = await launch(_login!);
        _guard();
        if (!opened) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
        }
        _launched = true;
      }
      while (_access == null) {
        _guard();
        if (!now().isBefore(_expiresAt!)) {
          throw const SyncProviderFailure(
            SyncProviderFailureKind.reconnectRequired,
          );
        }
        final response = await _http.send(
          'POST',
          _endpoint!,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: Uint8List.fromList(
            utf8.encode('token=${Uri.encodeQueryComponent(_token!)}'),
          ),
        );
        if (response.statusCode == 404) {
          await Future.any([
            Future<void>.delayed(pollInterval),
            _closed.future,
          ]);
          continue;
        }
        if (response.statusCode != 200) ProviderHttp.fail(response);
        final data = _json(response);
        if (data['server'] is! String ||
            normalizeServer(Uri.parse(data['server'] as String)) != server ||
            !_secret(data['loginName']) ||
            (data['loginName'] as String).contains(':') ||
            !_secret(data['appPassword'])) {
          throw const FormatException();
        }
        _access = StorageDavAccess(
          server,
          data['loginName'] as String,
          data['appPassword'] as String,
        );
        _token = null;
      }
    }
    final access = _access!;
    if (access.davUserId != null) return access;
    final response = await _http.send(
      'GET',
      _path('/ocs/v2.php/cloud/user'),
      headers: {
        'Accept': 'application/json',
        'OCS-APIRequest': 'true',
        'Authorization':
            'Basic ${base64Encode(utf8.encode('${access.username}:${access.password}'))}',
      },
    );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    final ocs = _json(response)['ocs'];
    if (ocs is! Map ||
        ocs['meta'] is! Map ||
        ocs['meta']['statuscode'] != 200 ||
        ocs['data'] is! Map ||
        !_secret(ocs['data']['id'])) {
      throw const FormatException();
    }
    final id = ocs['data']['id'] as String;
    if (id == '.' || id == '..' || id.contains('/')) {
      throw const FormatException();
    }
    return _access = StorageDavAccess(
      server,
      access.username,
      access.password,
      davUserId: id,
    );
  });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _token = null;
    _access = null;
    _login = _endpoint = null;
    _closed.complete();
    _client.close();
    onDispose?.call();
  }
}
