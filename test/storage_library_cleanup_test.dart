import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/google_drive_sync_transport.dart';
import 'package:better_keep/services/external_sync/nextcloud_sync_transport.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';

import 'package:better_keep/services/external_sync/sync_metadata_index.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';

import 'support/drive_http_fixture.dart';

void main() {
  final library = 'a' * 64;
  test('Dropbox clears only this library without creating folders; missing root is safe', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      expect(r.url.path, '/2/files/delete_batch');
      expect(jsonDecode(r.body), {
        'entries': [
          {'path': '/betterkeep-v1/$library'},
        ],
      });
      return http.Response(
        '{".tag":"complete","entries":[{".tag":"failure","failure":{".tag":"path_lookup","path_lookup":{".tag":"not_found"}}}]}',
        200,
      );
    });
    await DropboxSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'test',
      libraryId: library,
    ).clearLibrary();
    expect(calls, 1);
    client.close();
  });
  testWidgets('Dropbox waits for asynchronous deletion completion', (
    tester,
  ) async {
    var polls = 0, done = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/delete_batch')) {
        expectSync(jsonDecode(request.body)['entries'], [
          {'path': '/betterkeep-v1/$library'},
        ]);
        return http.Response(
          '{".tag":"async_job_id","async_job_id":"job"}',
          200,
        );
      }
      expectSync(request.url.path, '/2/files/delete_batch/check');
      expectSync(jsonDecode(request.body), {'async_job_id': 'job'});
      polls++;
      return http.Response(
        polls == 1
            ? '{".tag":"in_progress"}'
            : '{".tag":"complete","entries":[{".tag":"success"}]}',
        200,
      );
    });
    addTearDown(client.close);
    final clearing = DropboxSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'test',
      libraryId: library,
    ).clearLibrary().then((_) => done = true);
    await tester.pump();
    expect(done, false);
    expect(polls, 1);
    await tester.pump(const Duration(seconds: 2));
    await clearing;
    expect(done, true);
    expect(polls, 2);
  });

  test(
    'Dropbox batch write throttling preserves rate limit and retry delay',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          '{".tag":"complete","entries":[{".tag":"failure","failure":{".tag":"too_many_write_operations"}}]}',
          200,
          headers: {'retry-after': '12'},
        ),
      );
      addTearDown(client.close);
      await expectLater(
        DropboxSyncTransport(
          httpClient: ProviderHttp(client),
          accessToken: () async => 'test',
          libraryId: library,
        ).clearLibrary(),
        throwsA(
          isA<SyncProviderFailure>()
              .having(
                (e) => e.kind,
                'kind',
                SyncProviderFailureKind.rateLimited,
              )
              .having(
                (e) => e.retryAfter,
                'retry delay',
                const Duration(seconds: 12),
              ),
        ),
      );
    },
  );

  test('Dropbox rejects failed or malformed batch completion', () async {
    for (final result in [
      {'.tag': 'complete', 'entries': <Object>[]},
      {
        '.tag': 'complete',
        'entries': [
          {
            '.tag': 'failure',
            'failure': {'.tag': 'too_many_write_operations'},
          },
        ],
      },
      {'.tag': 'async_job_id', 'async_job_id': ''},
      {'.tag': 'in_progress'},
    ]) {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(jsonEncode(result), 200);
      });
      addTearDown(client.close);
      await expectLater(
        DropboxSyncTransport(
          httpClient: ProviderHttp(client),
          accessToken: () async => 'test',
          libraryId: library,
        ).clearLibrary(),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
    }
  });

  test('Drive clears with bounded concurrency', () async {
    final drive = DriveHttpFixture();
    for (var i = 0; i < 12; i++) {
      final logical = 'o-${i.toRadixString(16).padLeft(64, '0')}';
      drive.files['file-$i'] = Uint8List(0);
      drive.metadata['file-$i'] = {
        'id': 'file-$i',
        'name': 'bk1-$library-$logical',
        'appProperties': {
          'library': library,
          'protocol': '1',
          'logical': logical,
        },
      };
    }
    var active = 0, peak = 0;
    final client = MockClient((request) async {
      if (request.method != 'DELETE') return drive.handle(request);
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      try {
        return await drive.handle(request);
      } finally {
        active--;
      }
    });
    addTearDown(client.close);
    await GoogleDriveSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'synthetic-access',
      libraryId: library,
    ).clearLibrary();
    expect(peak, 4);
    expect(active, 0);
    expect(drive.files, isEmpty);
  });

  test(
    'Nextcloud clears only the account library and never initializes it',
    () async {
      final client = MockClient((r) async {
        expect(r.method, 'DELETE');
        expect(r.url.path, '/remote.php/dav/files/test/BetterKeep/$library/');
        return http.Response('', 204);
      });
      await NextcloudSyncTransport(
        httpClient: ProviderHttp(client),
        server: Uri.https('example.test'),
        username: 'test',
        appPassword: () async => 'test',
        libraryId: library,
      ).clearLibrary();
      client.close();
    },
  );
  test('Drive validates every deletion and relists instead of skipping changed pages', () async {
    var lists = 0, deletes = 0, indexLists = 0;
    final name = 'o-${'b' * 64}';
    final client = MockClient((r) async {
      if (r.method == 'DELETE') {
        deletes++;
        expect(
          r.url.path,
          deletes == 1 ? '/drive/v3/files/file1' : '/drive/v3/files/index1',
        );
        return http.Response('', 204);
      }
      expect(r.url.queryParameters['q'], contains("value='$library'"));
      expect(r.url.queryParameters.containsKey('pageToken'), false);
      if (r.url.queryParameters['q']!.contains("key='indexLibrary'")) {
        indexLists++;
        return http.Response(
          jsonEncode({
            'files': indexLists == 1
                ? [
                    {
                      'id': 'index1',
                      'name': 'bk1-$library-${SyncMetadataIndex.fileName}',
                      'appProperties': {'indexLibrary': library},
                    },
                  ]
                : [],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'files': lists++ == 0
              ? [
                  {
                    'id': 'file1',
                    'name': 'bk1-$library-$name',
                    'appProperties': {
                      'library': library,
                      'protocol': '1',
                      'logical': name,
                    },
                  },
                ]
              : [],
        }),
        200,
      );
    });
    await GoogleDriveSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'test',
      libraryId: library,
    ).clearLibrary();
    expect(lists, 2);
    expect(indexLists, 2);
    expect(deletes, 2);
    client.close();
  });
  test('Drive cleanup removes v1, v2 and v3 indexes across batches, preserving other libraries', () async {
    final drive = DriveHttpFixture();
    for (var i = 0; i < 121; i++) {
      final page =
          'metadata-index-v2-${i.toRadixString(16).padLeft(64, '0')}.json';
      drive.files['page-$i'] = Uint8List(0);
      drive.metadata['page-$i'] = {
        'id': 'page-$i',
        'name': 'bk1-$library-$page',
        'appProperties': {'indexLibrary': library},
      };
    }
    for (final name in [
      'metadata-index-v1.json',
      'metadata-index-v2.json',
      SyncMetadataIndex.fileName,
      SyncMetadataIndex.pageName(1),
    ]) {
      drive.files[name] = Uint8List(0);
      drive.metadata[name] = {
        'id': name,
        'name': 'bk1-$library-$name',
        'appProperties': {'indexLibrary': library},
      };
    }
    drive.files['foreign'] = Uint8List.fromList([1]);
    drive.metadata['foreign'] = {
      'id': 'foreign',
      'name': 'other-library',
      'appProperties': {'indexLibrary': 'b' * 64},
    };
    final client = MockClient(drive.handle);
    addTearDown(client.close);
    await GoogleDriveSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'synthetic-access',
      libraryId: library,
    ).clearLibrary();
    expect(drive.files.keys, ['foreign']);
    expect(drive.metadata.keys, ['foreign']);
  });
  test('foreign Drive result cannot authorize deletion', () async {
    final client = MockClient((r) async {
      expect(r.method, 'GET');
      return http.Response(
        jsonEncode({
          'files': [
            {
              'id': 'valid-first',
              'name': 'bk1-$library-o-${'b' * 64}',
              'appProperties': {
                'library': library,
                'protocol': '1',
                'logical': 'o-${'b' * 64}',
              },
            },
            {
              'id': 'foreign',
              'name': 'foreign',
              'appProperties': {'library': 'b' * 64, 'protocol': '1'},
            },
          ],
        }),
        200,
      );
    });
    await expectLater(
      GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'test',
        libraryId: library,
      ).clearLibrary(),
      throwsFormatException,
    );
    client.close();
  });
  test('foreign Drive index cannot authorize deletion', () async {
    final client = MockClient((r) async {
      expect(r.method, 'GET', reason: 'No foreign file may be deleted');
      final indexes = r.url.queryParameters['q']!.contains(
        "key='indexLibrary'",
      );
      return http.Response(
        jsonEncode({
          'files': indexes
              ? [
                  {
                    'id': 'foreign-index',
                    'name': 'bk1-$library-${SyncMetadataIndex.fileName}',
                    'appProperties': {'indexLibrary': 'b' * 64},
                  },
                ]
              : [],
        }),
        200,
      );
    });
    addTearDown(client.close);
    await expectLater(
      GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'test',
        libraryId: library,
      ).clearLibrary(),
      throwsFormatException,
    );
  });
  test('reset namespace is keyed to this library; old records retain their path and cursor', () async {
    final a = await SyncCipher.create('a', Uint8List(32));
    final b = await SyncCipher.create('b', Uint8List(32));
    expect(a.storageNamespace('dropbox', ''), a.libraryId);
    expect(
      a.storageNamespace('dropbox', '1' * 64),
      isNot(b.storageNamespace('dropbox', '1' * 64)),
    );
    expect(
      a.storageNamespace('dropbox', '1' * 64),
      isNot(a.storageNamespace('google_drive', '1' * 64)),
    );
    StorageConnection connection(String epoch) => StorageConnection(
      provider: 'dropbox',
      libraryId: a.libraryId,
      accountLabel: '',
      encryptedCapability: '',
      generation: 1,
      enabled: true,
      state: 'ready',
      storageEpoch: epoch,
    );
    expect(connection('').replicaId, 'dropbox:1');
    expect(connection('1' * 64).replicaId, isNot(connection('').replicaId));
    a.dispose();
    b.dispose();
  });
}
