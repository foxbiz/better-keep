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

  Future<void> Function()? beforeUpload;

  Future<http.Response> handle(http.Request request) async {
    requests++;
    expectSync(request.headers['authorization'], 'Bearer synthetic-access');
    expectSync(request.followRedirects, false);
    http.Response json(Object value) => http.Response(jsonEncode(value), 200);
    final path = request.url.path;
    final query = request.url.queryParameters;
    if (request.method == 'POST') {
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
        final id = 'file-${uploads++}';
        files[id] = Uint8List.fromList(
          latin1.encode(payload.substring(0, payload.length - 2)),
        );
        metadata[id] = {...header, 'id': id};
        return json({'id': id});
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
      return http.Response.bytes(files[request.url.pathSegments.last]!, 200);
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
    final offset = int.parse(query['pageToken'] ?? '0');
    final page = metadata.values.skip(offset).take(100).toList();
    return json({
      'files': page,
      if (offset + page.length < files.length)
        'nextPageToken': '${offset + page.length}',
    });
  }
}
