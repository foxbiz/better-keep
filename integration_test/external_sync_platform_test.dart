// Real platform SQLite/files/crypto, synthetic Dropbox HTTP boundary.
// The optional automatic matrix authenticates only with disposable emulators.
// Neither matrix touches a user's library/provider files.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/sketch_preview_generator.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/sync_change_signals.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:better_keep/utils/db_init.dart'
    if (dart.library.html) 'package:better_keep/utils/db_init_web.dart'
    if (dart.library.io) 'package:better_keep/utils/db_init_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const automatic = bool.fromEnvironment('AUTOMATIC_SYNC_EMULATOR_TEST');
  if (automatic) {
    testWidgets(
      'automatic replication through real Firebase emulator hints',
      _automaticMatrix,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
  testWidgets(
    'platform replica matrix: rich content, media, edits and recovery',
    (tester) async {
      initializeDb();
      final files = await fileSystem();
      final run = DateTime.now().microsecondsSinceEpoch;
      final root = p.join(await files.documentDir, 'sync-qa-$run');
      final server = _DropboxBoundary();
      final replicas = <_Replica>[];
      Future<_Replica> create(String name) async {
        final replica = await _Replica.create(
          files,
          p.join(root, name),
          server,
        );
        replicas.add(replica);
        return replica;
      }

      addTearDown(() async {
        for (final replica in replicas) {
          await replica.session.close();
          replica.client.close();
          await replica.db.close();
          await deleteDatabase(replica.db.path);
        }
        await _deleteTestFiles(files, root);
      });
      final a = await create('a');
      final b = await create('b');
      var revision = 0;
      String stamp() =>
          DateTime.utc(2030)
              .add(Duration(seconds: revision++))
              .toIso8601String();
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      final audio = Uint8List.fromList(List.generate(128, (i) => i));
      final sketch = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': [
              SketchStroke(
                points: '10,20,0.5;30,40,0.5;',
                color: Colors.indigo,
                size: 6,
              ).toString(),
            ],
            'bgColor': Colors.white.toARGB32(),
            'pagePattern': 'blank',
            'aspectRatio': 1.0,
          }),
        ),
      );
      final expected = {'image': image, 'audio': audio, 'sketch': sketch};
      final attachments = <Map<String, dynamic>>[];
      for (final entry in expected.entries) {
        final source = p.join(a.root, '${entry.key}.bin');
        await files.writeBytes(source, entry.value);
        attachments.add({
          'id': entry.key,
          'type': entry.key,
          'data': switch (entry.key) {
            'sketch' => {'strokesFilePath': source, 'aspectRatio': 1.0},
            'audio' => {'src': source, 'length': 128, 'title': 'QA recording'},
            _ => {
              'src': source,
              'size': entry.value.length,
              'index': 0,
              'aspectRatio': '1:1',
              'lastModified': '',
            },
          },
        });
      }
      String content(int version) => jsonEncode([
        {'insert': 'Sync QA $version\n'},
        {'insert': 'Complete task'},
        {
          'insert': '\n',
          'attributes': {'list': version.isEven ? 'unchecked' : 'checked'},
        },
        {
          'insert': {
            NoteTableData.type:
                NoteTableData(rows: 2, columns: 2, id: 'qa-table').withCell(
                  0,
                  1,
                  [
                    {'insert': 'Cell $version\n'},
                  ],
                ).toJson(),
          },
        },
        {'insert': '\n'},
      ]);
      await a.db.insert('note', {
        'id': 1,
        'sync_id': 'qa-note',
        'title': 'Synthetic QA',
        'content': content(0),
        'created_at': stamp(),
        'updated_at': stamp(),
        'attachments': jsonEncode(attachments),
      });
      await a.sync();
      await b.sync();
      expect((await b.row())['content'], content(0));
      await b.verifyMedia(expected);
      debugPrint(
        'SYNC QA PASS: initial text/table/task/image/audio/sketch transfer',
      );

      final received =
          jsonDecode((await b.row())['attachments'] as String) as List;
      final drawing = SketchData.fromJson(
        Map<String, dynamic>.from(received.last['data'] as Map),
      );
      expect(
        (await SketchStrokesFileService.hydrate(drawing)).hasStrokes,
        isTrue,
      );
      drawing.previewImage = p.join(b.root, 'preview.jpg');
      expect(
        await SketchPreviewGenerator.generatePreview(
          drawing,
          updateCache: false,
        ),
        isTrue,
      );
      final codec = await ui.instantiateImageCodec(
        await files.readBytes(drawing.previewImage!),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(1));
      expect(frame.image.height, greaterThan(1));
      frame.image.dispose();
      codec.dispose();
      debugPrint(
        'SYNC QA PASS: downloaded sketch renders a decodable local preview',
      );

      for (var edit = 1; edit <= 6; edit++) {
        final writer = edit.isOdd ? b : a;
        final reader = edit.isOdd ? a : b;
        await writer.db.update('note', {
          'content': content(edit),
          'updated_at': stamp(),
        }, where: "sync_id = 'qa-note'");
        await writer.sync();
        await reader.sync();
        expect((await reader.row())['content'], content(edit));
        await reader.verifyMedia(expected);
      }
      debugPrint(
        'SYNC QA PASS: six alternating-device edits retain tables/tasks/media',
      );

      final updated =
          jsonDecode((await b.row())['attachments'] as String) as List;
      final imagePath = updated.first['data']['src'] as String;
      final replacement = Uint8List.fromList([...image, 0]);
      await files.writeBytes(imagePath, replacement);
      updated.first['data']['size'] = replacement.length;
      updated.first['data']['lastModified'] = 'replacement';
      expected['image'] = replacement;
      await b.db.update('note', {
        'attachments': jsonEncode(updated),
        'updated_at': stamp(),
      }, where: "sync_id = 'qa-note'");
      await b.sync();
      await a.sync();
      await a.verifyMedia(expected);
      debugPrint('SYNC QA PASS: media replacement reaches the other replica');

      final restored = await create('clean-login');
      await restored.sync();
      expect((await restored.row())['content'], content(6));
      await restored.verifyMedia(expected);
      final fileCount = server.files.length;
      await a.sync();
      await b.sync();
      await restored.sync();
      expect(
        server.files.length,
        fileCount,
        reason: 'No echo uploads after convergence',
      );
      debugPrint(
        'SYNC QA PASS: empty replica restores all media without echo uploads',
      );

      await a.db.delete('note', where: "sync_id = 'qa-note'");
      await a.sync();
      await b.sync();
      await restored.sync();
      expect(await b.db.query('note'), isEmpty);
      expect(await restored.db.query('note'), isEmpty);
      debugPrint('SYNC QA PASS: deletion converges on both receivers');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'SYNC QA PASSED\nRich content · media · edits · restore · deletion',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
    skip: automatic,
  );
}

Future<void> _deleteTestFiles(FileSystem files, String directory) async {
  for (final entry in await files.list(directory)) {
    final path = p.isAbsolute(entry) ? entry : p.join(directory, entry);
    if (!p.isWithin(directory, path)) {
      throw StateError('Invalid test file path');
    }
    if (await files.isDirectory(path)) {
      await _deleteTestFiles(files, path);
    } else {
      await files.delete(path);
    }
  }
  // Some file-system implementations remove only files; empty directories
  // can remain, but no test media or encrypted payload is retained.
  await files.delete(directory);
}

Future<void> _automaticMatrix(WidgetTester tester) async {
  // Matches functions/test/support/seedAutomaticSync.cjs. All credentials and
  // encryption material here are public disposable fixtures, never app secrets.
  const uid = 'automatic-sync-qa';
  const options = FirebaseOptions(
    apiKey: 'fake-api-key',
    appId: '1:123:web:automatic-sync-qa',
    messagingSenderId: '123',
    projectId: 'demo-better-keep-signals',
  );
  final apps = <FirebaseApp>[];
  final replicas = <_Replica>[];
  initializeDb();
  final files = await fileSystem();
  final root = p.join(
    await files.documentDir,
    'automatic-qa-${DateTime.now().microsecondsSinceEpoch}',
  );
  final server = _DropboxBoundary();
  addTearDown(() async {
    for (final replica in replicas) {
      await replica.session.close();
      replica.client.close();
      await replica.db.close();
      await deleteDatabase(replica.db.path);
    }
    await _deleteTestFiles(files, root);
    for (final app in apps) {
      await FirebaseAuth.instanceFor(app: app).signOut();
      await FirebaseFirestore.instanceFor(app: app).terminate();
      await app.delete();
    }
  });
  Future<_Replica> device(String id) async {
    final app = await Firebase.initializeApp(
      name: 'automatic-$id',
      options: options,
    );
    apps.add(app);
    final auth = FirebaseAuth.instanceFor(app: app);
    await auth.useAuthEmulator('127.0.0.1', 39099);
    final db = FirebaseFirestore.instanceFor(app: app);
    db.useFirestoreEmulator('127.0.0.1', 38183, automaticHostMapping: false);
    db.settings = const Settings(persistenceEnabled: false);
    final signedIn = await auth.signInWithEmailAndPassword(
      email: 'automatic-sync-qa@example.test',
      password: 'Disposable-QA-Only-123!',
    );
    expect(signedIn.user!.uid, uid);
    expect((await signedIn.user!.getIdTokenResult()).claims!['plan'], 'lite');
    final replica = await _Replica.create(
      files,
      p.join(root, id),
      server,
      uid: uid,
      firestore: db,
      deviceId: id,
    );
    replicas.add(replica);
    await replica.session.scheduler.waitForIdle();
    return replica;
  }

  Future<void> until(Future<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 50));
    while (!await ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'Automatic sync timed out: ${replicas.map((r) => r.session.scheduler.progress)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<bool> hasTitle(_Replica device, String title) async {
    final rows = await device.db.query('note');
    return rows.length == 1 && rows.single['title'] == title;
  }

  final a = await device('device-a');
  final b = await device('device-b');
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  );
  final imagePath = p.join(a.root, 'image.png');
  await files.writeBytes(imagePath, image);
  final content = jsonEncode([
    {'insert': 'Automatic fixture\n'},
    {'insert': 'Task'},
    {
      'insert': '\n',
      'attributes': {'list': 'checked'},
    },
    {
      'insert': {
        NoteTableData.type:
            NoteTableData(rows: 2, columns: 2, id: 'automatic-table').withCell(
              0,
              1,
              [
                {'insert': 'Synced cell\n'},
              ],
            ).toJson(),
      },
    },
    {'insert': '\n'},
  ]);
  await a.db.insert('note', {
    'id': 1,
    'sync_id': 'automatic-note',
    'title': 'First automatic save',
    'content': content,
    'created_at': '2030-01-01T00:00:00.000Z',
    'updated_at': '2030-01-01T00:00:01.000Z',
    'attachments': jsonEncode([
      {
        'id': 'image',
        'type': 'image',
        'data': {
          'src': imagePath,
          'size': image.length,
          'index': 0,
          'aspectRatio': '1:1',
          'lastModified': '',
        },
      },
    ]),
  });
  a.session.localChanged();
  await until(() => hasTitle(b, 'First automatic save'));
  expect((await b.row())['content'], content);
  await b.verifyMedia({'image': image});
  debugPrint(
    'AUTOMATIC QA PASS: save → encrypted provider commit → Firestore hint → second replica, with table/task/image',
  );

  final received = jsonDecode((await b.row())['attachments'] as String) as List;
  final replacement = Uint8List.fromList([...image, 0]);
  await files.writeBytes(received.single['data']['src'] as String, replacement);
  received.single['data']['size'] = replacement.length;
  received.single['data']['lastModified'] = 'replacement';
  await b.db.update('note', {
    'title': 'Edited on second device',
    'updated_at': '2030-01-01T00:00:02.000Z',
    'attachments': jsonEncode(received),
  }, where: "sync_id = 'automatic-note'");
  b.session.localChanged();
  await until(() => hasTitle(a, 'Edited on second device'));
  await a.verifyMedia({'image': replacement});
  debugPrint(
    'AUTOMATIC QA PASS: reverse edit and media replacement without manual sync',
  );

  b.session.setForeground(false);
  await a.db.update('note', {
    'title': 'While receiver sleeps',
    'updated_at': '2030-01-01T00:00:03.000Z',
  }, where: "sync_id = 'automatic-note'");
  a.session.localChanged();
  final signalRef = FirebaseFirestore.instanceFor(app: apps.first)
      .doc('users/$uid/storage_sync_signals/dropbox');
  await until(
    () async =>
        (await signalRef.get(const GetOptions(source: Source.server)))
            .data()?['deviceId'] ==
        'device-a',
  );
  expect(await hasTitle(b, 'Edited on second device'), isTrue);
  b.session.setForeground(true);
  await until(() => hasTitle(b, 'While receiver sleeps'));
  await a.session.scheduler.waitForIdle();
  await b.session.scheduler.waitForIdle();
  // Drain the apply debounce before measuring a full former polling interval.
  await Future<void>.delayed(const Duration(seconds: 3));
  final requests = server.requests;
  final signalToken = (await signalRef.get(
    const GetOptions(source: Source.server),
  )).data()!['token'];
  await Future<void>.delayed(const Duration(seconds: 35));
  expect(
    server.requests,
    requests,
    reason: 'Idle clients must not poll providers',
  );
  expect(
    (await signalRef.get(const GetOptions(source: Source.server)))
        .data()!['token'],
    signalToken,
  );
  debugPrint(
    'AUTOMATIC QA PASS: background/resume catches up, no idle polling or notification echo',
  );

  a.session.setAutomatic(false);
  b.session.setAutomatic(false);
  await a.db.update('note', {
    'title': 'Manual only',
    'updated_at': '2030-01-01T00:00:04.000Z',
  }, where: "sync_id = 'automatic-note'");
  a.session.localChanged();
  await Future<void>.delayed(const Duration(seconds: 3));
  expect(await hasTitle(b, 'While receiver sleeps'), isTrue);
  expect(server.requests, requests);
  await a.session.scheduler.syncNow();
  await b.session.scheduler.syncNow();
  expect(await hasTitle(b, 'Manual only'), isTrue);
  expect(
    (await signalRef.get(const GetOptions(source: Source.server)))
        .data()!['token'],
    signalToken,
  );
  debugPrint(
    'AUTOMATIC QA PASS: disabling automatic access stops triggers but manual sync still transfers notes',
  );
}

class _ReadyConnection extends ChangeNotifier
    implements StorageConnectionController {
  _ReadyConnection(StorageConnection connection, SyncProviderAdapter adapter)
    : connections = {connection.provider: connection},
      adapters = [adapter];
  @override
  final Map<String, StorageConnection> connections;
  @override
  final List<SyncProviderAdapter> adapters;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Replica {
  _Replica(
    this.db,
    this.root,
    this.files,
    this.session,
    this.adapter,
    this.client,
  );
  final Database db;
  final String root;
  final FileSystem files;
  final LibrarySyncSession session;
  final FileSyncAdapter adapter;
  final http.Client client;
  static Future<_Replica> create(
    FileSystem files,
    String root,
    _DropboxBoundary server, {
    String uid = 'isolated-platform-qa',
    FirebaseFirestore? firestore,
    String deviceId = 'synthetic-device',
  }) async {
    await files.createDirectory(root);
    final db = await openDatabase(p.join(root, 'qa.sqlite'));
    await Note.createTable(db);
    await Label.createTable(db);
    await NoteSyncTrack.createTable(db);
    await FileSyncTrack.createTable(db);
    await LabelSyncTrack.createTable(db);
    await NoteSortService.createTable(db);
    await SyncReplicaStore.createTables(db);
    await SyncAttachmentStore.createTable(db);
    await SyncStatusStore.createTable(db);
    await SyncMutationJournal.install(db);
    final cipher = await SyncCipher.create(uid, Uint8List(32));
    final client = MockClient(server.handle);
    final connection = StorageConnection(
      provider: 'dropbox',
      libraryId: cipher.libraryId,
      accountLabel: '',
      encryptedCapability: '',
      generation: 1,
      enabled: true,
      state: 'ready',
    );
    final adapter = FileSyncAdapter(
      connectionId: firestore == null ? 'dropbox-qa' : connection.replicaId,
      cipher: cipher,
      transport: DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic',
        libraryId: cipher.libraryId,
      ),
    );
    final session = LibrarySyncSession(
      uid: uid,
      database: db,
      files: files,
      documentRoot: root,
      cacheRoot: p.join(root, 'cache'),
      cipher: cipher,
      foreground: firestore != null,
      isCurrent: () => true,
      createSignals: firestore == null
          ? null
          : (store, changed) => SyncChangeSignals.firebase(
              uid: uid,
              deviceId: deviceId,
              store: store,
              isCurrent: () => true,
              firestore: firestore,
              onRemoteChange: changed,
            ),
      createConnections: (current) => firestore != null
          ? _ReadyConnection(connection, adapter)
          : StorageConnectionController(
              cipher: cipher,
              deviceId: root,
              isCurrent: current,
              call: (_, _) async =>
                  throw StateError('No Firebase calls allowed'),
              readConnection: (_) async => null,
              metadata: const Stream.empty(),
              launchAuthorization: (_) async => false,
            ),
    );
    return _Replica(db, root, files, session, adapter, client);
  }

  Future<void> sync() async {
    await session.engine.sync(adapter);
    expect(session.content.captureFailures, isEmpty);
  }

  Future<Map<String, Object?>> row() async => (await db.query('note')).single;
  Future<void> verifyMedia(Map<String, Uint8List> expected) async {
    final attachments =
        jsonDecode((await row())['attachments'] as String) as List;
    expect(attachments.length, expected.length);
    for (final attachment in attachments) {
      final data = attachment['data'] as Map;
      final source = (data['src'] ?? data['strokesFilePath']) as String;
      expect(
        await session.attachments.read(source),
        expected[attachment['id']],
      );
      expect(source, startsWith(root));
    }
  }
}

class _DropboxBoundary {
  final files = <String, Uint8List>{};
  int requests = 0;
  Future<http.Response> handle(http.Request request) async {
    requests++;
    expect(request.headers['authorization'], 'Bearer synthetic');
    final args =
        jsonDecode(request.headers['dropbox-api-arg'] ?? request.body) as Map;
    switch (request.url.path) {
      case '/2/files/create_folder_v2':
        return http.Response('{}', 200);
      case '/2/files/list_folder':
      case '/2/files/list_folder/continue':
        final offset = int.parse(args['cursor'] as String? ?? '0');
        return http.Response(
          jsonEncode({
            'entries': files.keys
                .skip(offset)
                .map((path) => {'.tag': 'file', 'name': p.basename(path)})
                .toList(),
            'cursor': '${files.length}',
            'has_more': false,
          }),
          200,
        );
      case '/2/files/upload':
        final path = args['path'] as String;
        if (files.containsKey(path)) {
          return http.Response('{"error_summary":"path/conflict/file"}', 409);
        }
        files[path] = Uint8List.fromList(request.bodyBytes);
        return http.Response('{}', 200);
      case '/2/files/download':
        return http.Response.bytes(files[args['path']]!, 200);
      default:
        throw StateError('Unexpected Dropbox route ${request.url.path}');
    }
  }
}
