import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/remote_document_revision.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote sync cache completion', () {
    test('an interrupted page cannot become commit-ready', () async {
      final fileSystem = _MemoryFileSystem();
      final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
      await cache.init();
      await cache.startNewSync(_cursor);
      await cache.addPage(_page(hasMore: true));

      await cache.markCompleted('note-1');

      expect(cache.metadata?.allPagesFetched, isFalse);
      expect(cache.metadata?.syncComplete, isFalse);
      expect(cache.metadata?.isCommitReady, isFalse);
      expect(
        classifyRemoteSyncResume(
          metadata: cache.metadata,
          hasRemainingEntries: cache.hasPendingSyncs,
        ),
        RemoteSyncResumeDisposition.restartIncomplete,
      );
    });

    test('empty fetch completes only after pagination finishes', () async {
      final fileSystem = _MemoryFileSystem();
      final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
      await cache.init();
      await cache.startNewSync(_cursor);

      expect(cache.metadata?.isCommitReady, isFalse);

      await cache.markAllPagesFetched();

      expect(cache.metadata?.allPagesFetched, isTrue);
      expect(cache.metadata?.syncComplete, isTrue);
      expect(cache.metadata?.isCommitReady, isTrue);
    });

    test(
      'exact-sized final page needs an explicit fetch-complete marker',
      () async {
        final fileSystem = _MemoryFileSystem();
        final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
        await cache.init();
        await cache.startNewSync(_cursor);
        await cache.addPage(_page(hasMore: true));
        await cache.markCompleted('note-1');

        expect(cache.metadata?.isCommitReady, isFalse);

        await cache.markAllPagesFetched();

        expect(cache.metadata?.isCommitReady, isTrue);
      },
    );

    test('failed entries keep a finished fetch non-commit-ready', () async {
      final fileSystem = _MemoryFileSystem();
      final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
      await cache.init();
      await cache.startNewSync(_cursor);
      await cache.addPage(_page(hasMore: false));
      await cache.markAllPagesFetched();
      await cache.markFailed('note-1', 'injected failure');

      expect(cache.hasPendingSyncs, isTrue);
      expect(cache.metadata?.syncComplete, isFalse);
      expect(
        classifyRemoteSyncResume(
          metadata: cache.metadata,
          hasRemainingEntries: cache.hasPendingSyncs,
        ),
        RemoteSyncResumeDisposition.retainPending,
      );
    });

    test('completion cannot remove a newer in-progress revision', () async {
      final fileSystem = _MemoryFileSystem();
      final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
      await cache.init();
      await cache.startNewSync(_cursor);
      await cache.addPage(_page(hasMore: false));
      await cache.markAllPagesFetched();
      final original = cache.getSync('note-1')!;
      final originalRevision = remoteDocumentRevision(
        original.remoteData,
        original.remoteDocId,
      );
      await cache.updateSync(
        'note-1',
        original.copyWith(status: PendingRemoteSyncStatus.inProgress),
      );
      await cache.updateRemoteData('note-1', {
        'local_id': 1,
        'updated_at': '2026-07-29T00:01:00.000Z',
      });

      final removed = await cache.completeIfCurrentRevision(
        'note-1',
        originalRevision,
      );

      expect(removed, isFalse);
      expect(cache.hasPendingSyncs, isTrue);
      expect(cache.metadata?.isCommitReady, isFalse);
      expect(
        cache.getSync('note-1')!.remoteData['updated_at'],
        '2026-07-29T00:01:00.000Z',
      );
      expect(cache.getSync('note-1')!.status, PendingRemoteSyncStatus.pending);
    });

    test(
      'completion removes the revision that was actually processed',
      () async {
        final fileSystem = _MemoryFileSystem();
        final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);
        await cache.init();
        await cache.startNewSync(_cursor);
        await cache.addPage(_page(hasMore: false));
        await cache.markAllPagesFetched();
        final pending = cache.getSync('note-1')!;

        final removed = await cache.completeIfCurrentRevision(
          pending.remoteDocId,
          remoteDocumentRevision(pending.remoteData, pending.remoteDocId),
        );

        expect(removed, isTrue);
        expect(cache.hasPendingSyncs, isFalse);
        expect(cache.metadata?.isCommitReady, isTrue);
      },
    );

    test(
      'reload repairs contradictory completion and retries in-progress work',
      () async {
        final fileSystem = _MemoryFileSystem();
        const cacheDirectory = '/cache/remote_sync_cache';
        final metadata = RemoteSyncCacheMetadata(
          totalPages: 1,
          lastCursor: _cursor,
          allPagesFetched: false,
          syncComplete: true,
        );
        final interruptedPage = _page(
          hasMore: true,
          status: PendingRemoteSyncStatus.inProgress,
        );
        fileSystem.seed(
          path.join(cacheDirectory, 'metadata.json'),
          utf8.encode(jsonEncode(metadata.toJson())),
        );
        fileSystem.seed(
          path.join(cacheDirectory, 'page_0.json'),
          utf8.encode(jsonEncode(interruptedPage.toJson())),
        );
        final cache = RemoteSyncCacheService.forTesting(() async => fileSystem);

        await cache.init();

        expect(cache.metadata?.syncComplete, isFalse);
        expect(cache.metadata?.isCommitReady, isFalse);
        expect(cache.hasPendingSyncs, isTrue);
        expect(
          cache.getPendingSyncs().single.status,
          PendingRemoteSyncStatus.pending,
        );
      },
    );
  });

  group('remote sync resume classification', () {
    test('commits only a complete current-schema cache', () {
      final metadata = RemoteSyncCacheMetadata(
        allPagesFetched: true,
        syncComplete: true,
      );

      expect(
        classifyRemoteSyncResume(
          metadata: metadata,
          hasRemainingEntries: false,
        ),
        RemoteSyncResumeDisposition.commitDurable,
      );
    });

    test('reconciles a complete legacy cache', () {
      final metadata = RemoteSyncCacheMetadata(
        cursorSchemaVersion: 1,
        allPagesFetched: true,
        syncComplete: true,
      );

      expect(
        classifyRemoteSyncResume(
          metadata: metadata,
          hasRemainingEntries: false,
        ),
        RemoteSyncResumeDisposition.reconcileLegacy,
      );
    });
  });
}

const _cursor = CloudSyncCursor(
  seconds: 100,
  nanoseconds: 200,
  documentId: 'high-water',
);

PendingRemoteSyncPage _page({
  required bool hasMore,
  PendingRemoteSyncStatus status = PendingRemoteSyncStatus.pending,
}) {
  return PendingRemoteSyncPage(
    pageIndex: 0,
    hasMore: hasMore,
    lastDocumentId: 'note-1',
    syncs: {
      'note-1': PendingRemoteSync(
        localId: 1,
        remoteDocId: 'note-1',
        remoteData: {'local_id': 1, 'updated_at': '2026-07-29T00:00:00.000Z'},
        fetchedAt: DateTime.utc(2026, 7, 29),
        status: status,
      ),
    },
  );
}

class _MemoryFileSystem implements FileSystem {
  final Map<String, Uint8List> files = {};
  final Set<String> directories = {'/', '/cache'};

  void seed(String filePath, List<int> bytes) {
    files[filePath] = Uint8List.fromList(bytes);
    var parent = path.dirname(filePath);
    while (parent != '.' && directories.add(parent)) {
      final next = path.dirname(parent);
      if (next == parent) break;
      parent = next;
    }
  }

  @override
  Future<String> get cacheDir async => '/cache';

  @override
  Future<String> get documentDir async => '/documents';

  @override
  Future<void> createDirectory(String directory) async {
    directories.add(directory);
  }

  @override
  Future<void> writeBytes(
    String filePath,
    Uint8List data, {
    bool append = false,
  }) async {
    directories.add(path.dirname(filePath));
    files[filePath] = append && files.containsKey(filePath)
        ? Uint8List.fromList([...files[filePath]!, ...data])
        : Uint8List.fromList(data);
  }

  @override
  Future<Uint8List> readBytes(String filePath) async =>
      Uint8List.fromList(files[filePath] ?? (throw StateError('missing')));

  @override
  Future<bool> delete(String filePath) async => files.remove(filePath) != null;

  @override
  Future<bool> exists(String filePath) async => files.containsKey(filePath);

  @override
  Future<bool> isDirectory(String value) async => directories.contains(value);

  @override
  Future<bool> isFile(String value) async => files.containsKey(value);

  @override
  Future<List<String>> list([String directory = '/']) async {
    return files.keys
        .where((candidate) {
          return path.dirname(candidate) == directory;
        })
        .map(path.basename)
        .toList();
  }

  @override
  Future<String> copy(String sourcePath, String targetPath) async {
    await writeBytes(targetPath, await readBytes(sourcePath));
    return targetPath;
  }

  @override
  Future<int?> length(String filePath) async => files[filePath]?.length;

  @override
  Future<void> writeString(
    String filePath,
    String data, {
    bool append = false,
  }) => writeBytes(
    filePath,
    Uint8List.fromList(utf8.encode(data)),
    append: append,
  );

  @override
  Future<String> readString(String filePath) async =>
      utf8.decode(await readBytes(filePath));

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) async =>
      false;

  @override
  String get backendType => 'memory';

  @override
  bool get opfsSupported => false;

  @override
  Future<List<Map<String, dynamic>>> listRecursive([
    String directory = '/',
  ]) async => const [];

  @override
  Future<Map<String, dynamic>> testOpfs() async => const {};
}
