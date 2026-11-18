import 'dart:convert';
import 'dart:io';

import 'package:better_keep/services/firebase_storage_emulator_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';

String token({
  String project = 'demo-relay',
  String signature = '',
  String algorithm = 'none',
}) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return 'Firebase ${part({'alg': algorithm})}.${part({'aud': project, 'iss': 'https://securetoken.google.com/$project'})}.$signature';
}

void main() {
  late HttpServer upstream;
  late StorageEmulatorRelay relay;
  late HttpClient client;
  late List<String> paths;
  late List<String?> authorizations;
  late List<int> bytes;

  setUp(() async {
    paths = [];
    authorizations = [];
    bytes = [];
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = Uri.parse('http://127.0.0.1:${upstream.port}');
    upstream.listen((request) async {
      paths.add(request.uri.toString());
      authorizations.add(request.headers.value('authorization'));
      expect(request.headers.value('x-firebase-appcheck'), isNull);
      await for (final chunk in request) {
        bytes.addAll(chunk);
      }
      if (request.uri.path == '/denied') {
        request.response.statusCode = 403;
      } else if (request.uri.path == '/start') {
        request.response.headers.set(
          'x-goog-upload-url',
          '$origin/upload?upload_id=test',
        );
      } else if (request.uri.path == '/start-relative') {
        request.response.headers.set(
          'x-goog-upload-url',
          '/upload?upload_id=test',
        );
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '$origin/denied');
      } else if (request.uri.path == '/redirect-external') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'https://example.com/elsewhere',
        );
      } else if (request.uri.path == '/start-external') {
        request.response.headers.set(
          'x-goog-upload-url',
          'https://example.com/upload',
        );
      }
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    relay = await StorageEmulatorRelay.start(
      upstream: origin,
      projectId: 'demo-relay',
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await relay.close();
    await upstream.close(force: true);
  });

  Future<HttpClientResponse> send(String path, {String? authorization}) async {
    final request = await client.postUrl(relay.local.resolve(path));
    request.followRedirects = false;
    if (authorization != null) {
      request.headers.set('authorization', authorization);
    }
    request.headers.set('x-firebase-appcheck', 'must-not-be-forwarded');
    request.add([4, 5, 6]);
    return request.close();
  }

  test(
    'streams image bytes and preserves encoded object path and emulator Auth',
    () async {
      const path =
          '/v0/b/demo/o/users%2Ftest%2Fa%20b.jpg?alt=media&token=a%2Bb';
      final response = await send(path, authorization: token());
      expect(response.statusCode, 200);
      expect(await response.expand((chunk) => chunk).toList(), [1, 2, 3]);
      expect(paths, [path]);
      expect(authorizations, [token()]);
      expect(bytes, [4, 5, 6]);
    },
  );

  test('keeps resumable uploads and redirects on loopback', () async {
    final start = await send('/start', authorization: token());
    final upload = start.headers.value('x-goog-upload-url');
    await start.drain<void>();
    expect(upload, '${relay.local}/upload?upload_id=test');
    final response = await send(upload!, authorization: token());
    await response.drain<void>();
    expect(paths, ['/start', '/upload?upload_id=test']);
    final relative = await send('/start-relative', authorization: token());
    expect(relative.headers.value('x-goog-upload-url'), upload);
    await relative.drain<void>();
    final redirect = await send('/redirect', authorization: token());
    expect(redirect.statusCode, 302);
    expect(redirect.headers.value('location'), '${relay.local}/denied');
    await redirect.drain<void>();
    expect(paths.last, '/redirect');
  });

  test('rejects signed, foreign-project, and malformed credentials before forwarding', () async {
    for (final auth in [
      token(signature: 'signed', algorithm: 'RS256'),
      token(project: 'other'),
      'Bearer secret',
      'Firebase malformed',
    ]) {
      final response = await send('/start', authorization: auth);
      expect(response.statusCode, 403);
      await response.drain<void>();
    }
    expect(paths, isEmpty);
  });

  test(
    'does not let the SDK follow responses outside the selected emulator',
    () async {
      for (final path in ['/redirect-external', '/start-external']) {
        final response = await send(path, authorization: token());
        expect(response.statusCode, 502);
        expect(response.headers.value('location'), isNull);
        expect(response.headers.value('x-goog-upload-url'), isNull);
        await response.drain<void>();
      }
      expect(paths, ['/redirect-external', '/start-external']);
    },
  );

  test(
    'preserves denial by Storage rules including anonymous requests',
    () async {
      for (final auth in [null, token()]) {
        final response = await send('/denied', authorization: auth);
        expect(response.statusCode, 403);
        await response.drain<void>();
      }
      expect(authorizations, [null, token()]);
    },
  );
}
