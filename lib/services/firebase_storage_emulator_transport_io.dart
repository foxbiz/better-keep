import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'firebase_emulator_host.dart';

StorageEmulatorRelay? _relay;

Future<Uri> configureStorageEmulatorTransport(
  FirebaseEmulatorEndpoints endpoints, {
  required String projectId,
}) async {
  final upstream = Uri(
    scheme: 'http',
    host: endpoints.host,
    port: FirebaseEmulatorEndpoints.storagePort,
  );
  if (!kDebugMode ||
      !(Platform.isIOS || Platform.isMacOS) ||
      const {'localhost', '127.0.0.1', '::1'}.contains(endpoints.host)) {
    return upstream;
  }
  if (_relay?.upstream != upstream || _relay?.projectId != projectId) {
    await _relay?.close();
    _relay = null;
    // Stable across hot restarts: native Storage retains its configured port.
    _relay = await StorageEmulatorRelay.start(
      upstream: upstream,
      projectId: projectId,
      port: 49199,
    );
  }
  return _relay!.local;
}

/// Firebase Apple SDK 12.17 omits Auth over non-loopback HTTP. This debug-only
/// relay permits LAN emulator testing without forwarding real credentials or
/// changing Storage rules. It accepts only unsigned tokens for this project.
class StorageEmulatorRelay {
  StorageEmulatorRelay._(this._server, this.upstream, this.projectId);

  final HttpServer _server;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = false;
  final Uri upstream;
  final String projectId;

  Uri get local => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  static Future<StorageEmulatorRelay> start({
    required Uri upstream,
    required String projectId,
    int port = 0,
  }) async {
    if (!kDebugMode) throw StateError('Emulator relay requires a debug build');
    if (upstream.scheme != 'http' ||
        upstream.host.isEmpty ||
        upstream.userInfo.isNotEmpty ||
        upstream.path.isNotEmpty ||
        upstream.hasQuery ||
        upstream.hasFragment) {
      throw ArgumentError.value(upstream, 'upstream', 'Expected HTTP origin');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final relay = StorageEmulatorRelay._(server, upstream, projectId);
    server.listen((request) => unawaited(relay._forward(request)));
    return relay;
  }

  bool _isEmulatorAuthorization(String? authorization) {
    if (authorization == null) {
      return true; // Rules still reject anonymous writes.
    }
    if (!authorization.startsWith('Firebase ')) return false;
    try {
      final parts = authorization.substring(9).split('.');
      if (parts.length != 3 || parts[2].isNotEmpty) return false;
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
      ) as Map;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map;
      return header['alg'] == 'none' &&
          claims['aud'] == projectId &&
          claims['iss'] == 'https://securetoken.google.com/$projectId';
    } catch (_) {
      return false;
    }
  }

  static const _hopHeaders = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'host',
  };

  Future<void> _forward(HttpRequest request) async {
    HttpClientRequest? outgoing;
    try {
      if (!_isEmulatorAuthorization(request.headers.value('authorization'))) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('Only emulator credentials are accepted');
        return;
      }
      // Replace the entire origin, even for an absolute incoming URI.
      final target = upstream.replace(
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null,
      );
      outgoing = await _client.openUrl(request.method, target);
      outgoing.followRedirects = false;
      request.headers.forEach((name, values) {
        if (!_hopHeaders.contains(name) && name != 'x-firebase-appcheck') {
          outgoing!.headers.set(name, values);
        }
      });
      await outgoing.addStream(request);
      final response = await outgoing.close().timeout(
        const Duration(seconds: 120),
      );
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (_hopHeaders.contains(name)) return;
        request.response.headers.set(
          name,
          values.map((value) {
            // Resumable uploads must come back through the same relay.
            if (name == 'x-goog-upload-url' || name == 'location') {
              final uri = target.resolve(value);
              if (uri.origin != upstream.origin || uri.userInfo.isNotEmpty) {
                throw const FormatException(
                  'Emulator returned an external upload or redirect URL',
                );
              }
              return uri.replace(host: local.host, port: local.port).toString();
            }
            return value;
          }).toList(),
        );
      });
      await request.response.addStream(response);
    } catch (_) {
      outgoing?.abort();
      // Do not log headers, tokens, or download URL query parameters.
      try {
        request.response.headers.clear();
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {
        // A client may have disconnected after receiving response headers.
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        // A disconnected SDK request must not crash the relay's isolate.
      }
    }
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}
