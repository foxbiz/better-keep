import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:crypto/crypto.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/webdav_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/webdav_server.dart';

void main() {
  final library = 'a' * 64;
  final commit = 'c-${'b' * 64}.json';
  final media = 'o-${'c' * 64}';
  WebDavSyncTransport transport(WebDavServer server, {String? id}) =>
      WebDavSyncTransport(
        httpClient: ProviderHttp(server.client()),
        server: server.root,
        username: 'alice',
        appPassword: () async => 'app-password',
        libraryId: id ?? library,
      );

  test('large DAV scans stream beyond 8 MiB and reuse exact continuation', () async {
    String name(int i) => 'c-${i.toRadixString(16).padLeft(64, '0')}.json';
    final names = List.generate(30000, name);
    String listing() =>
        '<d:multistatus xmlns:d="DAV:">${names.map((n) => '<d:response><d:href>/dav/BetterKeep/$library/$n</d:href>'
            '<d:propstat><d:prop><d:getetag>"etag"</d:getetag><d:resourcetype/>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>';
    var requests = 0;
    final dav = WebDavSyncTransport(
      httpClient: ProviderHttp(
        MockClient((request) async {
          if (request.method == 'MKCOL') return http.Response('', 201);
          requests++;
          final body = listing();
          expect(utf8.encode(body).length, greaterThan(8 * 1024 * 1024));
          return http.Response(body, 207);
        }),
      ),
      server: Uri.parse('https://example.test/dav'),
      username: 'qa',
      appPassword: () async => 'fixture',
      libraryId: library,
    );
    final first = await dav.list(null);
    expect(first.names, names.take(100));
    final second = await dav.list(first.cursor);
    expect(second.names, names.skip(100).take(100));
    expect(requests, 1);
    var page = second;
    var received = 200;
    while (page.hasMore) {
      expect(page.cursor!.length, lessThan(200));
      page = await dav.list(page.cursor);
      received += page.names.length;
    }
    expect(received, names.length);
    expect(requests, 1);
    expect((jsonDecode(page.cursor!) as Map)['version'], 1);
  });

  test('interrupted and stale DAV continuations fail safely and can restart', () async {
    final server = WebDavServer();
    for (var i = 0; i < 201; i++) {
      server.files['${server.root.path}/BetterKeep/$library/c-${i.toRadixString(16).padLeft(64, '0')}.json'] =
          Uint8List.fromList([i % 256]);
    }
    final dav = transport(server);
    final first = await dav.list(null);
    final second = await dav.list(first.cursor);
    final invalid = isA<SyncProviderFailure>().having(
      (e) => e.kind,
      'kind',
      SyncProviderFailureKind.invalidCursor,
    );
    await expectLater(dav.list(first.cursor), throwsA(invalid));
    final restarted = transport(server);
    await expectLater(restarted.list(second.cursor), throwsA(invalid));
    var page = await restarted.list(null);
    final names = page.names.toSet();
    while (page.hasMore) {
      page = await restarted.list(page.cursor);
      names.addAll(page.names);
    }
    expect(names, hasLength(201));
    // The durable final checkpoint works in a new transport too.
    expect((await transport(server).list(page.cursor)).names, isEmpty);
  });

  test('a new scan observes commits inserted during pagination', () async {
    final server = WebDavServer();
    final dav = transport(server);
    for (var i = 0; i < 201; i++) {
      server.files['${server.root.path}/BetterKeep/$library/c-${i.toRadixString(16).padLeft(64, '0')}.json'] =
          Uint8List.fromList([i % 256]);
    }
    var page = await dav.list(null);
    final added = 'c-${'f' * 64}.json';
    server.files['${server.root.path}/BetterKeep/$library/$added'] =
        Uint8List.fromList([1]);
    while (page.hasMore) {
      page = await dav.list(page.cursor);
    }
    expect(server.requests.where((r) => r.method == 'PROPFIND'), hasLength(1));
    page = await dav.list(page.cursor);
    expect(page.names, [added]);
    expect(server.requests.where((r) => r.method == 'PROPFIND'), hasLength(2));
  });

  test(
    'encrypted note, media and tombstone round-trip between approved clients',
    () async {
      final server = WebDavServer();
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final owner = await SyncCipher.create('owner', key);
      final approved = await SyncCipher.create('owner', key);
      addTearDown(owner.dispose);
      addTearDown(approved.dispose);
      final first = FileSyncAdapter(
        connectionId: 'webdav:1',
        transport: transport(server, id: owner.libraryId),
        cipher: owner,
      );
      final second = FileSyncAdapter(
        connectionId: 'webdav:1',
        transport: transport(server, id: approved.libraryId),
        cipher: approved,
      );
      final note = await owner.encryptObject(
        Uint8List.fromList(utf8.encode('private note with tasks and table')),
      );
      final attachment = await owner.encryptObject(
        Uint8List.fromList([0, 255, 127]),
      );
      final noteId = sha256.convert(note).toString();
      final mediaId = sha256.convert(attachment).toString();
      await first.putObject(noteId, note);
      await first.putObject(mediaId, attachment);
      final revision = SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-1',
        revisionId: 'rev-1',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: noteId,
        blobIds: [mediaId],
      );
      await first.publish(revision);
      final page = await second.changes(null);
      expect(page.revisions.single.encode(), revision.encode());
      expect(
        utf8.decode(
          await approved.decryptObject(await second.readObject(noteId)),
        ),
        'private note with tasks and table',
      );
      expect(await approved.decryptObject(await second.readObject(mediaId)), [
        0,
        255,
        127,
      ]);
      final deleted = SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-1',
        revisionId: 'rev-2',
        modifiedAtMicros: 2,
        deleted: true,
        payloadObjectId: null,
      );
      await second.publish(deleted);
      expect((await first.changes(page.cursor)).revisions.single.deleted, true);
      for (final bytes in server.files.values) {
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains('private note')),
        );
      }
    },
  );

  test(
    'two clients share files and track changes without overwriting media',
    () async {
      final server = WebDavServer();
      final first = transport(server), second = transport(server);
      await first.probeImmutableWrites(verifyMetadata: true);
      expect(server.files, isEmpty);
      final bytes = Uint8List.fromList([0, 1, 127, 255]);
      expect(await first.create(media, bytes), true);
      expect(
        await first.create(commit, Uint8List.fromList(utf8.encode('commit'))),
        true,
      );
      final page = await second.list(null);
      expect(page.names, [commit]);
      expect((await second.list(page.cursor)).names, isEmpty);
      expect(await second.read(media), bytes);
      expect(await second.create(media, Uint8List.fromList([9])), false);
      expect(await first.read(media), bytes);
      final later = 'c-${'d' * 64}.json';
      await second.create(later, Uint8List.fromList([2]));
      expect((await first.list(page.cursor)).names, [later]);
      expect(server.requests.every((r) => !r.followRedirects), true);
      expect(
        server.requests.every(
          (r) =>
              r.headers['authorization'] ==
              'Basic ${base64Encode(utf8.encode('alice:app-password'))}',
        ),
        true,
      );
    },
  );

  test(
    'cleanup deletes only this account library; quota uses configured root',
    () async {
      final server = WebDavServer();
      final first = transport(server), other = transport(server, id: 'e' * 64);
      await first.create(media, Uint8List.fromList([1]));
      await other.create(media, Uint8List.fromList([2]));
      final usage = await first.readStorageUsage();
      expect(usage!.usedBytes, 200);
      expect(usage.totalBytes, 1000);
      await first.clearLibrary();
      expect(await other.read(media), [2]);
      expect(server.files.length, 1);
      expect(
        server.requests.lastWhere((r) => r.method == 'DELETE').url.path,
        '${server.root.path}/BetterKeep/$library/',
      );
    },
  );

  test(
    'setup rejects unsafe writes, missing ETags and foreign metadata',
    () async {
      for (final failure in ['overwrite', 'etag', 'href']) {
        final server = WebDavServer()
          ..ignoreConditions = failure == 'overwrite'
          ..omitEtags = failure == 'etag'
          ..listingHref = failure == 'href'
              ? 'https://evil.example/file'
              : null;
        await expectLater(
          transport(server).probeImmutableWrites(verifyMetadata: true),
          throwsA(isA<SyncProviderFailure>()),
        );
        expect(server.files, isEmpty);
      }
    },
  );

  test('unsafe URLs are rejected before sending credentials', () {
    for (final url in [
      'http://dav.example.test/',
      'https://user:pass@dav.example.test/',
      'https://dav.example.test/?token=x',
      'https://dav.example.test/#fragment',
      'https://dav.example.test/dav/%2Fother',
      'https://dav.example.test/dav/%5Cother',
    ]) {
      expect(
        () => WebDavSyncTransport.normalizeServer(Uri.parse(url)),
        throwsA(isA<SyncProviderFailure>()),
      );
    }
  });

  test(
    'redirects never receive credentials and full storage is classified',
    () async {
      for (final status in [302, 507]) {
        var calls = 0;
        final adapter = WebDavSyncTransport(
          httpClient: ProviderHttp(
            MockClient((request) async {
              calls++;
              expect(request.followRedirects, false);
              return http.Response(
                '',
                status,
                headers: {'location': 'https://evil.example/'},
              );
            }),
          ),
          server: Uri.parse('https://dav.example.test/dav'),
          username: 'alice',
          appPassword: () async => 'secret',
          libraryId: library,
        );
        await expectLater(
          adapter.read(media),
          throwsA(
            isA<SyncProviderFailure>().having(
              (e) => e.kind,
              'failure',
              status == 507
                  ? SyncProviderFailureKind.quotaExceeded
                  : SyncProviderFailureKind.unsupported,
            ),
          ),
        );
        expect(calls, 1);
      }
    },
  );
}
