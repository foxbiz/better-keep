@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:better_keep/services/cloud_session_recovery.dart';

import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';

import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_object_cache.dart';
import 'package:better_keep/services/file_system_base.dart';
import 'package:better_keep/services/scoped_file_system.dart';
import 'package:better_keep/services/web_file_system.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  test('cold OPFS cache uses metadata through the scoped filesystem', () async {
    final cipher = await SyncCipher.create(
      'synthetic-opfs-review',
      Uint8List(32),
    );
    addTearDown(cipher.dispose);
    final backend = await WebFileSystem.instance();
    expect(backend.backendType, 'OPFS');
    final files = _CountingScope(
      backend,
      directoryName: 'size-qa-${DateTime.now().microsecondsSinceEpoch}',
    );
    final root = await files.cacheDir;
    addTearDown(() => files.deleteTrees([root]));
    SyncObjectCache open() => SyncObjectCache(
      database: _UnusedDatabase(),
      files: files,
      root: root,
      scope: 'opfs-review',
      cipher: cipher,
    );
    final cache = open();
    final small = Uint8List.fromList([1, 2, 3]);
    final large = Uint8List(1024 * 1024 + 1);
    final smallId = sha256.convert(small).toString();
    final largeId = sha256.convert(large).toString();
    await cache.write(smallId, small);
    await cache.write(largeId, large);
    final before = files.reads;
    final cold = open();
    expect(await cold.readSmall(largeId, maxBytes: 1024 * 1024), null);
    expect(files.reads, before);
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), small);
    expect(files.reads, before + 1);
    final metadataCalls = files.metadataCalls;
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), small);
    expect(files.metadataCalls, metadataCalls);
    expect(await files.metadataLength('$root/missing'), null);
    final entries = await files.listRecursive(root);
    final sizes = {
      for (final entry in entries.where((entry) => entry['type'] == 'file'))
        (entry['path'] as String).split('/').last: entry['size'],
    };
    expect(sizes, {smallId: small.length, largeId: large.length});
  });

  test('web size probes never read unknown files and warm small reads verify content', () async {
    final cipher = await SyncCipher.create('synthetic-review', Uint8List(32));
    addTearDown(cipher.dispose);
    final files = _Files();
    SyncObjectCache open() => SyncObjectCache(
      database: _UnusedDatabase(),
      files: ScopedFileSystem(files, directoryName: 'synthetic-scope'),
      root: '/synthetic-cache',
      scope: 'review',
      cipher: cipher,
    );
    final cache = open();
    final small = Uint8List.fromList([1, 2, 3]);
    final smallId = sha256.convert(small).toString();
    final large = Uint8List(1024 * 1024 + 1);
    final largeId = sha256.convert(large).toString();
    await cache.write(smallId, small);
    await cache.write(largeId, large);
    final before = files.reads;
    expect(await cache.readSmall(largeId, maxBytes: 1024 * 1024), null);
    expect(files.reads, before);
    expect(await cache.readSmall(smallId, maxBytes: 1024 * 1024), small);
    final cold = open();
    final warmReads = files.reads;
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), null);
    expect(files.reads, warmReads);
    expect(await cold.read(smallId), small);
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), small);
    final path = files.data.keys.singleWhere((path) => path.endsWith(smallId));
    files.data[path] = Uint8List.fromList([9, 9, 9]);
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), null);
    expect(files.data.containsKey(path), false);
    await cold.write(smallId, small);
    var existenceChecks = 0;
    files.beforeExists = (_) => existenceChecks++;
    files.beforeRead = (_) => throw StateError('programming error');
    await expectLater(
      cold.readSmall(smallId, maxBytes: 1024 * 1024),
      throwsStateError,
    );
    expect(existenceChecks, 1); // Errors must bypass the absence fallback.

    existenceChecks = 0;
    files.beforeRead = (_) => throw const CloudOperationCancelled();
    await expectLater(
      cold.read(smallId),
      throwsA(isA<CloudOperationCancelled>()),
    );
    expect(existenceChecks, 1); // Cancellation must not be treated as a miss.

    final original = Exception('original read failure');
    final originalStack = StackTrace.fromString('original-cache-read-stack');
    existenceChecks = 0;
    files.beforeRead = (_) =>
        Error.throwWithStackTrace(original, originalStack);
    files.beforeExists = (_) {
      if (++existenceChecks > 1) throw Exception('existence probe failure');
    };
    try {
      await cold.readSmall(smallId, maxBytes: 1024 * 1024);
      fail('Expected the original read failure');
    } catch (error, stack) {
      expect(
        error,
        isA<SyncProviderFailure>().having(
          (error) => error.kind,
          'kind',
          SyncProviderFailureKind.localStorage,
        ),
      );
      expect(stack.toString(), contains('original-cache-read-stack'));
    }
    expect(existenceChecks, 2);
    files.beforeExists = null;
    files.beforeRead = (path) {
      files.data.remove(path);
      throw Exception('removed between existence check and read');
    };
    expect(await cold.readSmall(smallId, maxBytes: 1024 * 1024), null);
  });
}

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Files implements FileSystem {
  final data = <String, Uint8List>{};
  void Function(String)? beforeRead;
  void Function(String)? beforeExists;
  int reads = 0;
  @override
  Future<int?> length(String path) async =>
      throw StateError('Web length must not be used as a bounded size probe');
  @override
  Future<bool> exists(String path) async {
    beforeExists?.call(path);
    return data.containsKey(path);
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    reads++;
    beforeRead?.call(path);
    return data[path]!;
  }

  @override
  Future<void> writeBytes(
    String path,
    Uint8List bytes, {
    bool append = false,
  }) async {
    data[path] = bytes;
  }

  @override
  Future<void> createDirectory(String path) async {}
  @override
  Future<bool> delete(String path) async => data.remove(path) != null;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _CountingScope extends ScopedFileSystem {
  _CountingScope(super.delegate, {required super.directoryName});
  int reads = 0;
  int metadataCalls = 0;

  @override
  Future<int?> metadataLength(String path) async {
    metadataCalls++;
    return super.metadataLength(path);
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    reads++;
    return super.readBytes(path);
  }
}
