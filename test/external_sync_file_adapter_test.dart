import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:crypto/crypto.dart';
import 'package:better_keep/services/external_sync/sync_limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late SyncCipher cipher;
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  setUp(() async {
    cipher = await SyncCipher.create('user', key);
  });
  tearDown(() => cipher.dispose());

  test('ended encryption sessions cannot encrypt with cleared keys', () async {
    cipher.dispose();
    await expectLater(cipher.encryptObject(Uint8List(1)), throwsStateError);
    await expectLater(cipher.decryptObject(Uint8List(40)), throwsStateError);
  });

  SyncRevision revision(String id) => SyncRevision(
    kind: SyncEntityKind.note,
    entityId: 'private-note',
    revisionId: 'revision-1',
    modifiedAtMicros: 123,
    deleted: false,
    payloadObjectId: id,
  );

  test('oversize commits and excessive attachment references fail before decryption', () async {
    await expectLater(
      cipher.decodeCommit(Uint8List(SyncLimits.commitBytes + 1)),
      throwsFormatException,
    );
    final value = revision('a' * 64).toJson();
    value['blobIds'] = List.filled(SyncLimits.attachmentCount + 1, 'b' * 64);
    expect(() => SyncRevision.decode(jsonEncode(value)), throwsFormatException);
  });

  test('objects and commits round-trip with separate keys and randomized encryption', () async {
    final plaintext = Uint8List.fromList(utf8.encode('private content'));
    final object = await cipher.encryptObject(plaintext);
    expect(await cipher.decryptObject(object), plaintext);
    expect(await cipher.encryptObject(plaintext), isNot(object));
    final value = revision(sha256.convert(object).toString());
    final commit = await cipher.encodeCommit(value);
    expect(utf8.decode(commit), isNot(contains('private-note')));
    expect((await cipher.decodeCommit(commit)).encode(), value.encode());
    final envelope = jsonDecode(utf8.decode(commit)) as Map<String, dynamic>;
    await expectLater(
      cipher.decryptObject(base64Decode(envelope['ciphertext'] as String)),
      throwsA(anything),
    );
  });

  test(
    'other account, reset key, tampering and unsupported format fail closed',
    () async {
      final object = await cipher.encryptObject(Uint8List.fromList([1]));
      final commit = await cipher.encodeCommit(
        revision(sha256.convert(object).toString()),
      );
      for (final other in [
        await SyncCipher.create('other-user', key),
        await SyncCipher.create('user', Uint8List.fromList(List.filled(32, 9))),
      ]) {
        expect(other.libraryId, isNot(cipher.libraryId));
        await expectLater(other.decodeCommit(commit), throwsFormatException);
        await expectLater(other.decryptObject(object), throwsA(anything));
        other.dispose();
      }
      object[object.length - 1] ^= 1;
      await expectLater(cipher.decryptObject(object), throwsA(anything));
      final envelope = jsonDecode(utf8.decode(commit)) as Map<String, dynamic>;
      envelope['version'] = 2;
      await expectLater(
        cipher.decodeCommit(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        ),
        throwsFormatException,
      );
    },
  );

  test('commit retries are idempotent despite new nonces; swapped commit names rejected', () async {
    final transport = _Files();
    final adapter = FileSyncAdapter(
      connectionId: 'drive',
      transport: transport,
      cipher: cipher,
    );
    final bytes = await cipher.encryptObject(Uint8List.fromList([1, 2]));
    final id = sha256.convert(bytes).toString();
    await adapter.putObject(id, bytes);
    await adapter.putObject(id, bytes);
    await adapter.publish(revision(id));
    await adapter.publish(revision(id));
    expect(transport.files.length, 2);
    expect(
      (await adapter.changes(null)).revisions.single.encode(),
      revision(id).encode(),
    );
    final commit = transport.files.remove(
      FileSyncAdapter.commitName(revision(id)),
    )!;
    transport.files['c-${'0' * 64}.json'] = commit;
    await expectLater(
      adapter.changes(null),
      throwsA(isA<SyncProviderFailure>()),
    );
  });

  test(
    'equivalent encrypted representations publish one logical commit',
    () async {
      final transport = _Files();
      final adapter = FileSyncAdapter(
        connectionId: 'drive',
        transport: transport,
        cipher: cipher,
      );
      SyncRevision variant(String objectId, String fingerprint) => SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note',
        revisionId: 'same-edit',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: objectId,
        contentFingerprint: fingerprint,
      );
      await adapter.publish(variant('a' * 64, 'f' * 64));
      await adapter.publish(variant('b' * 64, 'f' * 64));
      expect(transport.files.length, 1);
      await expectLater(
        adapter.publish(variant('c' * 64, 'e' * 64)),
        throwsA(isA<SyncProviderFailure>()),
      );
    },
  );

  test('immutable object conflicts verify existing bytes instead of acknowledging corruption', () async {
    final transport = _Files();
    final adapter = FileSyncAdapter(
      connectionId: 'drive',
      transport: transport,
      cipher: cipher,
    );
    final bytes = await cipher.encryptObject(Uint8List.fromList([1]));
    final id = sha256.convert(bytes).toString();
    transport.files[FileSyncAdapter.objectName(id)] = Uint8List.fromList([9]);
    await expectLater(
      adapter.putObject(id, bytes),
      throwsA(isA<SyncProviderFailure>()),
    );
    await expectLater(
      adapter.readObject(id),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(
      () => FileSyncAdapter.objectName('../secret'),
      throwsFormatException,
    );
  });

  test('Dropbox paginates with opaque cursor and never treats physical deletion as a tombstone', () async {
    final calls = <http.Request>[];
    final client = MockClient((request) async {
      calls.add(request);
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer temporary-token');
      if (request.url.path.endsWith('create_folder_v2')) {
        return http.Response('{}', 200);
      }
      return http.Response(
        jsonEncode({
          'entries': [
            {'.tag': 'file', 'name': 'c-${'a' * 64}.json'},
            {'.tag': 'deleted', 'name': 'c-${'b' * 64}.json'},
          ],
          'cursor': 'next',
          'has_more': true,
        }),
        200,
      );
    });
    final transport = DropboxSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'temporary-token',
      libraryId: cipher.libraryId,
    );
    final first = await transport.list(null);
    expect(first.names, ['c-${'a' * 64}.json']);
    expect(first.hasMore, isTrue);
    await transport.list(first.cursor);
    expect(calls.last.url.path, '/2/files/list_folder/continue');
    expect(jsonDecode(calls.last.body), {'cursor': 'next'});
    expect(
      calls.where((c) => c.url.path.endsWith('create_folder_v2')).length,
      2,
    );
    client.close();
  });

  test(
    'Dropbox conflict, expired grant, quota and invalid cursor remain distinct',
    () async {
      var failure = 'path/conflict/file';
      var status = 409;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('create_folder_v2')) {
          return http.Response('{}', 200);
        }
        return http.Response(
          jsonEncode({'error_summary': '$failure/'}),
          status,
        );
      });
      final transport = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'token',
        libraryId: cipher.libraryId,
      );
      final name = 'o-${'a' * 64}';
      expect(await transport.create(name, Uint8List(1)), isFalse);
      failure = 'path/insufficient_space';
      await expectLater(
        transport.create(name, Uint8List(1)),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.quotaExceeded,
          ),
        ),
      );
      failure = 'reset';
      await expectLater(
        transport.list('stale'),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.invalidCursor,
          ),
        ),
      );
      status = 401;
      await expectLater(
        transport.read(name),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
      client.close();
    },
  );

  test(
    'large Dropbox upload uses bounded chunks and exact byte offsets',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.url.path.endsWith('upload_session/start')
              ? '{"session_id":"session"}'
              : '{}',
          200,
        );
      });
      final transport = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'token',
        libraryId: cipher.libraryId,
      );
      const chunk = 8 * 1024 * 1024;
      expect(
        await transport.create('o-${'a' * 64}', Uint8List(chunk * 2 + 5)),
        isTrue,
      );
      final uploads = requests
          .where((r) => r.url.host == 'content.dropboxapi.com')
          .toList();
      expect(uploads.map((r) => r.bodyBytes.length), [chunk, chunk, 5]);
      final append = jsonDecode(uploads[1].headers['Dropbox-API-Arg']!);
      final finish = jsonDecode(uploads[2].headers['Dropbox-API-Arg']!);
      expect(append['cursor']['offset'], chunk);
      expect(finish['cursor']['offset'], chunk * 2);
      expect(finish['commit']['strict_conflict'], isTrue);
      expect(finish['commit']['autorename'], isFalse);
      expect(finish['commit']['mode'], 'add');
      client.close();
    },
  );

  test(
    'HTTP rejects insecure endpoints, redirects and redacts error bodies',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.followRedirects, isFalse);
        return http.Response(
          'sensitive-provider-secret',
          302,
          headers: {'location': 'https://other.example'},
        );
      });
      final boundary = ProviderHttp(client);
      await expectLater(
        boundary.send('GET', Uri.parse('http://cloud.example'), headers: {}),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(requests, 0);
      final response = await boundary.send(
        'GET',
        Uri.parse('https://cloud.example'),
        headers: {},
      );
      expect(
        () => ProviderHttp.fail(response),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('sensitive-provider-secret')),
          ),
        ),
      );
      expect(requests, 1);
      client.close();
    },
  );
}

class _Files implements SyncFileTransport {
  final files = <String, Uint8List>{};
  @override
  Future<bool> create(String name, Uint8List bytes) async {
    if (files.containsKey(name)) return false;
    files[name] = bytes;
    return true;
  }

  @override
  Future<SyncFilePage> list(String? cursor) async =>
      SyncFilePage(names: files.keys.toList(), cursor: null, hasMore: false);
  @override
  Future<Uint8List> read(String name) async => files[name]!;
}
