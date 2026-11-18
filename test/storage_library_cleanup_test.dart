import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/google_drive_sync_transport.dart';
import 'package:better_keep/services/external_sync/nextcloud_sync_transport.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';

void main() {
  final library = 'a' * 64;
  test('Dropbox clears only this library without creating folders; missing root is safe', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      expect(r.url.path, '/2/files/delete_v2');
      expect(jsonDecode(r.body), {'path': '/betterkeep-v1/$library'});
      return http.Response(
        '{"error_summary":"path_lookup/not_found/..."}',
        409,
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
    var lists = 0, deletes = 0;
    final name = 'o-${'b' * 64}';
    final client = MockClient((r) async {
      if (r.method == 'DELETE') {
        deletes++;
        expect(r.url.path, '/drive/v3/files/file1');
        return http.Response('', 204);
      }
      expect(r.url.queryParameters['q'], contains("value='$library'"));
      expect(r.url.queryParameters.containsKey('pageToken'), false);
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
    expect(deletes, 1);
    client.close();
  });
  test('foreign Drive result cannot authorize deletion', () async {
    final client = MockClient((r) async {
      expect(r.method, 'GET');
      return http.Response(
        jsonEncode({
          'files': [
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
