import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:better_keep/services/file_system_base.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  late _Files files;
  late bool current;
  final bytes = Uint8List.fromList([1, 2, 3]);
  final objectId = sha256.convert([4, 5, 6]).toString();
  Future<Uint8List> decode(Uint8List value) async {
    if (LocalDataEncryption.isBytesEncrypted(value)) {
      if (value.length == 4) throw const FormatException('Damaged file');
      return Uint8List.fromList(value.skip(4).map((byte) => byte ^ 7).toList());
    }
    return value;
  }

  SyncAttachmentStore store({
    String scope = 'account/library',
    bool protect = true,
    Future<Uint8List> Function(Uint8List)? encrypt,
  }) => SyncAttachmentStore(
    database: db,
    files: files,
    scope: scope,
    root: '/app/attachments',
    allowedSourceRoots: ['/app', '/cache'],
    isCurrent: () => current,
    normalizePath: (path) async => path,
    encryptionEnabled: () async => protect,
    encrypt:
        encrypt ??
        (value) async => protect
            ? Uint8List.fromList([
                69,
                78,
                67,
                82,
                ...value.map((byte) => byte ^ 7),
              ])
            : value,
    decrypt: decode,
  );
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await SyncAttachmentStore.createTable(db);
    files = _Files();
    current = true;
  });
  tearDown(() async => db.close());

  test('iOS emulator media materializes and verifies without doubling its scope', () async {
    const documents =
        '/var/mobile/Containers/Data/Application/current/Library/Application Support/firebase_emulator';
    const cache =
        '/var/mobile/Containers/Data/Application/current/Library/Caches/firebase_emulator';
    final writer = SyncAttachmentStore(
      database: db,
      files: files,
      scope: 'account/library',
      root: '$documents/external_sync_media/library',
      allowedSourceRoots: [documents, cache],
      isCurrent: () => current,
      encrypt: (value) async => value,
      decrypt: (value) async => value,
      encryptionEnabled: () async => false,
      normalizePath: (value) async => FileUtils.rebaseIosPath(
        value,
        documentDir: documents,
        cacheDir: cache,
      ),
    );
    for (final extension in ['.json', '.png', '.m4a']) {
      final mediaId = sha256.convert(extension.codeUnits).toString();
      final restored = await writer.materialize(
        'note',
        mediaId,
        extension,
        bytes,
      );
      expect(restored, startsWith('$documents/external_sync_media/library/'));
      expect(await writer.read(restored), bytes);
      expect(
        await writer.read(restored.replaceFirst('/current/', '/previous/')),
        bytes,
      );
      expect(
        await writer.materialize('note', mediaId, extension, bytes),
        restored,
      );
    }
    expect(files.writes, 3);
  });

  test(
    'encrypts once, persists reuse and isolates notes and accounts',
    () async {
      final writer = store();
      final results = await Future.wait([
        writer.materialize('note', objectId, '.png', bytes),
        writer.materialize('note', objectId, '.png', bytes),
      ]);
      expect(results[0], results[1]);
      expect(files.writes, 1);
      expect(files.values[results[0]], isNot(orderedEquals(bytes)));
      expect(await writer.read(results[0]), bytes);
      expect(
        await store().materialize('note', objectId, '.png', bytes),
        results[0],
      );
      expect(
        await writer.materialize('other-note', objectId, '.png', bytes),
        isNot(results[0]),
      );
      expect(
        await store(scope: 'other/library')
            .materialize('note', objectId, '.png', bytes),
        isNot(results[0]),
      );
    },
  );

  test('damaged or locally edited cached files are replaced without deleting old references', () async {
    final writer = store();
    final original = await writer.materialize('note', objectId, '.png', bytes);
    files.values[original] = Uint8List.fromList([69, 78, 67, 82]);
    final repaired = await writer.materialize('note', objectId, '.png', bytes);
    expect(repaired, isNot(original));
    expect(await writer.read(repaired), bytes);
    expect(files.values.containsKey(original), isTrue);
    files.values[repaired] = Uint8List.fromList([9]);
    final restored = await writer.materialize('note', objectId, '.png', bytes);
    expect(restored, isNot(repaired));
    expect(await writer.read(restored), bytes);
  });

  test('refuses plaintext fallback when local encryption is enabled', () async {
    await expectLater(
      store(encrypt: (value) async => value)
          .materialize('note', objectId, '.png', bytes),
      throwsFormatException,
    );
    expect(files.writes, 0);
    expect(await db.query('replica_attachment_cache'), isEmpty);
    final unprotected = store(protect: false);
    final path = await unprotected.materialize('note', objectId, '.png', bytes);
    expect(files.values[path], bytes);
    final protected = await store().materialize(
      'note',
      objectId,
      '.png',
      bytes,
    );
    expect(protected, isNot(path));
    expect(
      LocalDataEncryption.isBytesEncrypted(files.values[protected]!),
      isTrue,
    );
  });

  test(
    'rejects outside-app sources and unsafe extensions before writing',
    () async {
      files.values['/private/source'] = bytes;
      final writer = store();
      await expectLater(
        writer.read('/app/../private/source'),
        throwsFormatException,
      );
      expect(
        () => writer.materialize('note', objectId, '/../png', bytes),
        throwsFormatException,
      );
      expect(files.writes, 0);
      expect(files.reads, 0);
    },
  );

  test(
    'retirement during write removes its unindexed file and drains queued work',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      files.afterWrite = () async {
        started.complete();
        await release.future;
      };
      final writer = store();
      final writing = writer.materialize('note', objectId, '.png', bytes);
      final rejected = expectLater(
        writing,
        throwsA(isA<SyncReplicaCancelled>()),
      );
      await started.future;
      current = false;
      var drained = false;
      final draining = writer.waitForIdle().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      await rejected;
      await draining;
      expect(files.values, isEmpty);
      expect(await db.query('replica_attachment_cache'), isEmpty);
    },
  );

  test(
    'partial writes are cleaned and cannot poison a subsequent retry',
    () async {
      files.afterWrite = () async => throw StateError('Partial write');
      final writer = store();
      await expectLater(
        writer.materialize('note', objectId, '.png', bytes),
        throwsStateError,
      );
      expect(files.values, isEmpty);
      expect(await db.query('replica_attachment_cache'), isEmpty);
      files.afterWrite = null;
      final path = await writer.materialize('note', objectId, '.png', bytes);
      expect(await writer.read(path), bytes);
    },
  );
}

class _Files implements FileSystem {
  final values = <String, Uint8List>{};
  int writes = 0, reads = 0;
  Future<void> Function()? afterWrite;
  @override
  Future<void> createDirectory(String path) async {}
  @override
  Future<void> writeBytes(
    String path,
    Uint8List value, {
    bool append = false,
  }) async {
    writes++;
    values[path] = Uint8List.fromList(value);
    await afterWrite?.call();
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    reads++;
    return values[path] ?? (throw StateError('Missing file'));
  }

  @override
  Future<bool> exists(String path) async => values.containsKey(path);
  @override
  Future<bool> delete(String path) async => values.remove(path) != null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
