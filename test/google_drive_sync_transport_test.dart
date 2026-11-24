import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/google_drive_sync_transport.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/external_sync/sync_limits.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final library = 'a' * 64;
  final name = 'c-${'b' * 64}.json';
  Map<String, dynamic> metadata(String id, String logical, {String? owner}) => {
    'id': id,
    'name': 'bk1-${owner ?? library}-$logical',
    'appProperties': {
      'library': owner ?? library,
      'protocol': '1',
      'logical': logical,
    },
  };
  GoogleDriveSyncTransport transport(http.Client client, {String? libraryId}) =>
      GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'token',
        libraryId: libraryId ?? library,
      );
  http.Response json(Object data, [int status = 200]) =>
      http.Response(jsonEncode(data), status);

  test(
    'bounded Drive prefetch validates every duplicate object copy',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final logical = 'o-${sha256.convert(bytes)}';
      var corrupt = false;
      final reads = <String>[];
      final drive = transport(
        MockClient((request) async {
          if (request.url.queryParameters['alt'] == 'media') {
            final id = request.url.pathSegments.last;
            reads.add(id);
            return http.Response.bytes(
              corrupt && id == 'two' ? [9] : bytes,
              200,
            );
          }
          return json({
            'files': [metadata('one', logical), metadata('two', logical)],
          });
        }),
      );
      expect(await drive.readSmall(logical), bytes);
      expect(reads, ['one', 'two']);
      corrupt = true;
      await expectLater(
        drive.readSmall(logical),
        throwsA(
          isA<SyncProviderFailure>().having(
            (failure) => failure.kind,
            'kind',
            SyncProviderFailureKind.corruptData,
          ),
        ),
      );
    },
  );

  test(
    'large Drive objects fall back without relaxing regular size validation',
    () async {
      final logical = 'o-${'d' * 64}';
      final bytes = Uint8List(SyncLimits.prefetchBytes + 1);
      final drive = transport(
        MockClient((request) async {
          if (request.url.queryParameters['alt'] == 'media') {
            return http.Response.bytes(bytes, 200);
          }
          return json({
            'files': [metadata('one', logical)],
          });
        }),
      );
      expect(await drive.readSmall(logical), isNull);
      expect(await drive.read(logical), bytes);
      expect(await drive.readSmall(name), isNull);
    },
  );

  test('Drive prefetch bounds the combined size of duplicate copies', () async {
    final logical = 'o-${'d' * 64}';
    final bytes = Uint8List(SyncLimits.prefetchBytes ~/ 2 + 1);
    final drive = transport(
      MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          return http.Response.bytes(bytes, 200);
        }
        return json({
          'files': [metadata('one', logical), metadata('two', logical)],
        });
      }),
    );
    expect(await drive.readSmall(logical), isNull);
  });

  test('bootstrap captures boundary before listing and drains changes without a gap', () async {
    final calls = <String>[];
    final client = MockClient((request) async {
      calls.add(request.url.path);
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer token');
      if (request.url.path.endsWith('startPageToken')) {
        return json({'startPageToken': 'boundary'});
      }
      if (request.url.path.endsWith('files')) {
        expect(request.url.queryParameters['spaces'], 'appDataFolder');
        if (request.url.queryParameters['pageToken'] == null) {
          return json({
            'files': [metadata('file1', name)],
            'nextPageToken': 'page2',
          });
        }
        return json({'files': []});
      }
      expect(request.url.queryParameters['pageToken'], 'boundary');
      return json({
        'changes': [
          {'removed': true},
          {'file': metadata('other', name, owner: 'c' * 64)},
          {'file': metadata('file2', name)},
        ],
        'newStartPageToken': 'caught-up',
      });
    });
    final drive = transport(client);
    final first = await drive.list(null);
    expect(first.names, [name]);
    expect(first.hasMore, isTrue);
    final second = await drive.list(first.cursor);
    expect(second.hasMore, isTrue);
    final third = await drive.list(second.cursor);
    expect(third.hasMore, isFalse);
    expect(third.names, [name]);
    expect(jsonDecode(third.cursor!)['token'], 'caught-up');
    expect(calls.first, '/drive/v3/changes/startPageToken');
    client.close();
  });

  test(
    'small binary files use one multipart upload with private metadata',
    () async {
      final requests = <http.Request>[];
      final bytes = Uint8List.fromList([0, 13, 10, 255, 128, 1]);
      final drive = transport(
        MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') return json({'files': []});
          expect(request.method, 'POST');
          expect(request.url.queryParameters['uploadType'], 'multipart');
          expect(request.followRedirects, false);
          final boundary = request.headers['Content-Type']!
              .split('boundary=')
              .last;
          final body = latin1.decode(request.bodyBytes);
          final parts = body.split('--$boundary');
          expect(parts, hasLength(4));
          final data = jsonDecode(parts[1].split('\r\n\r\n')[1].trim());
          expect(data['parents'], ['appDataFolder']);
          expect(data['appProperties']['library'], library);
          expect(data['appProperties']['logical'], name);
          expect(
            parts[2],
            '\r\nContent-Type: application/octet-stream\r\n\r\n'
            '${latin1.decode(bytes)}\r\n',
          );
          return json({'id': 'created'}, 200);
        }),
      );
      expect(await drive.create(name, bytes), true);
      expect(requests.map((r) => r.method), ['GET', 'POST']);
    },
  );

  test(
    'multipart threshold stays independent of cache prefetch sizing',
    () async {
      expect(GoogleDriveSyncTransport.multipartUploadBytes, 1024 * 1024);
      for (final size in [1024 * 1024, 1024 * 1024 + 1]) {
        String? uploadType;
        final client = MockClient((request) async {
          if (request.method == 'GET') return json({'files': []});
          if (request.method == 'POST') {
            uploadType = request.url.queryParameters['uploadType'];
            if (uploadType == 'multipart') return json({'id': 'small'});
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=test',
              },
            );
          }
          return json({'id': 'large'}, 201);
        });
        addTearDown(client.close);
        expect(await transport(client).create(name, Uint8List(size)), true);
        expect(uploadType, size == 1024 * 1024 ? 'multipart' : 'resumable');
      }
    },
  );

  test(
    'lost multipart response leaves an immutable file for verified retry',
    () async {
      var created = false;
      var posts = 0;
      final drive = transport(
        MockClient((request) async {
          if (request.method == 'GET') {
            return json({
              'files': created ? [metadata('existing', name)] : [],
            });
          }
          posts++;
          created = true;
          throw http.ClientException('lost response');
        }),
      );
      await expectLater(
        drive.create(name, Uint8List(3)),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(await drive.create(name, Uint8List(3)), false);
      expect(posts, 1);
    },
  );

  test(
    'resumable upload commits metadata and acknowledges exact chunk ranges',
    () async {
      const chunk = 8 * 1024 * 1024;
      final putRanges = <String>[];
      final client = MockClient((request) async {
        if (request.method == 'GET') return json({'files': []});
        if (request.method == 'POST') {
          final body = jsonDecode(request.body);
          expect(body['parents'], ['appDataFolder']);
          expect(body['appProperties']['library'], library);
          expect(body['appProperties']['logical'], name);
          expect(request.headers['X-Upload-Content-Length'], '${chunk + 7}');
          return http.Response(
            '',
            200,
            headers: {
              'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=abc',
            },
          );
        }
        final range = request.headers['Content-Range']!;
        putRanges.add(range);
        if (putRanges.length == 1) {
          return http.Response(
            '',
            308,
            headers: {'range': 'bytes=0-${chunk - 1}'},
          );
        }
        return json({'id': 'created'}, 201);
      });
      expect(
        await transport(client).create(name, Uint8List(chunk + 7)),
        isTrue,
      );
      expect(putRanges, [
        'bytes 0-${chunk - 1}/${chunk + 7}',
        'bytes $chunk-${chunk + 6}/${chunk + 7}',
      ]);
      client.close();
    },
  );

  test(
    'resumes a partially persisted final chunk from its acknowledged offset',
    () async {
      final ranges = <String>[];
      const size = GoogleDriveSyncTransport.multipartUploadBytes + 10;
      final drive = transport(
        MockClient((request) async {
          if (request.method == 'GET') return json({});
          if (request.method == 'POST') {
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=test',
              },
            );
          }
          ranges.add(request.headers['Content-Range']!);
          return ranges.length == 1
              ? http.Response('', 308, headers: {'range': 'bytes=0-3'})
              : json({'id': 'complete'}, 201);
        }),
      );
      expect(await drive.create(name, Uint8List(size)), true);
      expect(ranges, [
        'bytes 0-${size - 1}/$size',
        'bytes 4-${size - 1}/$size',
      ]);
    },
  );

  test(
    'a resumable upload with no progress stops after bounded retries',
    () async {
      var puts = 0;
      final drive = transport(
        MockClient((request) async {
          if (request.method == 'GET') return json({});
          if (request.method == 'POST') {
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=test',
              },
            );
          }
          puts++;
          return http.Response('', 308);
        }),
      );
      await expectLater(
        drive.create(
          name,
          Uint8List(GoogleDriveSyncTransport.multipartUploadBytes + 1),
        ),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(puts, 3);
    },
  );

  test('existing name never starts an overwrite or another upload', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      return json({
        'files': [metadata('existing', name)],
      });
    });
    expect(await transport(client).create(name, Uint8List(1)), isFalse);
    client.close();
  });

  test('repeating lookup page tokens cannot loop indefinitely', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return json({'files': [], 'nextPageToken': 'same'});
    });
    await expectLater(
      transport(client).create(name, Uint8List(1)),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.corruptData,
        ),
      ),
    );
    expect(calls, 2);
    client.close();
  });

  test('interrupted upload retries discover completed remote file', () async {
    var published = false;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return json({
          'files': published ? [metadata('existing', name)] : [],
        });
      }
      if (request.method == 'POST') {
        return http.Response(
          '',
          200,
          headers: {
            'location': 'https://www.googleapis.com/upload/drive/v3/files?upload_id=abc',
          },
        );
      }
      published = true;
      throw http.ClientException('lost response');
    });
    final drive = transport(client);
    await expectLater(
      drive.create(
        name,
        Uint8List(GoogleDriveSyncTransport.multipartUploadBytes + 1),
      ),
      throwsA(isA<SyncProviderFailure>()),
    );
    expect(
      await drive.create(
        name,
        Uint8List(GoogleDriveSyncTransport.multipartUploadBytes + 1),
      ),
      isFalse,
    );
    client.close();
  });

  test(
    'upload session cannot redirect credentials to another origin',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') return json({'files': []});
        return http.Response(
          '',
          200,
          headers: {'location': 'https://evil.example/upload'},
        );
      });
      await expectLater(
        transport(client).create(
          name,
          Uint8List(GoogleDriveSyncTransport.multipartUploadBytes + 1),
        ),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(requests.length, 2);
      client.close();
    },
  );

  test('Drive quota, rate limits and expired cursors have actionable failure kinds', () async {
    var reason = 'storageQuotaExceeded';
    var status = 403;
    final client = MockClient(
      (request) async => json({
        'error': {
          'errors': [
            {'reason': reason},
          ],
        },
      }, status),
    );
    final drive = transport(client);
    await expectLater(
      drive.create(name, Uint8List(1)),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.quotaExceeded,
        ),
      ),
    );
    reason = 'userRateLimitExceeded';
    await expectLater(
      drive.create(name, Uint8List(1)),
      throwsA(
        isA<SyncProviderFailure>().having(
          (e) => e.kind,
          'kind',
          SyncProviderFailureKind.rateLimited,
        ),
      ),
    );
    status = 410;
    await expectLater(
      drive.list(
        jsonEncode({
          'v': 1,
          'library': library,
          'phase': 'changes',
          'token': 'expired',
        }),
      ),
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

  test('duplicate Drive commits must decrypt to identical revisions, regardless of nonce', () async {
    final cipher = await SyncCipher.create(
      'user',
      Uint8List.fromList(List.filled(32, 1)),
    );
    addTearDown(cipher.dispose);
    final payload = await cipher.encryptObject(Uint8List.fromList([1]));
    final revision = SyncRevision(
      kind: SyncEntityKind.note,
      entityId: 'note',
      revisionId: 'rev',
      modifiedAtMicros: 1,
      deleted: false,
      payloadObjectId: sha256.convert(payload).toString(),
    );
    final logical = FileSyncAdapter.commitName(revision);
    final one = await cipher.encodeCommit(revision);
    var two = await cipher.encodeCommit(revision);
    final client = MockClient((request) async {
      if (request.url.queryParameters['alt'] == 'media') {
        return http.Response.bytes(
          request.url.path.endsWith('one') ? one : two,
          200,
        );
      }
      return json({
        'files': [
          metadata('one', logical, owner: cipher.libraryId),
          metadata('two', logical, owner: cipher.libraryId),
        ],
      });
    });
    final adapter = FileSyncAdapter(
      connectionId: 'drive',
      cipher: cipher,
      transport: transport(client, libraryId: cipher.libraryId),
    );
    await adapter.publish(
      revision,
    ); // Existing names are checked, not replaced.
    two = await cipher.encodeCommit(
      SyncRevision(
        kind: revision.kind,
        entityId: revision.entityId,
        revisionId: revision.revisionId,
        modifiedAtMicros: 2,
        deleted: false,
        payloadObjectId: revision.payloadObjectId,
      ),
    );
    await expectLater(
      adapter.publish(revision),
      throwsA(isA<SyncProviderFailure>()),
    );
    client.close();
  });
}
