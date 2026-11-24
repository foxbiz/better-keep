import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/google_drive_sync_transport.dart';
import 'package:better_keep/services/external_sync/nextcloud_sync_transport.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_metadata_index.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/external_sync/webdav_sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/drive_http_fixture.dart';
import 'support/dropbox_http_fixture.dart';
import 'support/webdav_server.dart';

void main() {
  for (final invalidCopies in [1, 3]) {
    test(
      'Drive tries at most three authenticated index copies ($invalidCopies invalid)',
      () async {
        final cipher = await SyncCipher.create('duplicate-qa', Uint8List(32));
        addTearDown(cipher.dispose);
        final drive = DriveHttpFixture();
        final client = MockClient(drive.handle);
        addTearDown(client.close);
        GoogleDriveSyncTransport transport() => GoogleDriveSyncTransport(
          httpClient: ProviderHttp(client),
          accessToken: () async => 'synthetic-access',
          libraryId: cipher.libraryId,
        );
        FileSyncAdapter adapter() => FileSyncAdapter(
          connectionId: 'drive',
          cipher: cipher,
          transport: transport(),
        );
        final value = SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'one',
          revisionId: 'one',
          modifiedAtMicros: 1,
          deleted: false,
          payloadObjectId: 'a' * 64,
        );
        Future<List<SyncRevision>> scan(FileSyncAdapter source) async {
          final revisions = <SyncRevision>[];
          String? cursor;
          while (true) {
            final page = await source.changes(cursor);
            revisions.addAll(page.revisions);
            if (!page.hasMore) return revisions;
            cursor = page.cursor;
          }
        }

        final first = adapter();
        await first.publish(value);
        await scan(first);
        await first.maintainIndex();
        final validId = drive.metadata.entries
            .singleWhere(
              (e) => (e.value['appProperties'] as Map)['indexLibrary'] != null,
            )
            .key;
        for (var i = 0; i < invalidCopies; i++) {
          final id = 'a-invalid-$i';
          drive.files[id] = Uint8List.fromList([123]);
          drive.metadata[id] = {...drive.metadata[validId]!, 'id': id};
        }
        final reads = drive.mediaReads;
        expect((await scan(adapter())).single.entityId, 'one');
        expect(
          drive.mediaReads - reads,
          invalidCopies == 1 ? 2 : 4,
          reason:
              'Try three cache copies at most, then read the original commit',
        );
        // A validated head is pinned, so later reads do not retry the bad copy.
        if (invalidCopies == 1) {
          final reader = transport();
          final index = SyncMetadataIndex(cipher, 'drive');
          expect(
            await index.loadChain(
              (name) => reader.readIndex(name: name),
              readValidated: reader.readValidatedIndex,
            ),
            true,
          );
          final lookups = drive.lookups;
          final media = drive.mediaReads;
          await index.loadChain(
            (name) => reader.readIndex(name: name),
            readValidated: reader.readValidatedIndex,
          );
          expect(drive.lookups, lookups);
          expect(drive.mediaReads, media + 1);
        }
      },
    );
  }

  testWidgets(
    'optional request timeout shortens but never extends the HTTP deadline',
    (tester) async {
      for (final shorterBoundary in [false, true]) {
        final pending = Completer<http.Response>();
        final client = MockClient((_) => pending.future);
        final boundary = ProviderHttp(
          client,
          timeout: Duration(seconds: shorterBoundary ? 1 : 60),
        );
        Object? failure;
        unawaited(
          boundary
              .send(
                'GET',
                Uri.parse('https://example.test/index'),
                headers: {},
                requestTimeout: Duration(seconds: shorterBoundary ? 60 : 1),
              )
              .then<void>(
                (_) => fail('A stalled request must not succeed'),
                onError: (Object error) {
                  failure = error;
                },
              ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(
          failure,
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.unavailable,
          ),
        );
        // A late response must be discarded, not start a second operation.
        pending.complete(http.Response('late', 200));
        await tester.pump();
        client.close();
      }
    },
  );
  test(
    'Drive reuses the resolved index id and rediscovers it after removal',
    () async {
      final drive = DriveHttpFixture();
      final client = MockClient(drive.handle);
      addTearDown(client.close);
      final transport = GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic-access',
        libraryId: 'a' * 64,
      );
      await transport.writeIndex(Uint8List.fromList([1]));
      final lookups = drive.lookups;
      expect(await transport.readIndex(), [1]);
      expect(
        drive.lookups,
        lookups,
        reason: 'Creation retains the returned id',
      );
      await transport.writeIndex(Uint8List.fromList([2]));
      expect(await transport.readIndex(), [2]);
      expect(drive.lookups, lookups);
      drive.files.clear();
      drive.metadata.clear();
      expect(await transport.readIndex(), isNull);
      await transport.writeIndex(Uint8List.fromList([3]));
      expect(drive.indexWrites, 3);
      expect(drive.lookups, lookups + 1);
    },
  );

  test('failed Drive cleanup rediscovers the index on the next read', () async {
    final drive = DriveHttpFixture();
    var failCleanup = false;
    final client = MockClient((request) async {
      if (failCleanup) return http.Response('', 503);
      return drive.handle(request);
    });
    addTearDown(client.close);
    final transport = GoogleDriveSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'synthetic-access',
      libraryId: 'a' * 64,
    );
    await transport.writeIndex(Uint8List.fromList([1]));
    failCleanup = true;
    await expectLater(
      transport.clearLibrary(),
      throwsA(isA<SyncProviderFailure>()),
    );
    failCleanup = false;
    // Another client replaces the index while cleanup is interrupted.
    final oldId = drive.files.keys.single;
    drive.files.remove(oldId);
    drive.files['replacement'] = Uint8List.fromList([2]);
    drive.metadata['replacement'] = {
      ...drive.metadata.remove(oldId)!,
      'id': 'replacement',
    };
    expect(await transport.readIndex(), [2]);
  });

  test(
    'closed operation maps rejection before dispatch and sends no request',
    () async {
      late Zone operationZone;
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      addTearDown(client.close);
      final boundary = ProviderHttp(client);
      await ProviderHttp.withOperationTimeout(
        const Duration(seconds: 1),
        () async {
          operationZone = Zone.current;
        },
      );
      await expectLater(
        operationZone.run(
          () => boundary.send(
            'GET',
            Uri.parse('https://example.test/index'),
            headers: {},
          ),
        ),
        throwsA(
          isA<SyncProviderFailure>().having(
            (error) => error.kind,
            'kind',
            SyncProviderFailureKind.unavailable,
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test('Drive retains the id returned by resumable index creation', () async {
    final drive = DriveHttpFixture();
    final client = MockClient(drive.handle);
    addTearDown(client.close);
    final transport = GoogleDriveSyncTransport(
      httpClient: ProviderHttp(client),
      accessToken: () async => 'synthetic-access',
      libraryId: 'a' * 64,
    );
    final bytes = Uint8List(GoogleDriveSyncTransport.multipartUploadBytes + 1);
    await transport.writeIndex(bytes);
    final lookups = drive.lookups;
    await transport.writeIndex(Uint8List.fromList([2]));
    expect(await transport.readIndex(), [2]);
    expect(drive.lookups, lookups);
    expect(drive.indexWrites, 2);
  });

  for (final stalled in ['token', 'lookup', 'upload', 'refresh']) {
    testWidgets('expired index operation rejects late $stalled continuation', (
      tester,
    ) async {
      final token = Completer<String>();
      final response = Completer<http.Response>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (stalled == 'lookup') return response.future;
        if (stalled == 'refresh') return http.Response('', 401);
        if (request.method == 'GET') return http.Response('{"files":[]}', 200);
        return response.future;
      });
      addTearDown(client.close);
      final transport = GoogleDriveSyncTransport(
        httpClient: ProviderHttp(
          client,
          refreshRejectedToken: (_) => token.future,
        ),
        accessToken: () => stalled == 'token'
            ? token.future
            : Future.value('synthetic-access'),
        libraryId: 'a' * 64,
      );
      Object? failure;
      final write =
          ProviderHttp.withOperationTimeout(
            SyncMetadataIndex.writeTimeout,
            () => transport.writeIndex(Uint8List.fromList([1])),
          ).then<void>(
            (_) => fail('Expired write must not succeed'),
            onError: (Object error) {
              failure = error;
            },
          );
      await tester.pump();
      await tester.pump(SyncMetadataIndex.writeTimeout);
      await write;
      expect(failure, isA<TimeoutException>());
      final count = requests;
      token.complete('new-synthetic-access');
      response.complete(
        http.Response(
          stalled == 'lookup' ? '{"files":[]}' : '{"id":"late"}',
          200,
        ),
      );
      await tester.pump();
      expect(
        requests,
        count,
        reason: 'No request may start after the operation expired',
      );
    });
  }

  test('operation expiry cancels a stalled response body', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(body.stream, 200),
    );
    addTearDown(client.close);
    final boundary = ProviderHttp(client);
    await expectLater(
      ProviderHttp.withOperationTimeout(
        const Duration(milliseconds: 10),
        () => boundary.send(
          'PUT',
          Uri.parse('https://example.test/index'),
          headers: {},
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // The HTTP branch drains cancellation after the outer budget completes.
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, true);
    await body.close().timeout(const Duration(seconds: 1));
  });

  testWidgets(
    'index downloads allow slow transfers beyond the old ten-second cap',
    (tester) async {
      final drive = DriveHttpFixture();
      final library = 'a' * 64;
      drive.files['index'] = Uint8List.fromList([1]);
      drive.metadata['index'] = {
        'id': 'index',
        'name': 'bk1-$library-${SyncMetadataIndex.fileName}',
        'version': '1',
        'appProperties': {'indexLibrary': library},
      };
      final client = MockClient((request) async {
        if (request.url.queryParameters['alt'] == 'media') {
          await Future<void>.delayed(const Duration(seconds: 11));
        }
        return drive.handle(request);
      });
      addTearDown(client.close);
      final transport = GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic-access',
        libraryId: library,
      );
      Uint8List? result;
      final read = transport.readIndex().then((bytes) => result = bytes);
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      await read;
      expect(result, [1]);
    },
  );

  for (final provider in ['drive', 'dropbox', 'webdav', 'nextcloud']) {
    test(
      '$provider index reuses metadata, observes old-client writes, and rebuilds',
      () async {
        final cipher = await SyncCipher.create('index-qa', Uint8List(32));
        addTearDown(cipher.dispose);
        final drive = DriveHttpFixture();
        final dav = WebDavServer();
        final dropbox = DropboxHttpFixture(
          accessToken: 'synthetic-access',
          pageSize: 1 << 30,
        );
        var commitReads = 0;
        final client = MockClient((request) async {
          if (provider == 'drive') {
            if (request.url.queryParameters['alt'] == 'media' &&
                (drive.metadata[request.url.pathSegments.last]?['name']
                            as String? ??
                        '')
                    .contains('-c-')) {
              commitReads++;
            }
            return drive.handle(request);
          }
          if (provider == 'dropbox') {
            if (request.url.path.endsWith('/download') &&
                (request.headers['dropbox-api-arg'] ?? '').contains('/c-')) {
              commitReads++;
            }
            return dropbox.handle(request);
          }
          if (request.method == 'GET' &&
              request.url.pathSegments.last.startsWith('c-')) {
            commitReads++;
          }
          return dav.handle(request);
        });
        addTearDown(client.close);
        SyncFileTransport transport() => switch (provider) {
          'drive' => GoogleDriveSyncTransport(
            httpClient: ProviderHttp(client),
            accessToken: () async => 'synthetic-access',
            libraryId: cipher.libraryId,
          ),
          'dropbox' => DropboxSyncTransport(
            httpClient: ProviderHttp(client),
            accessToken: () async => 'synthetic-access',
            libraryId: cipher.libraryId,
          ),
          'nextcloud' => NextcloudSyncTransport(
            httpClient: ProviderHttp(client),
            server: dav.root,
            username: 'qa',
            appPassword: () async => 'synthetic',
            libraryId: cipher.libraryId,
          ),
          _ => WebDavSyncTransport(
            httpClient: ProviderHttp(client),
            server: dav.root,
            username: 'qa',
            appPassword: () async => 'synthetic',
            libraryId: cipher.libraryId,
          ),
        };
        FileSyncAdapter adapter() => FileSyncAdapter(
          connectionId: provider,
          cipher: cipher,
          transport: transport(),
        );
        SyncRevision revision(String id) => SyncRevision(
          kind: SyncEntityKind.note,
          entityId: id,
          revisionId: 'revision-$id',
          modifiedAtMicros: 1,
          deleted: false,
          payloadObjectId: 'a' * 64,
        );

        Future<List<SyncRevision>> scan(FileSyncAdapter source) async {
          final revisions = <SyncRevision>[];
          String? cursor;
          while (true) {
            final page = await source.changes(cursor);
            revisions.addAll(page.revisions);
            if (!page.hasMore) return revisions;
            cursor = page.cursor;
          }
        }

        // Publish uses the unchanged immutable wire format, with no index.
        await adapter().publish(revision('one'));
        final first = adapter();
        expect((await scan(first)).single.entityId, 'one');
        await first.maintainIndex();
        if (provider == 'dropbox') expect(dropbox.indexWrites, 1);
        expect(commitReads, 1);
        final indexed = adapter();
        expect((await scan(indexed)).single.entityId, 'one');
        expect(
          commitReads,
          1,
          reason: 'Current versions reuse authenticated metadata',
        );
        await indexed.maintainIndex();

        await adapter().publish(revision('two'));
        final changed = adapter();
        expect(
          (await scan(changed)).map((r) => r.entityId),
          unorderedEquals(['one', 'two']),
        );
        expect(
          commitReads,
          2,
          reason: 'An old client can add notes without the index',
        );
        await changed
            .maintainIndex(); // Exercises replacement of an existing index.
        if (provider == 'dropbox') expect(dropbox.indexWrites, 2);
        expect((await scan(adapter())), hasLength(2));
        expect(commitReads, 2);

        final indexTransport = transport() as SyncIndexFileTransport;
        final bytes = await indexTransport.readIndex();
        expect(bytes, isNotNull);
        expect(
          jsonDecode(utf8.decode(bytes!))['payload'],
          contains('payloadObjectId'),
        );
        await indexTransport.writeIndex(Uint8List.fromList([123]));
        final repaired = adapter();
        expect((await scan(repaired)), hasLength(2));
        expect(
          commitReads,
          4,
          reason: 'A torn cache falls back to both original commits',
        );
        await repaired.maintainIndex();
        expect((await scan(adapter())), hasLength(2));
        expect(commitReads, 4);
        expect(
          () => SyncMetadataIndex(cipher, provider).load(bytes),
          returnsNormally,
        );
        // Only two real commits are listed, deliberately placed on opposite
        // sides of a full cache page. The intervening entries are stale cache
        // metadata, never inventory, so only the real notes may be restored.
        final inventory = <String, List<String>>{};
        final listingTransport = transport();
        String? cursor;
        while (true) {
          final page = await listingTransport.list(cursor);
          inventory.addAll(page.commitVersions);
          cursor = page.cursor;
          if (!page.hasMore) break;
        }
        final chain = SyncMetadataIndex(cipher, provider);
        void remember(SyncRevision value, List<String> versions) =>
            chain.remember(FileSyncAdapter.commitName(value), versions, value);
        final one = revision('one');
        final two = revision('two');
        remember(one, inventory[FileSyncAdapter.commitName(one)]!);
        for (var i = 0; i < SyncMetadataIndex.maxPageEntries - 1; i++) {
          remember(revision('stale-cache-$i'), ['unused']);
        }
        remember(two, inventory[FileSyncAdapter.commitName(two)]!);
        await chain.upload(
          (name, bytes) => indexTransport.writeIndex(bytes, name: name),
        );
        final head = await indexTransport.readIndex();
        expect(
          jsonDecode(jsonDecode(utf8.decode(head!))['payload'])['next'],
          isNotNull,
        );
        final before = commitReads;
        expect(
          (await scan(adapter())).map((r) => r.entityId),
          unorderedEquals(['one', 'two']),
        );
        expect(
          commitReads,
          before,
          reason: 'Both linked pages reuse authenticated metadata',
        );
        for (final rejected in [
          '../outside',
          'metadata-index-v1.json',
          'metadata-index-v2.json',
        ]) {
          await expectLater(
            indexTransport.readIndex(name: rejected),
            throwsFormatException,
          );
          await expectLater(
            indexTransport.writeIndex(Uint8List(0), name: rejected),
            throwsFormatException,
          );
        }
      },
    );
  }
}
