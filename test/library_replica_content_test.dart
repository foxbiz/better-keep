import 'support/storage_authorization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/legacy_sketch_migration_service.dart';
import 'package:better_keep/utils/encryption.dart' as pin;
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/note_sort_cloud_manifest.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:better_keep/services/external_sync/firebase_attachment_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:better_keep/services/file_system_io.dart';
import 'package:better_keep/services/external_sync/library_replica_content.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_object_cache.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late _Device a;
  late _Device b;
  setUp(() async {
    a = await _Device.create();
    b = await _Device.create();
  });
  tearDown(() async {
    await a.dispose();
    await b.dispose();
  });

  test(
    'local edit during incoming download wins and drains the inbox in one pass',
    () async {
      await a.note();
      final remote = _Remote('drive');
      await a.engine.sync(remote);
      await b.engine.sync(remote);
      await a.db.update('note', {'title': 'Incoming edit'}, where: 'id = 1');
      await a.engine.sync(remote);
      var edited = false;
      remote.beforeRead = () async {
        if (edited) return;
        edited = true;
        await b.db.update('note', {'title': 'Local winner'});
        // Keep conflict ordering deterministic even on a low-resolution clock.
        await b.db.update(SyncMutationJournal.table, {
          'modified_at_micros': remote.revisions.last.modifiedAtMicros + 1,
        });
      };
      await b.engine.sync(remote);
      expect(edited, isTrue);
      expect((await b.db.query('note')).single['title'], 'Local winner');
      expect(await b.store.inbox('drive'), isEmpty);
      expect(await b.store.pending('drive'), isEmpty);
      expect(remote.revisions, hasLength(3));
      remote.beforeRead = null;
      await a.engine.sync(remote);
      expect((await a.db.query('note')).single['title'], 'Local winner');
    },
  );

  test('uncaptured newer local note skips missing stale media beyond the capture page', () async {
    await a.note();
    for (var i = 0; i < 100; i++) {
      await a.db.insert('note', {
        'id': i + 2,
        'sync_id': 'bulk-$i',
        'title': 'Bulk',
        'content': '[]',
        'attachments': '[]',
        'created_at': '2026-01-01T00:00:00Z',
      });
    }
    final remote = _Remote('drive');
    remote.revisions.add(
      SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-id',
        revisionId: 'old',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: 'f' * 64,
      ),
    );
    remote.beforeRead = () async => fail('Must not download an older body');
    await a.engine.sync(remote);
    expect(await a.store.inbox('drive'), isEmpty);
    expect(await a.store.pending('drive'), isEmpty);
    expect(
      remote.revisions.where((r) => r.entityId == 'note-id'),
      hasLength(2),
    );
    expect((await a.db.query('note', where: 'id = 1')).single['title'], 'Note');
  });

  test('switching providers preserves independent progress for notes, media and deletions', () async {
    final media = await a.source('switch-image.png', [1, 2, 3, 4]);
    await a.note(
      attachments: [
        {
          'type': 'image',
          'data': {
            'src': media,
            'size': 4,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': 'first',
          },
        },
      ],
    );
    final row = (await a.db.query('note')).single;
    await a.db.insert('note', {...row, 'id': 2, 'sync_id': 'to-delete'});
    final drive = _Remote('google_drive:1');
    final dropbox = _Remote('dropbox:1');
    final scheduler = a.session.scheduler;
    a.session.setAutomatic(false);
    a.session.setForeground(true);
    Future<void> select(_Remote provider) async {
      scheduler.setAdapters([provider]);
      await scheduler.syncNow();
      expect(scheduler.progress[provider.connectionId]!.failure, isNull);
      expect(await a.store.pending(provider.connectionId), isEmpty);
    }

    await select(drive);
    final driveSuccess = await a.session.status.read(drive.connectionId);
    expect(driveSuccess, isNotNull);
    expect(await a.session.status.read(dropbox.connectionId), isNull);
    expect(await a.store.pending(dropbox.connectionId), hasLength(2));
    await select(dropbox);
    expect(await a.session.status.read(drive.connectionId), driveSuccess);
    expect(dropbox.revisions, hasLength(2));

    final replacement = await a.source('switch-replacement.png', [5, 6, 7]);
    final attachments = jsonDecode(row['attachments'] as String) as List;
    attachments.single['data']['src'] = replacement;
    attachments.single['data']['lastModified'] = 'second';
    await a.db.update('note', {
      'title': 'Changed while using Dropbox',
      'attachments': jsonEncode(attachments),
    }, where: 'id = 1');
    await a.db.delete('note', where: 'id = 2');
    final driveCursor = await a.store.cursor(drive.connectionId);
    await select(dropbox);
    expect(drive.revisions, hasLength(2));
    expect(await a.store.cursor(drive.connectionId), driveCursor);
    expect(await a.store.pending(drive.connectionId), hasLength(2));
    expect(await a.session.status.read(drive.connectionId), driveSuccess);

    await select(drive);
    expect(drive.revisions, hasLength(4));
    expect(
      drive.revisions.lastWhere((r) => r.entityId == 'to-delete').deleted,
      isTrue,
    );
    final published = drive.publishCalls;
    final writes = drive.objectWrites;
    await select(dropbox);
    await select(drive);
    expect(drive.publishCalls, published);
    expect(drive.objectWrites, writes);
    await b.engine.sync(drive);
    final restored = (await b.db.query('note')).single;
    expect(restored['title'], 'Changed while using Dropbox');
    final restoredMedia =
        (jsonDecode(
              restored['attachments'] as String,
            ) as List).single['data']['src']
            as String;
    expect(await File(restoredMedia).readAsBytes(), [5, 6, 7]);
  });

  test('clean login restores the library through saved grants without old files or cursors', () async {
    final provider = _DropboxServer();
    final provisioning = await SyncCipher.create(
      'synthetic-user',
      Uint8List(32),
    );
    final capability = SyncCipher.newCapability();
    final metadata = <String, Map<String, dynamic>>{
      for (final name in ['dropbox', 'google_drive'])
        name: {
          'provider': name,
          'connectionId': name,
          'libraryId': provisioning.libraryId,
          'accountLabel': 'Synthetic test account',
          'generation': 1,
          'credentialVersion': 2,
          'clientId': 'test-client',
          'encryptedCapability': await provisioning.encryptCapability(
            name,
            capability,
          ),
          'enabled': name == 'dropbox',
          'state': 'ready',
          'updatedAt': 1,
        },
    };
    final encryptedCredentials = await provisioning.encryptCredentials(
      provider: 'dropbox',
      generation: 1,
      clientId: 'test-client',
      credentials: {
        'type': 'oauth',
        'grant': 'test',
        'clientId': 'test-client',
        'accountId': 'test-account',
        'accessToken': 'synthetic-access',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
    );
    provisioning.dispose();
    final authorizedDevices = <String>[];
    StorageConnectionController connect(
      String deviceId,
      SyncCipher cipher,
      bool Function() current,
    ) => StorageConnectionController(
      cipher: cipher,
      deviceId: deviceId,
      isCurrent: current,
      metadata: Stream.value(metadata),
      readConnection: (name) async => metadata[name],
      launchAuthorization: (_) async =>
          throw StateError('Consent must survive login'),
      createClient: () => MockClient(provider.handle),
      authorization: FakeStorageAuthorization(),
      call: (name, data) async {
        expect(name, 'getEncryptedStorageCredentials');
        expect(data['provider'], 'dropbox');
        expect(data['capability'], capability);
        expect(data['deviceId'], deviceId);
        authorizedDevices.add(deviceId);
        return {
          'generation': 1,
          'revision': 1,
          'clientId': 'test-client',
          'encryptedCredentials': encryptedCredentials,
        };
      },
    );
    Future<void> sync(_Device device) async {
      await device.session.connections.waitForMetadata();
      device.session.setForeground(true);
      await device.session.scheduler.syncNow();
      final progress = device.session.scheduler.progress['dropbox:1']!;
      expect(progress.failure, isNull);
      expect(progress.blockedEntities, 0);
      expect(progress.lastSuccess, isNotNull);
    }

    final original = await _Device.create(
      createConnections: (cipher, current) =>
          connect('before-logout', cipher, current),
    );
    addTearDown(() async {
      if (original.db.isOpen) await original.dispose();
    });
    const password = '2468';
    final body = jsonEncode([
      {'insert': 'Recovered private note\n'},
    ]);
    final content = await pin.encrypt(body, password);
    final plaintextMedia = Uint8List.fromList([1, 2, 3, 4]);
    final media = await pin.encryptBytesWithPassword(plaintextMedia, password);
    final source = await original.source('protected-image.png', media);
    await original.note(
      locked: true,
      attachments: [
        {
          'id': 'image',
          'type': 'image',
          'data': {
            'src': source,
            'size': media.length,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': '',
          },
        },
      ],
    );
    await original.db.update('note', {'content': content}, where: 'id = 1');
    await original.db.insert('label', {
      'id': 1,
      'sync_id': 'label-id',
      'name': 'Work',
    });
    await original.db.insert('note_sort_context', {
      'context_key': 'main:grid',
      'sort_mode': 'custom',
      'revision': 'initial',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await original.db.insert('note_sort_position', {
      'context_key': 'main:grid',
      'note_sync_id': 'note-id',
      'position': 0,
    });
    await original.db.insert('note', {
      ...(await original.db.query('note')).single,
      'id': 2,
      'sync_id': 'deleted-id',
    });
    await sync(original);
    await original.db.delete('note', where: 'id = 2');
    await sync(original);
    final sourceVersion = await SyncMutationJournal.current(
      original.db,
      SyncEntityKind.note,
      'note-id',
    );
    final deletion = await SyncMutationJournal.current(
      original.db,
      SyncEntityKind.note,
      'deleted-id',
    );
    final oldAdapter = original.session.connections.adapters.single;
    final fileCount = provider.files.length;
    expect(await original.store.cursor('dropbox:1'), isNotNull);
    // Simulate completed logout cleanup, including media/cache.
    await original.dispose();
    expect(await File(source).exists(), isFalse);
    expect(original.db.isOpen, isFalse);
    await expectLater(oldAdapter.changes(null), throwsStateError);

    final restored = await _Device.create(
      createConnections: (cipher, current) =>
          connect('after-login', cipher, current),
    );
    addTearDown(restored.dispose);
    expect(await restored.db.query('note'), isEmpty);
    expect(await restored.store.cursor('dropbox:1'), isNull);
    await sync(restored);
    final note = (await restored.db.query('note')).single;
    expect(note['sync_id'], 'note-id');
    expect(note['locked'], 1);
    expect(note['content'], content);
    expect(await pin.decrypt(note['content'] as String, password), body);
    expect(jsonDecode(note['reminder'] as String)['revision'], 7);
    final path =
        jsonDecode(note['attachments'] as String)[0]['data']['src'] as String;
    expect(p.isWithin(restored.root.path, path), isTrue);
    expect(await File(path).readAsBytes(), media);
    expect(
      await pin.decryptBytesWithPassword(
        await File(path).readAsBytes(),
        password,
      ),
      plaintextMedia,
    );
    expect((await restored.db.query('label')).single['name'], 'Work');
    expect(
      (await restored.db.query('note_sort_position')).single['note_sync_id'],
      'note-id',
    );
    expect(
      (await SyncMutationJournal.current(
        restored.db,
        SyncEntityKind.note,
        'note-id',
      ))?.revisionId,
      sourceVersion?.revisionId,
    );
    expect(
      (await SyncMutationJournal.current(
        restored.db,
        SyncEntityKind.note,
        'deleted-id',
      ))?.revisionId,
      deletion?.revisionId,
    );
    expect(
      (await SyncMutationJournal.current(
        restored.db,
        SyncEntityKind.note,
        'deleted-id',
      ))?.deleted,
      isTrue,
    );
    expect(
      restored.session.connections.connections['google_drive']!.enabled,
      isFalse,
    );
    expect(restored.session.connections.adapters.map((a) => a.connectionId), [
      'dropbox:1',
    ]);
    expect(
      provider.files.length,
      fileCount,
    ); // Restoration does not create new revisions.
    expect(authorizedDevices.toSet(), {'before-logout', 'after-login'});

    final wrongKey = await _Device.create(
      masterKey: Uint8List.fromList(List.filled(32, 1)),
      createConnections: (cipher, current) =>
          connect('wrong-key', cipher, current),
    );
    addTearDown(wrongKey.dispose);
    await wrongKey.session.connections.waitForMetadata();
    expect(wrongKey.session.connections.needsKeyRecovery('dropbox'), isTrue);
    expect(wrongKey.session.connections.adapters, isEmpty);
    expect(authorizedDevices.toSet(), {'before-logout', 'after-login'});
  });

  test('ordering deletion crosses an external provider, Firebase and another provider without restamping', () async {
    await a.db.insert('note_sort_context', {
      'context_key': 'main:grid',
      'sort_mode': 'custom',
      'revision': 'initial',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    final drive = _Remote('drive');
    await a.engine.sync(drive);
    await b.engine.sync(drive);
    await a.db.delete(
      'note_sort_context',
      where: 'context_key = ?',
      whereArgs: ['main:grid'],
    );
    await a.engine.sync(drive);
    final deletion = drive.revisions.lastWhere(
      (r) => r.entityId == 'main:grid',
    );
    expect(deletion.deleted, isTrue);
    await b.engine.sync(drive);
    final firestore = OfflineFirestore();
    final sort = NoteSortService();
    final previousDb = AppState.get('db');
    final fresh = await _Device.create();
    try {
      AppState.db = b.db;
      await sort.init();
      NoteSortService.cloudRepositoryOverride =
          FirestoreNoteSortCloudRepository(
            firestore: firestore,
            userId: 'test-user',
            schemaVersion: NoteSortService.cloudSchemaVersion,
          );
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.canPushCloudOverride = true;
      await sort.flushCloudForTesting();
      final payload =
          firestore.documents['users/test-user/note_order_contexts/main:grid']!;
      final firebaseVersion = NoteSortCloudManifest.version(payload);
      expect(firebaseVersion.revisionId, deletion.revisionId);
      expect(firebaseVersion.modifiedAtMicros, deletion.modifiedAtMicros);
      expect(firebaseVersion.deleted, isTrue);
      await sort.dispose();
      NoteSortService.canReceiveCloudOverride = null;
      NoteSortService.canPushCloudOverride = null;
      AppState.db = fresh.db;
      await sort.init();
      NoteSortService.canReceiveCloudOverride = true;
      NoteSortService.canPushCloudOverride = true;
      expect(await sort.receiveRemoteContextForTesting('main:grid'), 'deleted');
      final dropbox = _Remote('dropbox');
      await fresh.engine.sync(dropbox);
      final forwarded = dropbox.revisions.singleWhere(
        (r) => r.entityId == 'main:grid',
      );
      expect(forwarded.sameContent(deletion), isTrue);
    } finally {
      await sort.dispose();
      NoteSortService.cloudRepositoryOverride = null;
      NoteSortService.canReceiveCloudOverride = null;
      NoteSortService.canPushCloudOverride = null;
      AppState.set('db', previousDb);
      await fresh.dispose();
    }
  });

  test(
    'Firebase-only media becomes self-contained and forwards without Firebase',
    () async {
      final firebase = _FirebaseSources();
      final sourceDevice = await _Device.create(firebase: firebase);
      addTearDown(sourceDevice.dispose);
      const url = 'gs://test-bucket/users/synthetic-user/notes/n/source.json';
      final strokes = Uint8List.fromList(
        utf8.encode('{"strokes":[],"bgColor":42}'),
      );
      firebase.sources[url] = await FileEncryption.encryptBytes(
        strokes,
        Uint8List(32),
      );
      await sourceDevice.note(
        attachments: [
          {
            'id': 'sketch-id',
            'type': 'sketch',
            'data': {
              'strokesFilePath': url,
              'strokesContentHash': sha256.convert(strokes).toString(),
            },
          },
        ],
      );
      final drive = _Remote('drive');
      await sourceDevice.engine.sync(drive);
      expect(sourceDevice.content.captureFailures, isEmpty);
      final revision = drive.revisions.single;
      final payload = utf8.decode(
        await sourceDevice.objects.decrypt(revision.payloadObjectId!),
      );
      expect(payload, isNot(contains('gs://')));
      expect(payload, isNot(contains('test-bucket')));
      firebase.sources.clear();
      await a.engine.sync(drive);
      final attachment = (jsonDecode(
        (await a.db.query('note')).single['attachments'] as String,
      ) as List).single;
      expect(
        await File(attachment['data']['strokesFilePath']).readAsBytes(),
        strokes,
      );
      final dropbox = _Remote('dropbox');
      await a.engine.sync(dropbox);
      expect(dropbox.revisions.single.revisionId, revision.revisionId);
      await b.engine.sync(dropbox);
      expect((await b.db.query('note')).single['sync_id'], 'note-id');
    },
  );

  test('missing mapped media publishes a complete note that restores without Firebase', () async {
    final firebase = _FirebaseSources();
    final sourceDevice = await _Device.create(firebase: firebase);
    addTearDown(sourceDevice.dispose);
    final bytes = Uint8List.fromList([69, 78, 67, 80, 1, 2, 3]);
    final local = await sourceDevice.source('missing.png', bytes);
    await File(local).delete();
    const url = 'gs://test-bucket/users/synthetic-user/notes/n/source.png';
    firebase.sources[url] = await FileEncryption.encryptBytes(
      bytes,
      Uint8List(32),
    );
    await sourceDevice.note(
      locked: true,
      attachments: [
        {
          'id': 'image-id',
          'type': 'image',
          'data': {
            'src': local,
            'size': 7,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': '',
          },
        },
      ],
    );
    await sourceDevice.db.insert('file_sync_track', {
      'note_id': 1,
      'local_path': local,
      'remote_path': url,
      'content_hash': FileSyncTrack.computeHash(bytes),
    });
    final remote = _Remote('drive');
    await sourceDevice.engine.sync(remote);
    expect(sourceDevice.content.captureFailures, isEmpty);
    expect(remote.revisions, hasLength(1));
    firebase.sources.clear();
    await a.engine.sync(remote);
    final incoming = jsonDecode(
      (await a.db.query('note')).single['attachments'] as String,
    );
    expect(await File(incoming[0]['data']['src']).readAsBytes(), bytes);
    expect(await File(local).exists(), isFalse);
  });

  test('overwritten Firebase sketch cannot be published under an older source hash', () async {
    final firebase = _FirebaseSources();
    final sourceDevice = await _Device.create(firebase: firebase);
    addTearDown(sourceDevice.dispose);
    const url = 'gs://test-bucket/users/synthetic-user/notes/n/source.json';
    final expected = Uint8List.fromList(utf8.encode('{"strokes":[]}'));
    firebase.sources[url] = Uint8List.fromList(
      utf8.encode('{"strokes":["changed"]}'),
    );
    await sourceDevice.note(
      attachments: [
        {
          'type': 'sketch',
          'data': {
            'strokesFilePath': url,
            'strokesContentHash': sha256.convert(expected).toString(),
          },
        },
      ],
    );
    final remote = _Remote('drive');
    await sourceDevice.engine.sync(remote);
    expect(remote.revisions, isEmpty);
    expect(sourceDevice.content.captureFailures, isNotEmpty);
    firebase.sources[url] = expected;
    await sourceDevice.engine.sync(remote);
    expect(remote.revisions, hasLength(1));
    expect(sourceDevice.content.captureFailures, isEmpty);
  });

  test('notes, opaque PIN media, labels, reminders and order sync and forward without restamping', () async {
    final image = await a.source('photo.png', [1, 2, 3]);
    final audio = await a.source('recording.m4a', [4, 5]);
    final sketch = await a.source(
      'drawing.json',
      utf8.encode('PIN-protected-sketch-source'),
    );
    await a.db.insert('label', {
      'id': 2,
      'sync_id': 'label-id',
      'name': 'Work',
    });
    await a.note(
      attachments: [
        {
          'id': 'image-id',
          'type': 'image',
          'data': {
            'src': image,
            'size': 3,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': 'source-time',
          },
        },
        {
          'id': 'audio-id',
          'type': 'audio',
          'data': {'src': audio, 'length': 5, 'title': 'Recording'},
        },
        {
          'id': 'sketch-id',
          'type': 'sketch',
          'data': {
            'strokesFilePath': sketch,
            'backgroundImage': image,
            'previewImage': '/must-not-read-preview.png',
            'aspectRatio': 1.0,
          },
        },
      ],
      locked: true,
    );
    await a.db.transaction((txn) async {
      await txn.insert('note_sort_context', {
        'context_key': 'main:grid',
        'sort_mode': 'custom',
        'revision': 'local-order',
        'updated_at': '2026-01-01T00:00:00Z',
        'dirty': 1,
      });
      await txn.insert('note_sort_position', {
        'context_key': 'main:grid',
        'note_sync_id': 'note-id',
        'position': 0,
      });
    });
    final drive = _Remote('drive');
    final dropbox = _Remote('dropbox');
    await a.engine.sync(drive);
    expect(a.content.captureFailures, isEmpty);
    final original = drive.revisions
        .where((r) => r.kind == SyncEntityKind.note)
        .single;
    expect(
      original.blobIds.length,
      3,
    ); // Shared background is encrypted only once.
    final payload = jsonDecode(
      utf8.decode(await a.objects.decrypt(original.payloadObjectId!)),
    );
    expect(jsonEncode(payload), isNot(contains(a.root.path)));
    expect(jsonEncode(payload), isNot(contains('must-not-read-preview')));
    await b.engine.sync(drive);
    final row = (await b.db.query('note')).single;
    final created = b.appliedChanges
        .where((change) => change.revision.kind == SyncEntityKind.note)
        .single;
    expect(created.event, 'created');
    expect(created.localId, row['id'].toString());
    expect(created.row!['title'], 'Note');
    expect(row['title'], 'Note');
    expect(row['content'], 'PIN-ciphertext');
    expect(row['locked'], 1);
    expect(row['plain_text'], '');
    expect(jsonDecode(row['reminder'] as String)['revision'], 7);
    expect((await b.db.query('label')).single['name'], 'Work');
    expect(
      (await b.db.query('note_sort_position')).single['note_sync_id'],
      'note-id',
    );
    final attachments = jsonDecode(row['attachments'] as String) as List;
    expect(await File(attachments[0]['data']['src']).readAsBytes(), [1, 2, 3]);
    expect(await File(attachments[1]['data']['src']).readAsBytes(), [4, 5]);
    expect(
      await File(attachments[2]['data']['strokesFilePath']).readAsString(),
      'PIN-protected-sketch-source',
    );
    expect(attachments[2]['data']['previewImage'], isNull);
    await b.engine.sync(dropbox);
    final forwarded = dropbox.revisions
        .where((r) => r.kind == SyncEntityKind.note)
        .single;
    expect(forwarded.encode(), original.encode());
    expect(await SyncMutationJournal.pending(b.db, b.store.scope), isEmpty);

    await a.db.delete('note', where: "sync_id = 'note-id'");
    await a.engine.sync(drive);
    await b.engine.sync(drive);
    await b.engine.sync(dropbox);
    expect(await b.db.query('note'), isEmpty);
    final tombstone = dropbox.revisions.lastWhere(
      (r) => r.kind == SyncEntityKind.note,
    );
    expect(tombstone.deleted, true);
    expect(tombstone.payloadObjectId, isNull);
    expect((await b.db.query('sync_track')).single['action'], 'delete');
    final removed = b.appliedChanges.lastWhere(
      (change) => change.revision.kind == SyncEntityKind.note,
    );
    expect(removed.event, 'deleted');
    expect(removed.row!['title'], 'Note');
  });

  test('edit committed while remote objects download wins without losing its outgoing work', () async {
    await a.note();
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    await b.engine.sync(remote);
    await a.db.update('note', {
      'title': 'Remote edit',
    }, where: "sync_id = 'note-id'");
    await a.engine.sync(remote);
    final incoming = remote.revisions.last;
    remote.beforeRead = () async {
      remote.beforeRead = null;
      // Give the fixture a deterministic clock ahead of the incoming revision.
      await b.db.update(SyncMutationJournal.table, {
        'modified_at_micros': incoming.modifiedAtMicros + 1000,
      }, where: "entity_id = 'note-id'");
      await b.db.update('note', {
        'title': 'Local concurrent edit',
      }, where: "sync_id = 'note-id'");
    };
    await b.engine.sync(remote);
    expect((await b.db.query('note')).single['title'], 'Local concurrent edit');
    expect(
      (await b.store.current(
        b.db,
        SyncEntityKind.note,
        'note-id',
      ))!.modifiedAtMicros,
      greaterThan(incoming.modifiedAtMicros),
    );
    await b.engine.sync(remote);
    expect(await b.store.inbox('drive'), isEmpty);
    await a.engine.sync(remote);
    expect((await a.db.query('note')).single['title'], 'Local concurrent edit');
  });

  test('missing media cannot publish partial notes and retries preserve the journal revision', () async {
    final missing = p.join(a.root.path, 'missing.png');
    await a.note(
      attachments: [
        {
          'type': 'image',
          'data': {
            'src': missing,
            'size': 2,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': '',
          },
        },
      ],
    );
    final version = (await SyncMutationJournal.current(
      a.db,
      SyncEntityKind.note,
      'note-id',
    ))!;
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    expect(remote.revisions, isEmpty);
    expect(a.content.captureFailures, isNotEmpty);
    expect(a.content.notesRequiringUnlock, 0);
    await File(missing).writeAsBytes([3, 4]);
    await a.engine.sync(remote);
    expect(remote.revisions.single.revisionId, version.revisionId);
    expect(a.content.captureFailures, isEmpty);
  });

  test('quiescent cache cleanup retains entity, inbox and provider acknowledgement objects', () async {
    final ids = <String>[];
    for (var i = 0; i < 4; i++) {
      ids.add(await a.objects.encrypt(Uint8List.fromList([i])));
    }
    for (var i = 0; i < 3; i++) {
      final table = [
        'replica_entities',
        'replica_inbox',
        'replica_acknowledgements',
      ][i];
      final revision = SyncRevision(
        kind: SyncEntityKind.note,
        entityId: 'note-$i',
        revisionId: 'revision-$i',
        modifiedAtMicros: 1,
        deleted: false,
        payloadObjectId: ids[i],
      );
      await a.db.insert(table, {
        'scope': a.store.scope,
        'kind': 'note',
        'entity_id': revision.entityId,
        'revision_id': revision.revisionId,
        'revision': revision.encode(),
        if (i > 0) 'connection_id': 'drive',
      });
    }
    expect(await a.objects.pruneUnreferenced(), 1);
    for (final id in ids.take(3)) {
      expect(await a.objects.read(id), isNotNull);
    }
    expect(await a.objects.read(ids.last), isNull);
    final webStyle = SyncObjectCache(
      database: a.db,
      files: const _ChildNameFileSystem(),
      root: p.join(a.root.path, 'external_sync'),
      scope: a.store.scope,
      cipher: a.cipher,
    );
    final extra = await a.objects.encrypt(Uint8List.fromList([9]));
    expect(await webStyle.pruneUnreferenced(), 1);
    expect(await a.objects.read(extra), isNull);
    expect(
      await a.db.query(
        'replica_object_sources',
        where: 'object_id = ?',
        whereArgs: [ids.last],
      ),
      isEmpty,
    );
  });

  test(
    'persistent media fingerprints reuse ciphertext across cache instances',
    () async {
      final bytes = Uint8List.fromList([8, 9]);
      final id = await a.objects.encrypt(bytes);
      final reopened = SyncObjectCache(
        database: a.db,
        files: const IoFileSystem(),
        root: p.join(a.root.path, 'external_sync'),
        scope: a.store.scope,
        cipher: a.cipher,
      );
      expect(await reopened.encrypt(bytes), id);
      expect(await reopened.decrypt(id), bytes);
      await reopened.write(id, (await a.objects.read(id))!);
      await expectLater(
        reopened.write(id, Uint8List.fromList([0])),
        throwsFormatException,
      );
    },
  );

  test('legacy inline sketches become portable source files without uploading previews', () async {
    await a.note(
      attachments: [
        {
          'type': 'sketch',
          'data': {
            'strokes': <String>[],
            'bgColor': 0xFF123456,
            'pagePattern': 'blank',
            'aspectRatio': 1.5,
            'previewImage': '/derived-preview.png',
          },
        },
      ],
    );
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    expect(a.content.captureFailures, isEmpty);
    await b.engine.sync(remote);
    final attachments = jsonDecode(
      (await b.db.query('note')).single['attachments'] as String,
    );
    final data = attachments[0]['data'];
    final source = jsonDecode(
      await File(data['strokesFilePath']).readAsString(),
    );
    expect(source['bgColor'], 0xFF123456);
    expect(source['strokes'], isEmpty);
    expect(data['previewImage'], isNull);
  });

  test('locked device-key sketch stays pending until PIN migration replaces the source', () async {
    final file = await a.source('protected.json', [69, 78, 67, 80, 1, 2, 3]);
    final sketch = <String, dynamic>{
      'strokesFilePath': file,
      'encrypted_metadata': 'device-key-only-ciphertext',
    };
    await a.note(
      locked: true,
      attachments: [
        {'id': 'sketch-id', 'type': 'sketch', 'data': sketch},
      ],
    );
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    expect(remote.revisions, isEmpty);
    expect(a.content.captureFailures, isNotEmpty);
    expect(a.content.notesRequiringUnlock, 1);
    // The existing unlock migration verifies the sources before replacing the
    // stored metadata with a PIN-protected file. Sync must retry that change.
    sketch.remove('encrypted_metadata');
    await a.db.update('note', {
      'attachments': jsonEncode([
        {'id': 'sketch-id', 'type': 'sketch', 'data': sketch},
      ]),
    }, where: 'id = 1');
    await a.engine.sync(remote);
    expect(a.content.captureFailures, isEmpty);
    expect(a.content.notesRequiringUnlock, 0);
    await b.engine.sync(remote);
    final incoming = jsonDecode(
      (await b.db.query('note')).single['attachments'] as String,
    )[0]['data'];
    expect(incoming, isNot(contains('encrypted_metadata')));
    expect(await File(incoming['strokesFilePath']).readAsBytes(), [
      69,
      78,
      67,
      80,
      1,
      2,
      3,
    ]);
  });

  test(
    'legacy PIN sketch retains its opaque strokes and drawing defaults',
    () async {
      final ciphertext = await pin.encrypt(jsonEncode([]), '2468');
      await a.note(
        locked: true,
        attachments: [
          {
            'id': 'sketch-id',
            'type': 'sketch',
            'data': {
              'encryptedStrokes': ciphertext,
              'bgColor': 0xFF123456,
              'pagePattern': 'grid',
            },
          },
        ],
      );
      final remote = _Remote('drive');
      await a.engine.sync(remote);
      await b.engine.sync(remote);
      final incoming = jsonDecode(
        (await b.db.query('note')).single['attachments'] as String,
      )[0]['data'];
      expect(incoming['encryptedStrokes'], ciphertext);
      expect(incoming['bgColor'], 0xFF123456);
      expect(incoming['pagePattern'], 'grid');
      // Loading and saving the note must retain defaults used by the oldest
      // ciphertext shape, whose decrypted body contains strokes only.
      final sketch = SketchData.fromJson(
        SketchData.fromJson(incoming).toJson(),
      );
      final drawing = await LegacyEncryptedSketchDecoder.decode(
        ciphertext: sketch.encryptedStrokes!,
        password: '2468',
        fallbackBackgroundColor: sketch.backgroundColor,
        fallbackPagePattern: sketch.pagePattern,
      );
      expect(drawing.backgroundColor.toARGB32(), 0xFF123456);
      expect(drawing.pagePattern, PagePattern.grid);
      expect(drawing.strokes, isEmpty);
    },
  );

  test('authenticated payloads cannot inject filesystem paths as attachment references', () async {
    await b.note();
    final payload = {
      'version': 1,
      'kind': 'note',
      'entityId': 'note-id',
      'data': {
        'title': 'Injected',
        'labels': '',
        'color': '',
        'locked': 0,
        'pinned': 0,
        'trashed': 0,
        'archived': 0,
        'read_only': 0,
        'completed': 0,
        'content': '',
        'attachments': [
          {
            'type': 'image',
            'data': {
              'src': '/arbitrary/path.png',
              'size': 1,
              'index': 0,
              'aspectRatio': '1:1',
              'lastModified': '',
            },
          },
        ],
      },
    };
    final id = await b.objects.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    final revision = SyncRevision(
      kind: SyncEntityKind.note,
      entityId: 'note-id',
      revisionId: 'bad-path',
      modifiedAtMicros: DateTime.now().microsecondsSinceEpoch,
      deleted: false,
      payloadObjectId: id,
    );
    await expectLater(b.content.prepare(revision), throwsFormatException);
    expect((await b.db.query('note')).single['title'], 'Note');
  });

  test('independent encryption of one source revision converges without upload loops', () async {
    final photoA = await a.source('photo.png', [1, 2, 3]);
    final photoB = await b.source('download.bin', [1, 2, 3]);
    Map<String, dynamic> photo(String path, String thumbnail) => {
      'id': 'photo-id',
      'type': 'image',
      'data': {
        'src': path,
        'size': 3,
        'index': 0,
        'aspectRatio': '1:1',
        'lastModified': '',
        'blurredThumbnail': thumbnail,
      },
    };
    await a.note(attachments: [photo(photoA, 'generated-a')]);
    await b.note(attachments: [photo(photoB, 'generated-b')]);
    final source = (await SyncMutationJournal.pending(
      a.db,
      a.store.scope,
    )).single;
    await b.db.transaction(
      (txn) => SyncMutationJournal.received(txn, source, '1'),
    );
    final drive = _Remote('drive');
    final dropbox = _Remote('dropbox');
    await a.engine.sync(drive);
    await b.engine.sync(dropbox);
    final first = drive.revisions.single;
    final second = dropbox.revisions.single;
    expect(first.payloadObjectId, isNot(second.payloadObjectId));
    expect(first.blobIds, isNot(second.blobIds));
    expect(first.contentFingerprint, second.contentFingerprint);
    expect(first.sameContent(second), isTrue);
    await a.engine.sync(dropbox);
    await b.engine.sync(drive);
    expect(await a.store.pending('dropbox'), isEmpty);
    expect(await b.store.pending('drive'), isEmpty);
    expect(drive.revisions.length, 1);
    expect(dropbox.revisions.length, 1);

    // Reusing an edit identity with a different body is still corruption.
    final changed = SyncRevision(
      kind: first.kind,
      entityId: first.entityId,
      revisionId: first.revisionId,
      modifiedAtMicros: first.modifiedAtMicros,
      deleted: false,
      payloadObjectId: first.payloadObjectId,
      blobIds: first.blobIds,
      contentFingerprint: '0' * 64,
    );
    await expectLater(
      a.db.transaction((txn) => a.store.accept(txn, changed)),
      throwsFormatException,
    );
  });

  test('authenticated payload cannot claim another body fingerprint', () async {
    await a.note();
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    final original = remote.revisions.single;
    final payload = jsonDecode(
      utf8.decode(await a.objects.decrypt(original.payloadObjectId!)),
    );
    payload['data']['title'] = 'Different content';
    final id = await a.objects.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    final altered = SyncRevision(
      kind: original.kind,
      entityId: original.entityId,
      revisionId: original.revisionId,
      modifiedAtMicros: original.modifiedAtMicros,
      deleted: false,
      payloadObjectId: id,
      contentFingerprint: original.contentFingerprint,
    );
    await expectLater(a.content.prepare(altered), throwsFormatException);
    expect((await a.db.query('note')).single['title'], 'Note');
  });

  test('newer live revisions can revive a tombstone and replace the pending Firebase deletion', () async {
    await a.note();
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    await b.engine.sync(remote);
    await a.db.delete('note');
    await a.engine.sync(remote);
    await b.engine.sync(remote);
    await a.note();
    await a.engine.sync(remote);
    await b.engine.sync(remote);
    expect((await b.db.query('note')).single['title'], 'Note');
    expect((await b.db.query('sync_track')).single['action'], 'upload');
  });

  test(
    'retiring the library drains a pending download before database cleanup',
    () async {
      await a.note();
      final remote = _Remote('drive');
      await a.engine.sync(remote);
      final started = Completer<void>(), release = Completer<void>();
      remote.beforeRead = () async {
        started.complete();
        await release.future;
      };
      final syncing = b.engine.sync(remote);
      final rejected = expectLater(
        syncing,
        throwsA(isA<SyncReplicaCancelled>()),
      );
      await started.future;
      var closed = false;
      final closing = b.session.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      await expectLater(
        b.content.read(remote.revisions.single.payloadObjectId!),
        throwsA(isA<SyncReplicaCancelled>()),
      );
      release.complete();
      await rejected;
      await closing;
      expect(closed, isTrue);
      expect(await b.db.query('note'), isEmpty);
      expect(await b.db.query('replica_attachment_cache'), isEmpty);
      expect(await b.db.query('replica_entities'), isEmpty);
    },
  );

  for (final blocked in [false, true]) {
    test(
      'manual sync drains 1005 notes with blocked media: $blocked',
      () async {
        await a.db.transaction((txn) async {
          for (var i = 0; i < 1005; i++) {
            await txn.insert('note', {
              'id': i + 1,
              'sync_id': 'bulk-$i',
              'title': 'Note $i',
              'content': '',
              'attachments': blocked && i == 0
                  ? jsonEncode([
                      {
                        'type': 'image',
                        'data': {'src': '/missing-photo.png'},
                      },
                    ])
                  : '[]',
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
            });
          }
        });
        final remote = _Remote('drive');
        final scheduler = a.session.scheduler;
        scheduler.setAutomatic(false);
        scheduler.setAdapters([remote]);
        scheduler.setForeground(true);
        await scheduler.syncNow();
        expect(remote.revisions, hasLength(blocked ? 1004 : 1005));
        expect(scheduler.progress['drive']!.pendingLocalChanges, blocked);
        expect(scheduler.progress['drive']!.blockedEntities, blocked ? 1 : 0);
        expect(
          scheduler.progress['drive']!.lastSuccess,
          blocked ? isNull : isNotNull,
        );
        final published = remote.revisions.length;
        a.session.persistedChanged();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await scheduler.syncNow();
        expect(
          remote.revisions.length,
          published,
          reason: 'unchanged notes are not republished',
        );
        scheduler.setForeground(false);
      },
    );
  }

  test(
    'remote journal notifications do not mark a clean replica dirty',
    () async {
      await a.note();
      final remote = _Remote('drive');
      await a.engine.sync(remote);
      final scheduler = b.session.scheduler;
      scheduler.setAutomatic(false);
      scheduler.setAdapters([remote]);
      scheduler.setForeground(true);
      await scheduler.syncNow();
      b.session.persistedChanged();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scheduler.progress['drive']!.pendingLocalChanges, false);
      await b.db.update('note', {'title': 'Actual local change'});
      b.session.persistedChanged();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scheduler.progress['drive']!.pendingLocalChanges, true);
      scheduler.setForeground(false);
    },
  );

  test('late capture failure cannot block a newer incoming note', () async {
    final firebase = _FirebaseSources();
    final device = await _Device.create(firebase: firebase);
    addTearDown(device.dispose);
    final started = Completer<void>();
    final release = Completer<void>();
    firebase.beforeDownload = () async {
      started.complete();
      await release.future;
    };
    await device.note(
      attachments: [
        {
          'type': 'audio',
          'data': {
            'src': 'gs://test-bucket/users/synthetic-user/notes/n/missing.mp3',
            'length': 1,
          },
        },
      ],
    );
    final capturing = device.content.captureLocalChanges();
    await started.future;
    await a.note();
    final previous = (await SyncMutationJournal.current(
      device.db,
      SyncEntityKind.note,
      'note-id',
    ))!;
    await a.db.update(SyncMutationJournal.table, {
      'modified_at_micros': previous.modifiedAtMicros + 1000,
    });
    final remote = _Remote('drive');
    await a.engine.sync(remote);
    final revision = remote.revisions.single;
    for (final entry in remote.objects.entries) {
      await device.content.cache(entry.key, entry.value);
    }
    // A second provider can finish applying a download while a new capture
    // retries this device's old, unavailable source.
    final prepared = await device.content.prepare(revision);
    await device.db.transaction((txn) async {
      await device.store.accept(txn, revision);
      await prepared.apply(txn);
    });
    await prepared.didCommit?.call();
    release.complete();
    await capturing;
    expect(device.content.captureFailures, isEmpty);
    await device.content.captureLocalChanges();
    expect(device.content.captureFailures, isEmpty);
    expect((await device.db.query('note')).single['attachments'], '[]');
  });

  test('a newer incoming note clears a failed capture for the replaced local source', () async {
    await b.note(
      attachments: [
        {
          'type': 'image',
          'data': {
            'src': p.join(b.root.path, 'missing.png'),
            'size': 2,
            'index': 0,
            'aspectRatio': '1:1',
            'lastModified': '',
          },
        },
      ],
    );
    final remote = _Remote('drive');
    await b.engine.sync(remote);
    expect(b.content.captureFailures, isNotEmpty);
    final local = (await SyncMutationJournal.current(
      b.db,
      SyncEntityKind.note,
      'note-id',
    ))!;
    await a.note();
    await a.db.update(SyncMutationJournal.table, {
      'modified_at_micros': local.modifiedAtMicros + 1000,
    }, where: "entity_id = 'note-id'");
    await a.engine.sync(remote);
    await b.engine.sync(remote);
    expect(b.content.captureFailures, isEmpty);
    expect((await b.db.query('note')).single['attachments'], '[]');
  });
}

class _FirebaseSources extends AttachmentStorageRepository {
  final sources = <String, Uint8List>{};
  Future<void> Function()? beforeDownload;
  @override
  StorageObjectLocator parse(String source) => StorageObjectLocator.parse(
    source,
    configuredBucket: 'test-bucket',
    emulatorMode: false,
  );
  @override
  Future<Uint8List?> download(String source) async {
    await beforeDownload?.call();
    return sources[source];
  }
}

class _Device {
  _Device(
    this.db,
    this.root,
    this.cipher,
    this.store,
    this.objects,
    this.content,
    this.engine,
    this.session,
    this.appliedChanges,
  );
  final Database db;
  final Directory root;
  final SyncCipher cipher;
  final SyncReplicaStore store;
  final SyncObjectCache objects;
  final LibraryReplicaContent content;
  final SyncReplicaEngine engine;
  final LibrarySyncSession session;
  final List<SyncAppliedChange> appliedChanges;
  static Future<_Device> create({
    AttachmentStorageRepository? firebase,
    Uint8List? masterKey,
    StorageConnectionController Function(SyncCipher, bool Function())?
    createConnections,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'betterkeep-replica-test-',
    );
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
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
    final key = masterKey ?? Uint8List(32);
    final cipher = await SyncCipher.create('synthetic-user', key);
    final changes = <SyncAppliedChange>[];
    final session = LibrarySyncSession(
      uid: 'synthetic-user',
      database: db,
      files: const IoFileSystem(),
      documentRoot: root.path,
      cacheRoot: p.join(root.path, 'cache'),
      cipher: cipher,
      foreground: false,
      createAttachmentReader: firebase == null
          ? null
          : (readLocal, current) => FirebaseAttachmentReader(
              uid: 'synthetic-user',
              database: db,
              storage: firebase,
              readLocal: readLocal,
              readKey: () => key,
              isCurrent: current,
            ).read,
      onApplied: (change) async {
        changes.add(change);
      },
      isCurrent: () => true,
      createConnections: (current) =>
          createConnections?.call(cipher, current) ??
          StorageConnectionController(
            cipher: cipher,
            deviceId: 'synthetic-device',
            isCurrent: current,
            call: (_, _) async => throw StateError('No real broker in tests'),
            readConnection: (_) async => null,
            metadata: const Stream.empty(),
            launchAuthorization: (_) async => false,
          ),
    );
    return _Device(
      db,
      root,
      cipher,
      session.engine.store,
      session.objects,
      session.content,
      session.engine,
      session,
      changes,
    );
  }

  Future<String> source(String name, List<int> bytes) async {
    final path = p.join(root.path, name);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  Future<void> note({
    List<Map<String, dynamic>> attachments = const [],
    bool locked = false,
  }) => db.insert('note', {
    'id': 1,
    'sync_id': 'note-id',
    'title': 'Note',
    'labels': 'Work',
    'locked': locked ? 1 : 0,
    'content': locked ? 'PIN-ciphertext' : '[{"insert":"Note body\\n"}]',
    'reminder': jsonEncode({
      'dateTime': '2030-01-02T03:04:05Z',
      'recurrenceAnchor': '2030-01-02T03:04:05Z',
      'repeat': 'Once',
      'isAllDay': false,
      'type': 'notification',
      'revision': 7,
    }),
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
    'attachments': jsonEncode(attachments),
  });
  Future<void> dispose() async {
    await session.close();
    await db.close();
    await root.delete(recursive: true);
  }
}

/// In-memory Dropbox API boundary: production controller, broker, transport,
/// encryption and library code run above it without real accounts or network.
class _DropboxServer {
  final files = <String, Uint8List>{};

  Future<http.Response> handle(http.Request request) async {
    expect(request.headers['authorization'], 'Bearer synthetic-access');
    expect(request.method, 'POST');
    final args = jsonDecode(
      request.headers['dropbox-api-arg'] ?? request.body,
    ) as Map<String, dynamic>;
    switch (request.url.path) {
      case '/2/files/create_folder_v2':
        return http.Response('{}', 200);
      case '/2/files/list_folder':
      case '/2/files/list_folder/continue':
        final offset = args['cursor'] == null
            ? 0
            : int.parse(args['cursor'] as String);
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
        expect(args['mode'], 'add');
        expect(args['strict_conflict'], isTrue);
        final path = args['path'] as String;
        if (files.containsKey(path)) {
          return http.Response('{"error_summary":"path/conflict/file"}', 409);
        }
        files[path] = Uint8List.fromList(request.bodyBytes);
        return http.Response('{}', 200);
      case '/2/files/download':
        final bytes = files[args['path']];
        expect(bytes, isNotNull);
        return http.Response.bytes(bytes!, 200);
      default:
        throw StateError(
          'Unexpected synthetic Dropbox route: ${request.url.path}',
        );
    }
  }
}

class _Remote implements SyncProviderAdapter {
  _Remote(this.connectionId);
  @override
  final String connectionId;
  final objects = <String, Uint8List>{};
  final revisions = <SyncRevision>[];
  int publishCalls = 0;
  int objectWrites = 0;
  Future<void> Function()? beforeRead;
  @override
  Future<SyncChangePage> changes(String? cursor) async => SyncChangePage(
    revisions: revisions.skip(int.parse(cursor ?? '0')).toList(),
    cursor: '${revisions.length}',
    hasMore: false,
  );
  @override
  Future<Uint8List> readObject(String id) async {
    await beforeRead?.call();
    return objects[id]!;
  }

  @override
  Future<void> putObject(String id, Uint8List bytes) async {
    objectWrites++;
    objects[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> publish(SyncRevision revision) async {
    publishCalls++;
    if (!revisions.any(
      (r) =>
          r.kind == revision.kind &&
          r.entityId == revision.entityId &&
          r.revisionId == revision.revisionId,
    )) {
      revisions.add(revision);
    }
  }
}

class _ChildNameFileSystem extends IoFileSystem {
  const _ChildNameFileSystem();
  @override
  Future<List<String>> list([String directory = '/']) async =>
      (await super.list(directory)).map(p.basename).toList();
}
