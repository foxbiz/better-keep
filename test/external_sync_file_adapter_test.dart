import 'dart:async';
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

  test(
    'batch commits split at limits, verify retry content and reject corruption',
    () async {
      final files = _BatchFiles();
      final adapter = FileSyncAdapter(
        connectionId: 'batch',
        transport: files,
        cipher: cipher,
      );
      final revisions = List.generate(
        70,
        (i) => SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'n-$i',
          revisionId: 'r-$i',
          modifiedAtMicros: i,
          deleted: true,
          payloadObjectId: null,
        ),
      );
      await adapter.publishBatch(revisions);
      expect(files.sizes, [32, 32, 6]);
      await adapter.publishBatch(
        revisions,
      ); // Nonces differ, logical content matches.
      final data = Uint8List.fromList([1, 2, 3]);
      final id = sha256.convert(data).toString();
      await adapter.putObjects({id: data});
      await adapter.putObjects({id: data});
      files.files[FileSyncAdapter.objectName(id)] = Uint8List.fromList([9]);
      await expectLater(
        adapter.putObjects({id: data}),
        throwsA(isA<SyncProviderFailure>()),
      );
      files.files[FileSyncAdapter.commitName(revisions.first)] =
          Uint8List.fromList([9]);
      await expectLater(
        adapter.publishBatch(revisions),
        throwsA(isA<SyncProviderFailure>()),
      );
    },
  );

  test(
    'Dropbox folder initialization reports permanent write restrictions',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/2/files/create_folder_v2');
        return http.Response(
          jsonEncode({'error_summary': 'path/no_write_permission/'}),
          409,
        );
      });
      final transport = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic',
        libraryId: 'a' * 64,
      );
      final rejected = throwsA(
        isA<SyncProviderFailure>().having(
          (error) => error.kind,
          'kind',
          SyncProviderFailureKind.unsupported,
        ),
      );
      await expectLater(
        transport.create('o-${'a' * 64}', Uint8List(1)),
        rejected,
      );
      await expectLater(
        transport.createBatch({'o-${'a' * 64}': Uint8List(1)}),
        rejected,
      );
      client.close();
    },
  );

  test('Dropbox batches drain start failures and reject partial or malformed commits', () async {
    final releases = <Completer<void>>[];
    var active = 0, maximum = 0, starts = 0, finishes = 0;
    var block = true;
    var mode = 'success';
    final client = MockClient((request) async {
      if (request.url.path.endsWith('create_folder_v2')) {
        return http.Response('{}', 200);
      }
      if (request.url.path.endsWith('upload_session/start')) {
        starts++;
        active++;
        if (active > maximum) maximum = active;
        try {
          if (block) {
            final release = Completer<void>();
            releases.add(release);
            await release.future;
          }
          return http.Response(jsonEncode({'session_id': 's-$starts'}), 200);
        } finally {
          active--;
        }
      }
      expect(request.url.path, '/2/files/upload_session/finish_batch_v2');
      finishes++;
      final entries = (jsonDecode(request.body) as Map)['entries'] as List;
      for (final entry in entries) {
        expect(entry['commit']['mode'], 'add');
        expect(entry['commit']['strict_conflict'], isTrue);
        expect(entry['commit']['autorename'], isFalse);
        expect(entry['cursor']['offset'], 1);
      }
      if (mode == 'unauthorized') return http.Response('{}', 401);
      return http.Response(
        jsonEncode({
          'entries': mode == 'malformed'
              ? []
              : [
                  for (var i = 0; i < entries.length; i++)
                    if (i == 1 && mode != 'success')
                      {
                        '.tag': 'failure',
                        'failure': {
                          '.tag': mode == 'finish_busy'
                              ? 'too_many_write_operations'
                              : 'path',
                          if (mode != 'finish_busy') 'path': {'.tag': mode},
                        },
                      }
                    else
                      {'.tag': 'success'},
                ],
        }),
        200,
      );
    });
    final transport = DropboxSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'synthetic',
      libraryId: 'a' * 64,
    );
    final values = {
      for (var i = 0; i < 10; i++)
        'o-${i.toRadixString(16).padLeft(64, '0')}': Uint8List.fromList([i]),
    };
    var completed = false;
    final failed = expectLater(
      transport.createBatch(values).whenComplete(() => completed = true),
      throwsA(isA<StateError>()),
    );
    for (var i = 0; releases.length < 8 && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(releases, hasLength(8));
    releases.first.completeError(StateError('interrupted'));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    for (final release in releases.skip(1)) {
      release.complete();
    }
    await failed;
    expect(active, 0);
    expect(finishes, 0);
    expect(starts, 8);
    expect(maximum, 8);
    block = false;
    expect((await transport.createBatch(values)).values, everyElement(isTrue));
    mode = 'conflict';
    expect(
      (await transport.createBatch(values)).values.where((created) => !created),
      hasLength(1),
    );
    for (final failure in {
      'insufficient_space': SyncProviderFailureKind.quotaExceeded,
      'team_folder_insufficient_space': SyncProviderFailureKind.quotaExceeded,
      'member_folder_insufficient_space': SyncProviderFailureKind.quotaExceeded,
      'too_many_write_operations': SyncProviderFailureKind.rateLimited,
      'finish_busy': SyncProviderFailureKind.rateLimited,
      'no_write_permission': SyncProviderFailureKind.unsupported,
      'access_restricted': SyncProviderFailureKind.unsupported,
      'disallowed_name': SyncProviderFailureKind.unsupported,
      'malformed_path': SyncProviderFailureKind.unsupported,
      'team_folder': SyncProviderFailureKind.unsupported,
      'operation_suppressed': SyncProviderFailureKind.unsupported,
      'malformed': SyncProviderFailureKind.corruptData,
      'unauthorized': SyncProviderFailureKind.reconnectRequired,
    }.entries) {
      mode = failure.key;
      await expectLater(
        transport.createBatch(values),
        throwsA(
          isA<SyncProviderFailure>().having(
            (error) => error.kind,
            'kind',
            failure.value,
          ),
        ),
      );
    }
    final requests = starts;
    await expectLater(
      transport.createBatch({
        values.keys.first: Uint8List(SyncLimits.batchBytes + 1),
      }),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(starts, requests);
    client.close();
  });

  test(
    'failed commit pages drain active reads and never start queued reads',
    () async {
      final transport = _Files();
      final adapter = FileSyncAdapter(
        connectionId: 'qa',
        transport: transport,
        cipher: cipher,
      );
      for (var i = 0; i < 9; i++) {
        await adapter.publish(
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'note-$i',
            revisionId: 'revision-$i',
            modifiedAtMicros: i,
            deleted: true,
            payloadObjectId: null,
          ),
        );
      }
      final releases = <Completer<void>>[];
      var active = 0;
      transport.beforeRead = (_) async {
        final release = Completer<void>();
        releases.add(release);
        active++;
        try {
          await release.future;
        } finally {
          active--;
        }
      };
      var completed = false;
      final result = expectLater(
        adapter.changes(null).whenComplete(() => completed = true),
        throwsA(isA<SyncProviderFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(releases, hasLength(8));
      releases.first.completeError(
        const SyncProviderFailure(SyncProviderFailureKind.unavailable),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(active, 7);
      for (final release in releases.skip(1)) {
        release.complete();
      }
      await result;
      expect(active, 0);
      expect(releases, hasLength(8));
    },
  );

  test(
    'parallel commit reads serialize large legacy payload normalization',
    () async {
      final transport = _Files();
      var active = 0, maximum = 0, normalized = 0;
      final adapter = FileSyncAdapter(
        connectionId: 'legacy',
        transport: transport,
        cipher: cipher,
        normalizeLegacyRevision: (revision, _) async {
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          normalized++;
          return revision;
        },
      );
      for (var i = 0; i < 9; i++) {
        await adapter.publish(
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'legacy-$i',
            revisionId: 'revision-$i',
            modifiedAtMicros: i,
            deleted: false,
            payloadObjectId: 'a' * 64,
            contentFingerprint: 'b' * 64,
          ),
        );
      }
      final page = await adapter.changes(null);
      expect(
        page.revisions.map((r) => r.entityId),
        List.generate(9, (i) => 'legacy-$i'),
      );
      expect(normalized, 9);
      expect(maximum, 1);
    },
  );

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

  test('Dropbox small reads bound declared and streamed bodies; full reads remain available', () async {
    final bytes = Uint8List(SyncLimits.prefetchBytes + 1);
    for (final declared in [true, false]) {
      var calls = 0;
      final client = MockClient.streaming((request, body) async {
        calls++;
        return http.StreamedResponse(
          Stream.fromIterable([
            bytes.sublist(0, 600000),
            bytes.sublist(600000),
          ]),
          200,
          contentLength: declared ? bytes.length : null,
        );
      });
      final transport = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'test-token',
        libraryId: 'a' * 64,
      );
      final name = FileSyncAdapter.objectName(sha256.convert(bytes).toString());
      expect(await transport.readSmall(name), isNull);
      expect(await transport.read(name), bytes);
      expect(calls, 2);
      client.close();
    }
  });

  test(
    'small reads preserve authorization failures and authenticate ciphertext',
    () async {
      var status = 401;
      final client = MockClient((_) async => http.Response.bytes([9], status));
      final adapter = FileSyncAdapter(
        connectionId: 'qa',
        cipher: cipher,
        transport: DropboxSyncTransport(
          httpClient: ProviderHttp(client),
          accessToken: () async => 'test-token',
          libraryId: 'a' * 64,
        ),
      );
      expect(await adapter.supportsSmallReads, isTrue);
      await expectLater(
        adapter.readSmallObject('b' * 64),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
      status = 200;
      await expectLater(
        adapter.readSmallObject('b' * 64),
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

  test(
    'Dropbox initializes a missing library and retries its first listing once',
    () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        final route = request.url.pathSegments.last;
        calls.add(route);
        if (calls.length == 1) {
          return http.Response('{"error_summary":"path/not_found/"}', 409);
        }
        return http.Response(
          route == 'list_folder'
              ? '{"entries":[],"cursor":"next","has_more":false}'
              : '{}',
          200,
        );
      });
      addTearDown(client.close);
      final transport = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic',
        libraryId: cipher.libraryId,
      );
      expect((await transport.list(null)).cursor, 'next');
      expect(calls, [
        'list_folder',
        'create_folder_v2',
        'create_folder_v2',
        'list_folder',
      ]);
    },
  );

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
      calls.where((c) => c.url.path.endsWith('create_folder_v2')),
      isEmpty,
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
      for (final entry in {
        'path/no_write_permission': SyncProviderFailureKind.unsupported,
        'path/access_restricted': SyncProviderFailureKind.unsupported,
        'path/disallowed_name': SyncProviderFailureKind.unsupported,
        'path/malformed_path': SyncProviderFailureKind.unsupported,
        'path/team_folder': SyncProviderFailureKind.unsupported,
        'path/operation_suppressed': SyncProviderFailureKind.unsupported,
        'path/insufficient_space': SyncProviderFailureKind.quotaExceeded,
        'path/team_folder_insufficient_space':
            SyncProviderFailureKind.quotaExceeded,
        'path/member_folder_insufficient_space':
            SyncProviderFailureKind.quotaExceeded,
        'path/too_many_write_operations': SyncProviderFailureKind.rateLimited,
        'too_many_write_operations': SyncProviderFailureKind.rateLimited,
      }.entries) {
        failure = entry.key;
        await expectLater(
          transport.create(name, Uint8List(1)),
          throwsA(
            isA<SyncProviderFailure>().having(
              (error) => error.kind,
              'kind',
              entry.value,
            ),
          ),
        );
      }
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
  Future<void> Function(String)? beforeRead;
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
  Future<Uint8List> read(String name) async {
    await beforeRead?.call(name);
    return files[name]!;
  }
}

class _BatchFiles extends _Files implements BatchSyncFileWriter {
  final sizes = <int>[];
  @override
  Future<Map<String, bool>> createBatch(Map<String, Uint8List> values) async {
    sizes.add(values.length);
    expect(
      values.values.fold<int>(0, (sum, data) => sum + data.length),
      lessThanOrEqualTo(SyncLimits.batchBytes),
    );
    return {
      for (final entry in values.entries)
        entry.key: await create(entry.key, entry.value),
    };
  }
}
