import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_provider_adapter.dart';
import 'sync_limits.dart';
import 'provider_network_error.dart';

/// Credential-safe request boundary shared by provider transports. It never
/// logs provider responses and never forwards authorization through redirects.
class ProviderHttp {
  ProviderHttp(
    this.client, {
    this.timeout = const Duration(seconds: 60),
    this.refreshRejectedToken,
    this.isCurrent,
  });
  final http.Client client;
  final Duration timeout;
  final Future<String> Function(String rejectedToken)? refreshRejectedToken;
  final bool Function()? isCurrent;

  void _guard() {
    if (isCurrent != null && !isCurrent!()) {
      throw StateError('Provider session has ended');
    }
  }

  Future<http.Response> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    int maxResponseBytes = SyncLimits.metadataBytes,
    void Function(List<int>)? onResponseChunk,
    SyncProviderFailureKind sizeFailure = SyncProviderFailureKind.corruptData,
  }) async {
    _guard();
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    Future<http.Response> perform(Map<String, String> requestHeaders) async {
      _guard();
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers.addAll(requestHeaders);
      if (body != null) request.bodyBytes = body;
      StreamIterator<List<int>>? chunks;
      var finished = false;
      try {
        return await (() async {
          final response = await client.send(request);
          if (finished) {
            await response.stream.listen(null).cancel();
            throw TimeoutException('Provider request expired');
          }
          if ((response.contentLength ?? 0) > maxResponseBytes) {
            await response.stream.listen(null).cancel();
            throw SyncProviderFailure(sizeFailure);
          }
          final bytes = BytesBuilder(copy: false);
          var received = 0;
          final consume = response.statusCode == 207 ? onResponseChunk : null;
          chunks = StreamIterator(response.stream);
          while (await chunks!.moveNext()) {
            final chunk = chunks!.current;
            _guard();
            received += chunk.length;
            if (received > maxResponseBytes) {
              throw SyncProviderFailure(sizeFailure);
            }
            if (consume == null) {
              bytes.add(chunk);
            } else {
              // Bound parser chunk size even when a transport emits one huge
              // packet. The caller never needs the full listing in memory.
              for (var offset = 0; offset < chunk.length; offset += 8192) {
                consume(
                  chunk.sublist(
                    offset,
                    offset + 8192 < chunk.length ? offset + 8192 : chunk.length,
                  ),
                );
              }
            }
          }
          chunks = null; // The stream has completed; do not cancel it again.
          return http.Response.bytes(
            bytes.takeBytes(),
            response.statusCode,
            headers: response.headers,
            request: response.request,
            reasonPhrase: response.reasonPhrase,
          );
        })().timeout(timeout);
      } finally {
        finished = true;
        await chunks?.cancel();
      }
    }

    try {
      final result = await perform(headers);
      _guard();
      final authorization = headers['Authorization'];
      final refresh = refreshRejectedToken;
      if (result.statusCode != 401 ||
          refresh == null ||
          authorization == null ||
          !authorization.startsWith('Bearer ')) {
        return result;
      }
      final oldToken = authorization.substring(7);
      final newToken = await refresh(oldToken);
      _guard();
      if (oldToken == newToken) return result;
      // A 401 did not authorize a write. Retry exactly once with the new token,
      // retaining the original endpoint, body and redirect prohibition.
      return await perform({...headers, 'Authorization': 'Bearer $newToken'});
    } on TimeoutException {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    } on http.ClientException {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    } catch (error) {
      if (isProviderNetworkError(error)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
      }
      rethrow;
    }
  }

  static Never fail(http.Response response) {
    final status = response.statusCode;
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    throw SyncProviderFailure(
      switch (status) {
        401 => SyncProviderFailureKind.reconnectRequired,
        403 => SyncProviderFailureKind.unsupported,
        429 => SyncProviderFailureKind.rateLimited,
        507 => SyncProviderFailureKind.quotaExceeded,
        >= 300 && < 400 => SyncProviderFailureKind.unsupported,
        _ => SyncProviderFailureKind.unavailable,
      },
      retryAfter: seconds != null && seconds >= 0
          ? Duration(seconds: seconds)
          : null,
    );
  }
}
