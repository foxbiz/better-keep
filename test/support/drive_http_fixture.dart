import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Drive protocol fixture. Only the HTTP boundary is simulated; multipart
/// uploads, encrypted commits, paging, local capture, and restore use real code.
class DriveHttpFixture {
  final files = <String, Uint8List>{};
  final metadata = <String, Map<String, dynamic>>{};
  int requests = 0, uploads = 0, activeUploads = 0, peakUploads = 0;
  int mediaReads = 0, lookups = 0, activeReads = 0, peakReads = 0;
  Duration readLatency = Duration.zero;
  final _sessions = <String, Map<String, dynamic>>{};
  int indexWrites = 0;
  bool omitWriteVersions = false;

  Future<void> Function()? beforeUpload;

  Future<http.Response> handle(http.Request request) async {
    requests++;
    if (request.method == 'GET') {
      final media = request.url.queryParameters['alt'] == 'media';
      if (media) {
        mediaReads++;
        activeReads++;
        if (activeReads > peakReads) peakReads = activeReads;
      } else if ((request.url.queryParameters['q'] ?? '').contains('name =')) {
        lookups++;
      }
      try {
        if (readLatency != Duration.zero) {
          await Future<void>.delayed(readLatency);
        }
        return await _handle(request);
      } finally {
        if (media) activeReads--;
      }
    }
    return _handle(request);
  }

  Future<http.Response> _handle(http.Request request) async {
    expectSync(request.headers['authorization'], 'Bearer synthetic-access');
    expectSync(request.followRedirects, false);
    http.Response json(Object value) => http.Response(jsonEncode(value), 200);
    final path = request.url.path;
    final query = request.url.queryParameters;
    http.Response store(Map<String, dynamic> header, Uint8List bytes) {
      final id = 'file-${files.length}';
      files[id] = bytes;
      metadata[id] = {...header, 'id': id, 'version': '1'};
      if ((header['appProperties'] as Map?)?['indexLibrary'] != null) {
        indexWrites++;
      } else {
        uploads++;
      }
      return json({
        'id': id,
        if (!omitWriteVersions) 'version': metadata[id]!['version'],
      });
    }

    if (request.method == 'DELETE') {
      final id = request.url.pathSegments.last;
      files.remove(id);
      metadata.remove(id);
      return http.Response('', 204);
    }
    if (request.method == 'PATCH') {
      final id = request.url.pathSegments.last;
      if (!metadata.containsKey(id)) return http.Response('', 404);
      expectSync(query['uploadType'], 'media');
      expectSync(metadata[id]!['appProperties']['indexLibrary'], isNotNull);
      files[id] = request.bodyBytes;
      metadata[id]!['version'] = '${int.parse(metadata[id]!['version']) + 1}';
      indexWrites++;
      return json({
        'id': id,
        if (!omitWriteVersions) 'version': metadata[id]!['version'],
      });
    }
    if (request.method == 'PUT') {
      final header = _sessions.remove(query['upload_id']);
      expectSync(header, isNotNull);
      expectSync(
        request.headers['content-range'],
        'bytes 0-${request.bodyBytes.length - 1}/${request.bodyBytes.length}',
      );
      return store(header!, request.bodyBytes);
    }
    if (request.method == 'POST') {
      if (query['uploadType'] == 'resumable') {
        final id = 'session-${_sessions.length}';
        _sessions[id] = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          '',
          200,
          headers: {
            'location':
                'https://www.googleapis.com/upload/drive/v3/files?upload_id=$id',
          },
        );
      }
      expectSync(
        query['uploadType'],
        'multipart',
        reason:
            'This fixture supports only Drive multipart uploads (up to 1 MiB).',
      );
      activeUploads++;
      if (activeUploads > peakUploads) peakUploads = activeUploads;
      try {
        await beforeUpload?.call();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final boundary = request.headers['Content-Type']!
            .split('boundary=')
            .last;
        final parts = latin1.decode(request.bodyBytes).split('--$boundary');
        final header = jsonDecode(
          parts[1].split('\r\n\r\n')[1].trim(),
        ) as Map<String, dynamic>;
        final payload = parts[2].substring(parts[2].indexOf('\r\n\r\n') + 4);
        return store(
          header,
          Uint8List.fromList(
            latin1.encode(payload.substring(0, payload.length - 2)),
          ),
        );
      } finally {
        activeUploads--;
      }
    }
    if (path.endsWith('startPageToken')) {
      return json({'startPageToken': '${files.length}'});
    }
    if (path.endsWith('/changes')) {
      final offset = int.parse(query['pageToken']!);
      final page = metadata.values.skip(offset).take(100).toList();
      final next = offset + page.length;
      return json({
        'changes': page.map((f) => {'file': f}).toList(),
        if (next < files.length)
          'nextPageToken': '$next'
        else
          'newStartPageToken': '${files.length}',
      });
    }
    if (query['alt'] == 'media') {
      final bytes = files[request.url.pathSegments.last];
      return bytes == null
          ? http.Response('', 404)
          : http.Response.bytes(bytes, 200);
    }
    expectSync(path, '/drive/v3/files');
    final name = RegExp("name = '([^']+)'")
        .firstMatch(query['q'] ?? '')
        ?.group(1);
    if (name != null) {
      return json({
        'files': metadata.values.where((f) => f['name'] == name).toList(),
      });
    }
    final property = RegExp("key='([^']+)' and value='([^']+)'")
        .firstMatch(query['q'] ?? '');
    final inventory = metadata.values
        .where(
          (f) =>
              property == null ||
              f['appProperties']?[property.group(1)] == property.group(2),
        )
        .toList();
    final offset = int.parse(query['pageToken'] ?? '0');
    final page = inventory.skip(offset).take(100).toList();
    return json({
      'files': page,
      if (offset + page.length < inventory.length)
        'nextPageToken': '${offset + page.length}',
    });
  }
}
