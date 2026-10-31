import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory DAV fixture: never connects to a real account or modifies files.
class WebDavServer {
  final root = Uri.parse('https://dav.example.test/storage/user%20files');
  final files = <String, Uint8List>{};
  final requests = <http.Request>[];
  bool ignoreConditions = false, omitEtags = false;
  String? listingHref;
  int? failStatus;

  http.Client client() => MockClient(handle);

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (failStatus != null) return http.Response('', failStatus!);
    final path = request.url.path;
    if (request.url.origin != root.origin ||
        !(path == root.path || path.startsWith('${root.path}/'))) {
      throw StateError('Request escaped configured DAV root');
    }
    switch (request.method) {
      case 'MKCOL':
        return http.Response('', 201);
      case 'PUT':
        if (files.containsKey(path) &&
            !ignoreConditions &&
            request.headers['if-none-match'] == '*') {
          return http.Response('', 412);
        }
        final existed = files.containsKey(path);
        files[path] = Uint8List.fromList(request.bodyBytes);
        return http.Response('', existed ? 204 : 201);
      case 'GET':
        return files.containsKey(path)
            ? http.Response.bytes(files[path]!, 200)
            : http.Response('', 404);
      case 'DELETE':
        final target = path.replaceFirst(RegExp(r'/+$'), '');
        files.removeWhere(
          (key, _) => key == target || key.startsWith('$target/'),
        );
        return http.Response('', 204);
      case 'PROPFIND':
        final quota = request.body.contains('quota-available-bytes');
        final names = request.headers['depth'] == '0'
            ? [path]
            : files.keys.where((key) => key.startsWith(path)).toList();
        String escape(String value) => const HtmlEscape().convert(value);
        final body = names.map((name) {
          final etag = omitEtags
              ? ''
              : '<d:getetag>"${sha256.convert(files[name] ?? [])}"</d:getetag>';
          return '<d:response><d:href>${escape(listingHref ?? name)}</d:href>'
              '<d:propstat><d:prop><d:resourcetype/>$etag'
              '${quota ? '<d:quota-used-bytes>200</d:quota-used-bytes><d:quota-available-bytes>800</d:quota-available-bytes>' : ''}'
              '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
        }).join();
        return http.Response(
          '<d:multistatus xmlns:d="DAV:">$body</d:multistatus>',
          207,
        );
      default:
        throw StateError('Unexpected DAV operation');
    }
  }
}
