import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/cloud_operation.dart';

import 'dart:convert';

import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/remote_document_revision.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

typedef RemoteSyncFileSystemProvider = Future<FileSystem> Function();

enum RemoteSyncResumeDisposition {
  retainPending,
  commitDurable,
  reconcileLegacy,
  restartIncomplete,
}

RemoteSyncResumeDisposition classifyRemoteSyncResume({
  required RemoteSyncCacheMetadata? metadata,
  required bool hasRemainingEntries,
}) {
  if (hasRemainingEntries) {
    return RemoteSyncResumeDisposition.retainPending;
  }
  if (metadata?.isCommitReady != true) {
    return RemoteSyncResumeDisposition.restartIncomplete;
  }
  if (metadata!.cursorSchemaVersion == CloudSyncCheckpoint.schemaVersion) {
    return RemoteSyncResumeDisposition.commitDurable;
  }
  return RemoteSyncResumeDisposition.reconcileLegacy;
}

/// Service for managing the cache of pending remote syncs.
/// This persists pending syncs to JSON files organized by pages,
/// allowing sync to resume after app restart and reducing Firebase reads.
class RemoteSyncCacheService {
  RemoteSyncCacheService._internal({
    RemoteSyncFileSystemProvider? fileSystemProvider,
  }) : _fileSystemProvider = fileSystemProvider ?? fileSystem;

  factory RemoteSyncCacheService() => _instance;

  static final RemoteSyncCacheService _instance =
      RemoteSyncCacheService._internal();

  @visibleForTesting
  RemoteSyncCacheService.forTesting(this._fileSystemProvider);

  final RemoteSyncFileSystemProvider _fileSystemProvider;

  /// Page size for fetching notes from Firebase
  static const int pageSize = 20;

  /// Cache directory name
  static const String _cacheDir = 'remote_sync_cache';

  /// Metadata file name
  static const String _metadataFile = 'metadata.json';

  /// In-memory cache of pages
  final Map<int, PendingRemoteSyncPage> _pages = {};

  /// In-memory cache metadata
  RemoteSyncCacheMetadata? _metadata;

  /// Whether the cache has been initialized
  bool _initialized = false;

  Future<void> _pendingWrites = Future.value();

  Future<T> _withWriteLock<T>(Future<T> Function() operation) {
    final result = _pendingWrites.then((_) => operation());
    _pendingWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _requireSession(RemoteSyncCacheMetadata? session) {
    requireCloudOperation();
    if (session == null || !identical(session, _metadata)) {
      throw const CloudOperationCancelled();
    }
  }

  /// Get cache directory path
  Future<String> _getCacheDir() async {
    final fs = await _fileSystemProvider();
    final cacheDir = await fs.cacheDir;
    return path.join(cacheDir, _cacheDir);
  }

  /// Initialize the cache service - loads existing cache from disk
  Future<void> init() async {
    if (_initialized) return;

    try {
      await _loadMetadata();
      if (_metadata != null && !_metadata!.isCommitReady) {
        if (!await _loadAllPages()) {
          // An older cache may also have removed completed pages. Without a
          // complete page set, only the library checkpoint is safe to resume.
          _metadata!.allPagesFetched = false;
          _pages.clear();
        }
        _recomputeCompletionState();
        await _saveMetadata();
        AppLogger.log(
          "[SYNC] CACHE: Loaded ${_pages.length} pages with "
          "${_getTotalRemainingCount()} remaining syncs",
        );
      }
      _initialized = true;
    } catch (e) {
      AppLogger.error('[SYNC] CACHE ERROR: Initializing cache', e);
      // A failed read is not evidence that pending work can be discarded.
      // Leave the durable cache intact so initialization can be retried.
      _initialized = false;
      rethrow;
    }
  }

  /// Get total count of pending syncs across all pages
  int _getTotalRemainingCount() {
    int count = 0;
    for (final page in _pages.values) {
      count += page.syncs.length;
    }
    return count;
  }

  /// Check if there are pending syncs that need to be processed
  bool get hasPendingSyncs {
    if (_metadata == null || _metadata!.isCommitReady) return false;
    return _getTotalRemainingCount() > 0;
  }

  /// Get the current metadata
  RemoteSyncCacheMetadata? get metadata => _metadata;

  /// Get all pages
  Map<int, PendingRemoteSyncPage> get pages => Map.unmodifiable(_pages);

  /// Start a new sync session - clears existing cache and prepares for new sync
  Future<RemoteSyncCacheMetadata> startNewSync(
    CloudSyncCursor? startingCursor, {
    String? ownerUid,
  }) => _withWriteLock(() async {
    await _clear(false);
    requireCloudOperation();
    final metadata = RemoteSyncCacheMetadata(
      lastCursor: startingCursor,
      ownerUid: ownerUid,
    );
    _metadata = metadata;
    await _writeSessionFile(
      _metadataFile,
      jsonEncode(metadata.toJson()),
      metadata,
    );
    AppLogger.log("[SYNC] CACHE: Started new sync session");
    return metadata;
  });

  /// Add a new page of syncs to the cache
  /// [maxCursor] is the greatest exact cloud cursor safe to commit once all
  /// cached entries have been applied locally.
  Future<void> addPage(
    PendingRemoteSyncPage page, {
    CloudSyncCursor? maxCursor,
  }) async {
    if (_metadata == null) {
      AppLogger.log(
        "[SYNC] CACHE: addPage called but session was invalidated, skipping",
      );
      return;
    }
    final session = _metadata!;
    await _withWriteLock(() async {
      _requireSession(session);
      final fs = await _fileSystemProvider();
      final directory = path.join(await fs.cacheDir, _cacheDir);
      final file = path.join(directory, 'page_${page.pageIndex}.json');
      _requireSession(session);
      try {
        await _writeCacheFile(fs, file, jsonEncode(page.toJson()), session);
        _requireSession(session);
      } on CloudOperationCancelled {
        // The replacement session cannot reuse this index until the lock is released.
        if (page.pageIndex >= session.totalPages && await fs.exists(file)) {
          await fs.delete(file);
        }
        rethrow;
      }
      _pages[page.pageIndex] = page;
      if (page.syncs.isNotEmpty) session.syncComplete = false;
      if (page.pageIndex >= session.totalPages) {
        session.totalPages = page.pageIndex + 1;
      }
      session.updatedAt = DateTime.now();
      if (maxCursor != null) {
        session.lastCursor = session.lastCursor?.max(maxCursor) ?? maxCursor;
      }
      await _writeCacheFile(
        fs,
        path.join(directory, _metadataFile),
        jsonEncode(session.toJson()),
        session,
      );
    });
    AppLogger.log(
      "[SYNC] CACHE: Added page ${page.pageIndex} with ${page.syncs.length} syncs",
    );
  }

  CloudSyncCursor? get lastCursor => _metadata?.lastCursor;

  /// Records that the pagination loop reached its terminal result normally.
  ///
  /// This is deliberately separate from [addPage] so a crash after persisting
  /// the last observed page cannot make an interrupted fetch commit-ready.
  Future<void> markAllPagesFetched() async {
    final metadata = _metadata;
    if (metadata == null) return;
    metadata.allPagesFetched = true;
    metadata.updatedAt = DateTime.now();
    _recomputeCompletionState();
    await _saveMetadata();
  }

  /// Update a sync entry in the cache
  Future<void> updateSync(
    String remoteDocId,
    PendingRemoteSync updatedSync,
  ) async {
    // Find which page contains this sync
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(remoteDocId)) {
        entry.value.syncs[remoteDocId] = updatedSync;
        await _savePage(entry.value);
        break;
      }
    }
    _metadata?.updatedAt = DateTime.now();
    await _saveMetadata();
  }

  /// Marks a sync completed only if the cache still contains the revision that
  /// was processed.
  ///
  /// A listener can replace an in-progress entry with a newer revision. In
  /// that case the newer data is restored to pending instead of being removed
  /// by completion of the older operation.
  Future<bool> completeIfCurrentRevision(
    String remoteDocId,
    String processedRevision,
  ) async {
    for (final entry in _pages.entries) {
      final current = entry.value.syncs[remoteDocId];
      if (current != null) {
        final currentRevision = remoteDocumentRevision(
          current.remoteData,
          remoteDocId,
        );
        if (currentRevision != processedRevision) {
          entry.value.syncs[remoteDocId] = current.copyWith(
            status: PendingRemoteSyncStatus.pending,
          );
          await _savePage(entry.value);
          _metadata?.updatedAt = DateTime.now();
          _recomputeCompletionState();
          await _saveMetadata();
          return false;
        }

        entry.value.syncs.remove(remoteDocId);

        // Keep the empty page on disk as proof it was applied until the
        // whole fetch is committed. A missing file must trigger a refetch.
        await _savePage(entry.value);
        if (entry.value.syncs.isEmpty &&
            identical(_pages[entry.key], entry.value)) {
          _pages.remove(entry.key);
        }
        break;
      }
    }
    _metadata?.updatedAt = DateTime.now();

    _recomputeCompletionState();
    await _saveMetadata();
    return true;
  }

  /// Compatibility helper for non-racing call sites.
  Future<void> markCompleted(String remoteDocId) async {
    final current = getSync(remoteDocId);
    if (current == null) return;
    await completeIfCurrentRevision(
      remoteDocId,
      remoteDocumentRevision(current.remoteData, remoteDocId),
    );
  }

  void _recomputeCompletionState() {
    final metadata = _metadata;
    if (metadata == null) return;
    final wasComplete = metadata.syncComplete;
    metadata.syncComplete =
        metadata.allPagesFetched && _getTotalRemainingCount() == 0;
    if (!wasComplete && metadata.syncComplete) {
      AppLogger.log("[SYNC] CACHE: All syncs completed!");
    }
  }

  /// Mark a sync as failed
  Future<void> markFailed(String remoteDocId, String error) async {
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(remoteDocId)) {
        final sync = entry.value.syncs[remoteDocId]!;
        entry.value.syncs[remoteDocId] = sync.copyWith(
          status: PendingRemoteSyncStatus.failed,
          retryCount: sync.retryCount + 1,
          lastError: error,
        );
        await _savePage(entry.value);
        break;
      }
    }
    _metadata?.updatedAt = DateTime.now();
    await _saveMetadata();
  }

  /// Update a sync entry with new remote data (from real-time listener)
  /// Returns true if the sync was found and updated
  Future<bool> updateRemoteData(
    String remoteDocId,
    Map<String, dynamic> newRemoteData,
  ) async {
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(remoteDocId)) {
        final existingSync = entry.value.syncs[remoteDocId]!;

        // If currently in progress, mark it to be re-synced after completion
        if (existingSync.status == PendingRemoteSyncStatus.inProgress) {
          // Update the data but keep status as inProgress
          // The sync logic should check if data changed and re-sync if needed
          entry.value.syncs[remoteDocId] = existingSync.copyWith(
            remoteData: newRemoteData,
          );
        } else {
          // Reset to pending with new data
          entry.value.syncs[remoteDocId] = PendingRemoteSync(
            localId: existingSync.localId,
            remoteDocId: remoteDocId,
            remoteData: newRemoteData,
            fetchedAt: DateTime.now(),
            retryCount: 0,
            status: PendingRemoteSyncStatus.pending,
          );
        }

        await _savePage(entry.value);
        _metadata?.updatedAt = DateTime.now();
        await _saveMetadata();

        AppLogger.log(
          "[SYNC] CACHE: Updated remote data for note $remoteDocId",
        );
        return true;
      }
    }
    return false;
  }

  /// Get a sync entry by stable Firestore document ID.
  PendingRemoteSync? getSync(String remoteDocId) {
    for (final page in _pages.values) {
      if (page.syncs.containsKey(remoteDocId)) {
        return page.syncs[remoteDocId];
      }
    }
    return null;
  }

  /// Get all pending syncs (status is pending or failed)
  /// Deduplicates by stable remote ID, keeping the newest version per note.
  List<PendingRemoteSync> getPendingSyncs() {
    final Map<String, PendingRemoteSync> deduped = {};
    int totalBeforeDedup = 0;

    for (final page in _pages.values) {
      for (final sync in page.syncs.values) {
        if (sync.status == PendingRemoteSyncStatus.pending ||
            sync.status == PendingRemoteSyncStatus.failed) {
          totalBeforeDedup++;
          final existing = deduped[sync.remoteDocId];
          if (existing == null) {
            deduped[sync.remoteDocId] = sync;
          } else {
            // Keep the one with the more recent updated_at timestamp
            final existingUpdatedAt = existing.remoteData['updated_at'];
            final syncUpdatedAt = sync.remoteData['updated_at'];

            if (existingUpdatedAt != null && syncUpdatedAt != null) {
              final existingTime = DateTime.parse(existingUpdatedAt as String);
              final syncTime = DateTime.parse(syncUpdatedAt as String);
              if (syncTime.isAfter(existingTime)) {
                deduped[sync.remoteDocId] = sync;
              }
            } else if (syncUpdatedAt != null) {
              // Prefer the one with a timestamp
              deduped[sync.remoteDocId] = sync;
            }
          }
        }
      }
    }

    // Log deduplication if there were duplicates
    if (totalBeforeDedup != deduped.length) {
      AppLogger.log(
        "[SYNC] CACHE: Deduplicated pending syncs: $totalBeforeDedup -> ${deduped.length} unique notes",
      );
    }

    return deduped.values.toList();
  }

  /// Get all local IDs that have pending syncs
  List<int> getPendingLocalIds() {
    return getPendingSyncs().map((s) => s.localId).toList();
  }

  /// Check if cache data is stale (older than threshold)
  bool isCacheStale({Duration threshold = const Duration(minutes: 5)}) {
    if (_metadata == null) return true;
    final cacheAge = DateTime.now().difference(_metadata!.updatedAt);
    return cacheAge > threshold;
  }

  /// Get debug information about the cache state
  Future<Map<String, dynamic>> getDebugInfo() async {
    final files = <String, String>{};
    String? cacheDirPath;

    try {
      final fs = await _fileSystemProvider();
      final cacheDir = await _getCacheDir();
      cacheDirPath = cacheDir;

      final fileList = await fs
          .list(cacheDir)
          .timeout(const Duration(seconds: 3), onTimeout: () => <String>[]);

      for (final fileName in fileList) {
        try {
          final filePath = path.join(cacheDir, fileName);
          final content = await fs
              .readString(filePath)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => 'Timeout reading file',
              );
          // Truncate large files
          files[fileName] = content.length > 2000
              ? '${content.substring(0, 2000)}... (truncated)'
              : content;
        } catch (e) {
          files[fileName] = 'Error reading: $e';
        }
      }
    } catch (e) {
      files['error'] = e.toString();
    }

    return {
      'initialized': _initialized,
      'cacheDir': cacheDirPath,
      'metadata': _metadata?.toJson(),
      'pageCount': _pages.length,
      'pendingCount': _getTotalRemainingCount(),
      'hasPendingSyncs': hasPendingSyncs,
      'files': files,
    };
  }

  /// The retired account directory is cleaned in the background. Drop only
  /// the in-memory pages here, including when sign-out needs another attempt.
  void resetAfterSignOut() {
    _pages.clear();
    _metadata = null;
    _initialized = false;
  }

  /// Clear the entire cache
  Future<void> clear({bool strict = false}) =>
      _withWriteLock(() => _clear(strict));

  Future<void> _clear(bool strict) async {
    final fs = await _fileSystemProvider();
    final cacheDir = path.join(await fs.cacheDir, _cacheDir);

    try {
      final files = await fs.isDirectory(cacheDir)
          ? await fs.list(cacheDir)
          : <String>[];
      for (final fileName in files) {
        final filePath = path.join(cacheDir, fileName);
        requireCloudOperation();
        final deleted = await fs.delete(filePath);
        if (strict && !deleted && await fs.exists(filePath)) {
          throw StateError('Could not clear remote sync cache');
        }
      }
    } catch (e) {
      if (strict || e is CloudOperationCancelled) rethrow;
      // Directory might not exist yet
    }

    _pages.clear();
    _metadata = null;
    AppLogger.log("[SYNC] CACHE: Cache cleared");
  }

  /// Load metadata from disk
  Future<void> _loadMetadata() async {
    final fs = await _fileSystemProvider();
    final cacheDir = await _getCacheDir();
    final metadataPath = path.join(cacheDir, _metadataFile);

    try {
      if (await fs.exists(metadataPath)) {
        final content = await fs.readString(metadataPath);
        final json = jsonDecode(content) as Map<String, dynamic>;
        _metadata = RemoteSyncCacheMetadata.fromJson(json);
      }
    } catch (e) {
      AppLogger.error('[SYNC] CACHE ERROR: Loading metadata', e);
      rethrow;
    }
  }

  /// Save metadata to disk
  Future<void> _saveMetadata() async {
    final session = _metadata;
    if (session == null) return;
    await _withWriteLock(
      () => _writeSessionFile(
        _metadataFile,
        jsonEncode(session.toJson()),
        session,
      ),
    );
  }

  /// Returns false when an expected page is missing, even if others survived.
  Future<bool> _loadAllPages() async {
    final fs = await _fileSystemProvider();
    final cacheDir = await _getCacheDir();

    for (int i = 0; i < _metadata!.totalPages; i++) {
      final pagePath = path.join(cacheDir, 'page_$i.json');
      try {
        if (!await fs.exists(pagePath)) return false;
        final content = await fs.readString(pagePath);
        final json = jsonDecode(content) as Map<String, dynamic>;
        final page = PendingRemoteSyncPage.fromJson(json);
        page.syncs.removeWhere(
          (_, sync) => sync.status == PendingRemoteSyncStatus.completed,
        );
        for (final sync in page.syncs.values) {
          if (sync.status == PendingRemoteSyncStatus.inProgress) {
            sync.status = PendingRemoteSyncStatus.pending;
          }
        }
        if (page.syncs.isNotEmpty) _pages[i] = page;
      } catch (e) {
        AppLogger.error('[SYNC] CACHE ERROR: Loading page $i', e);
        rethrow;
      }
    }
    return true;
  }

  /// Save a page to disk
  Future<void> _savePage(PendingRemoteSyncPage page) {
    final session = _metadata;
    return _withWriteLock(
      () => _writeSessionFile(
        'page_${page.pageIndex}.json',
        jsonEncode(page.toJson()),
        session,
      ),
    );
  }

  Future<void> _writeSessionFile(
    String fileName,
    String content,
    RemoteSyncCacheMetadata? session,
  ) async {
    final fs = await _fileSystemProvider();
    final file = path.join(await fs.cacheDir, _cacheDir, fileName);
    await _writeCacheFile(fs, file, content, session);
  }

  Future<void> _writeCacheFile(
    FileSystem fs,
    String file,
    String content,
    RemoteSyncCacheMetadata? session,
  ) async {
    _requireSession(session);
    final temp = '$file.tmp';
    try {
      await fs.writeString(temp, content);
      _requireSession(session);
      await fs.copy(temp, file);
    } finally {
      await fs.delete(temp);
    }
  }
}
