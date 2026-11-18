import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/nextcloud_sync_transport.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final library = 'a' * 64;
  final name = 'c-${'b' * 64}.json';
  String xml(List<String> names, {String etag = 'v1', String? origin}) =>
      '<d:multistatus xmlns:d="DAV:">${names.map((name) => '''
      <d:response><d:href>${origin ?? ''}/cloud/remote.php/dav/files/alice/BetterKeep/$library/$name</d:href>
      <d:propstat><d:prop><d:getetag>$etag</d:getetag><d:resourcetype/></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>''').join()}</d:multistatus>';

  NextcloudSyncTransport transport(http.Client client) =>
      NextcloudSyncTransport(
        httpClient: ProviderHttp(client),
        server: Uri.parse('https://example.com/cloud/'),
        username: 'alice',
        appPassword: () async => 'app-password',
        libraryId: library,
      );

  test('DAV paths use the canonical ID while Basic authentication retains the login name', () async {
    final client = MockClient((request) async {
      expect(
        request.url.path,
        contains('/dav/files/canonical-user/BetterKeep'),
      );
      expect(
        request.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('email@example.invalid:app-password'))}',
      );
      if (request.method == 'MKCOL') return http.Response('', 405);
      return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
    });
    final value = NextcloudSyncTransport(
      httpClient: ProviderHttp(client),
      server: Uri.parse('https://example.com/cloud'),
      username: 'email@example.invalid',
      davUserId: 'canonical-user',
      appPassword: () async => 'app-password',
      libraryId: library,
    );
    expect((await value.list(null)).names, isEmpty);
  });

  test('cursor from a different library requires a fresh scan', () async {
    final client = MockClient(
      (request) async => request.method == 'MKCOL'
          ? http.Response('', 201)
          : http.Response(xml([]), 207),
    );
    final adapter = transport(client);
    final first = await adapter.list(null);
    final cursor = jsonDecode(first.cursor!) as Map<String, dynamic>;
    cursor['library'] = 'b' * 64;
    await expectLater(
      adapter.list(jsonEncode(cursor)),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.invalidCursor,
        ),
      ),
    );
    client.close();
  });

  test('connection probe rejects ignored conditional writes and cleans its own canary', () async {
    for (final behavior in ['safe', 'overwrite', 'lie']) {
      Uint8List? stored;
      Uri? canary;
      var deleted = false;
      final client = MockClient((request) async {
        if (request.method == 'MKCOL') return http.Response('', 201);
        canary ??= request.url;
        expect(request.url, canary);
        expect(request.url.pathSegments.last, startsWith('.probe-'));
        switch (request.method) {
          case 'PUT':
            expect(request.headers['If-None-Match'], '*');
            if (stored == null) {
              stored = request.bodyBytes;
              return http.Response('', 201);
            }
            if (behavior != 'safe') stored = request.bodyBytes;
            return http.Response('', behavior == 'overwrite' ? 204 : 412);
          case 'GET':
            return http.Response.bytes(stored!, 200);
          case 'DELETE':
            deleted = true;
            return http.Response('', 204);
          default:
            throw StateError('Unexpected probe request');
        }
      });
      if (behavior == 'safe') {
        await transport(client).probeImmutableWrites();
      } else {
        await expectLater(
          transport(client).probeImmutableWrites(),
          throwsA(
            isA<SyncProviderFailure>().having(
              (e) => e.kind,
              'kind',
              SyncProviderFailureKind.unsupported,
            ),
          ),
        );
      }
      expect(deleted, isTrue);
      client.close();
    }
  });

  test(
    'ETag cursor detects new and changed commits but does not invent deletions',
    () async {
      var etag = 'v1';
      var names = [name];
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(
          request.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('alice:app-password'))}',
        );
        if (request.method == 'MKCOL') return http.Response('', 201);
        expect(request.method, 'PROPFIND');
        expect(request.headers['Depth'], '1');
        return http.Response(xml(names, etag: etag), 207);
      });
      final adapter = transport(client);
      final first = await adapter.list(null);
      expect(first.names, [name]);
      expect((await adapter.list(first.cursor)).names, isEmpty);
      etag = 'v2';
      final changed = await adapter.list(first.cursor);
      expect(changed.names, [name]);
      names = [];
      expect((await adapter.list(changed.cursor)).names, isEmpty);
      client.close();
    },
  );

  test('bounded pages reuse the listing and the next scan discovers mid-scan insertions', () async {
    final names = List.generate(
      101,
      (i) => 'c-${i.toRadixString(16).padLeft(64, '0')}.json',
    );
    final client = MockClient(
      (request) async => request.method == 'MKCOL'
          ? http.Response('', 201)
          : http.Response(xml(names), 207),
    );
    final adapter = transport(client);
    final first = await adapter.list(null);
    expect(first.names.length, 100);
    expect(first.hasMore, isTrue);
    names.add(name);
    final next = await adapter.list(first.cursor);
    expect(next.names.length, 1);
    expect(next.names, isNot(contains(name)));
    expect(next.hasMore, isFalse);
    final rescan = await adapter.list(next.cursor);
    expect(rescan.names, [name]);
    expect((await adapter.list(rescan.cursor)).names, isEmpty);
    client.close();
  });

  test('conditional create never acknowledges an overwritten file', () async {
    var status = 201;
    final client = MockClient((request) async {
      if (request.method == 'MKCOL') return http.Response('', 201);
      expect(request.method, 'PUT');
      expect(request.headers['If-None-Match'], '*');
      expect(
        request.url.path,
        '/cloud/remote.php/dav/files/alice/BetterKeep/$library/$name',
      );
      return http.Response('', status);
    });
    final adapter = transport(client);
    expect(await adapter.create(name, Uint8List(1)), isTrue);
    status = 412;
    expect(await adapter.create(name, Uint8List(1)), isFalse);
    status = 204;
    await expectLater(
      adapter.create(name, Uint8List(1)),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.unsupported,
        ),
      ),
    );
    client.close();
  });

  test('untrusted DAV listing cannot redirect authenticated downloads outside the library', () async {
    final client = MockClient(
      (request) async => request.method == 'MKCOL'
          ? http.Response('', 201)
          : http.Response(xml([name], origin: 'https://evil.example'), 207),
    );
    await expectLater(
      transport(client).list(null),
      throwsA(isA<SyncProviderFailure>()),
    );
    client.close();
  });

  test(
    'insecure setup, malformed cursor and malformed XML fail explicitly',
    () async {
      final client = MockClient(
        (request) async => request.method == 'MKCOL'
            ? http.Response('', 201)
            : http.Response('<invalid', 207),
      );
      expect(
        () => NextcloudSyncTransport(
          httpClient: ProviderHttp(client),
          server: Uri.parse('http://example.com'),
          username: 'alice',
          appPassword: () async => 'secret',
          libraryId: library,
        ),
        throwsArgumentError,
      );
      await expectLater(
        transport(client).list('broken'),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.invalidCursor,
          ),
        ),
      );
      await expectLater(
        transport(client).list(null),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.corruptData,
          ),
        ),
      );
      client.close();
    },
  );
}
