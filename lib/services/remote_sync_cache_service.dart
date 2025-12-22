import 'dart:convert';

import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:path/path.dart' as path;

/// Service for managing the cache of pending remote syncs.
/// This persists pending syncs to JSON files organized by pages,
/// allowing sync to resume after app restart and reducing Firebase reads.
class RemoteSyncCacheService {
  RemoteSyncCacheService._internal();

  factory RemoteSyncCacheService() => _instance;

  static final RemoteSyncCacheService _instance =
      RemoteSyncCacheService._internal();

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

  /// Lock to prevent concurrent file operations
  bool _isWriting = false;

  /// Get cache directory path
  Future<String> _getCacheDir() async {
    final fs = await fileSystem();
    final cacheDir = await fs.cacheDir;
    return path.join(cacheDir, _cacheDir);
  }

  /// Initialize the cache service - loads existing cache from disk
  Future<void> init() async {
    if (_initialized) return;

    try {
      await _loadMetadata();
      if (_metadata != null && !_metadata!.syncComplete) {
        await _loadAllPages();
        AppLogger.log(
          "[SYNC] CACHE: Loaded ${_pages.length} pages with "
          "${_getTotalPendingCount()} pending syncs",
        );
      }
      _initialized = true;
    } catch (e) {
      AppLogger.error('[SYNC] CACHE ERROR: Initializing cache', e);
      // Clear corrupted cache
      await clear();
      _initialized = true;
    }
  }

  /// Get total count of pending syncs across all pages
  int _getTotalPendingCount() {
    int count = 0;
    for (final page in _pages.values) {
      count += page.pendingCount;
    }
    return count;
  }

  /// Check if there are pending syncs that need to be processed
  bool get hasPendingSyncs {
    if (_metadata == null || _metadata!.syncComplete) return false;
    return _getTotalPendingCount() > 0;
  }

  /// Get the current metadata
  RemoteSyncCacheMetadata? get metadata => _metadata;

  /// Get all pages
  Map<int, PendingRemoteSyncPage> get pages => Map.unmodifiable(_pages);

  /// Start a new sync session - clears existing cache and prepares for new sync
  Future<RemoteSyncCacheMetadata> startNewSync(DateTime? lastSyncedAt) async {
    await clear();
    _metadata = RemoteSyncCacheMetadata(lastSyncedAt: lastSyncedAt);
    await _saveMetadata();
    AppLogger.log("[SYNC] CACHE: Started new sync session");
    return _metadata!;
  }

  /// Add a new page of syncs to the cache
  /// [maxUpdatedAt] is the max updated_at from this page, used to update lastSyncedAt
  Future<void> addPage(
    PendingRemoteSyncPage page, {
    DateTime? maxUpdatedAt,
  }) async {
    _pages[page.pageIndex] = page;
    _metadata!.totalPages = _pages.length;
    _metadata!.updatedAt = DateTime.now();

    // Update lastSyncedAt to the max updated_at from fetched docs
    // This prevents re-fetching same notes on next sync
    if (maxUpdatedAt != null) {
      if (_metadata!.lastSyncedAt == null ||
          maxUpdatedAt.isAfter(_metadata!.lastSyncedAt!)) {
        _metadata!.lastSyncedAt = maxUpdatedAt;
      }
    }

    if (!page.hasMore) {
      _metadata!.allPagesFetched = true;
    }

    await _savePage(page);
    await _saveMetadata();
    AppLogger.log(
      "[SYNC] CACHE: Added page ${page.pageIndex} with ${page.syncs.length} syncs",
    );
  }

  /// Get the lastSyncedAt timestamp from cache metadata
  DateTime? get lastSyncedAt => _metadata?.lastSyncedAt;

  /// Update a sync entry in the cache
  Future<void> updateSync(int localId, PendingRemoteSync updatedSync) async {
    // Find which page contains this sync
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(localId)) {
        entry.value.syncs[localId] = updatedSync;
        await _savePage(entry.value);
        break;
      }
    }
    _metadata?.updatedAt = DateTime.now();
    await _saveMetadata();
  }

  /// Mark a sync as completed and remove it from the cache
  Future<void> markCompleted(int localId) async {
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(localId)) {
        entry.value.syncs.remove(localId);

        // If page is now empty, delete the page file
        if (entry.value.syncs.isEmpty) {
          await _deletePageFile(entry.key);
          _pages.remove(entry.key);
        } else {
          await _savePage(entry.value);
        }
        break;
      }
    }
    _metadata?.updatedAt = DateTime.now();

    // Check if all syncs are complete
    if (_metadata?.allPagesFetched == true && _getTotalPendingCount() == 0) {
      _metadata!.syncComplete = true;
      AppLogger.log("[SYNC] CACHE: All syncs completed!");
    }
    await _saveMetadata();
  }

  /// Mark the sync session as complete
  /// Used when there are no notes to process (empty fetch)
  Future<void> markSyncComplete() async {
    if (_metadata != null) {
      _metadata!.syncComplete = true;
      await _saveMetadata();
    }
  }

  /// Delete a page file from disk
  Future<void> _deletePageFile(int pageIndex) async {
    try {
      final fs = await fileSystem();
      final cacheDir = await _getCacheDir();
      final pagePath = path.join(cacheDir, 'page_$pageIndex.json');
      if (await fs.exists(pagePath)) {
        await fs.delete(pagePath);
        AppLogger.log("[SYNC] CACHE: Deleted empty page file $pageIndex");
      }
    } catch (e) {
      AppLogger.error('[SYNC] CACHE ERROR: Deleting page file $pageIndex', e);
    }
  }

  /// Mark a sync as failed
  Future<void> markFailed(int localId, String error) async {
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(localId)) {
        final sync = entry.value.syncs[localId]!;
        entry.value.syncs[localId] = sync.copyWith(
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
    int localId,
    Map<String, dynamic> newRemoteData,
    String remoteDocId,
  ) async {
    for (final entry in _pages.entries) {
      if (entry.value.syncs.containsKey(localId)) {
        final existingSync = entry.value.syncs[localId]!;

        // If currently in progress, mark it to be re-synced after completion
        if (existingSync.status == PendingRemoteSyncStatus.inProgress) {
          // Update the data but keep status as inProgress
          // The sync logic should check if data changed and re-sync if needed
          entry.value.syncs[localId] = existingSync.copyWith(
            remoteData: newRemoteData,
          );
        } else {
          // Reset to pending with new data
          entry.value.syncs[localId] = PendingRemoteSync(
            localId: localId,
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

        AppLogger.log("[SYNC] CACHE: Updated remote data for note $localId");
        return true;
      }
    }
    return false;
  }

  /// Get a sync entry by local ID
  PendingRemoteSync? getSync(int localId) {
    for (final page in _pages.values) {
      if (page.syncs.containsKey(localId)) {
        return page.syncs[localId];
      }
    }
    return null;
  }

  /// Get all pending syncs (status is pending or failed)
  List<PendingRemoteSync> getPendingSyncs() {
    final result = <PendingRemoteSync>[];
    for (final page in _pages.values) {
      for (final sync in page.syncs.values) {
        if (sync.status == PendingRemoteSyncStatus.pending ||
            sync.status == PendingRemoteSyncStatus.failed) {
          result.add(sync);
        }
      }
    }
    return result;
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
      final fs = await fileSystem();
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
      'pendingCount': _getTotalPendingCount(),
      'hasPendingSyncs': hasPendingSyncs,
      'files': files,
    };
  }

  /// Clear the entire cache
  Future<void> clear() async {
    final fs = await fileSystem();
    final cacheDir = await _getCacheDir();

    try {
      final files = await fs.list(cacheDir);
      for (final fileName in files) {
        final filePath = path.join(cacheDir, fileName);
        await fs.delete(filePath);
      }
    } catch (e) {
      // Directory might not exist yet
    }

    _pages.clear();
    _metadata = null;
    AppLogger.log("[SYNC] CACHE: Cache cleared");
  }

  /// Load metadata from disk
  Future<void> _loadMetadata() async {
    final fs = await fileSystem();
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
      _metadata = null;
    }
  }

  /// Save metadata to disk
  Future<void> _saveMetadata() async {
    if (_metadata == null) return;
    await _writeFile(_metadataFile, jsonEncode(_metadata!.toJson()));
  }

  /// Load all pages from disk
  Future<void> _loadAllPages() async {
    if (_metadata == null) return;

    final fs = await fileSystem();
    final cacheDir = await _getCacheDir();

    for (int i = 0; i < _metadata!.totalPages; i++) {
      final pagePath = path.join(cacheDir, 'page_$i.json');
      try {
        if (await fs.exists(pagePath)) {
          final content = await fs.readString(pagePath);
          final json = jsonDecode(content) as Map<String, dynamic>;
          final page = PendingRemoteSyncPage.fromJson(json);
          _pages[i] = page;
        }
      } catch (e) {
        AppLogger.error('[SYNC] CACHE ERROR: Loading page $i', e);
      }
    }
  }

  /// Save a page to disk
  Future<void> _savePage(PendingRemoteSyncPage page) async {
    await _writeFile('page_${page.pageIndex}.json', jsonEncode(page.toJson()));
  }

  /// Write a file to the cache directory with simple locking
  Future<void> _writeFile(String fileName, String content) async {
    // Simple lock to prevent concurrent writes
    while (_isWriting) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    _isWriting = true;

    try {
      final fs = await fileSystem();
      final cacheDir = await _getCacheDir();
      final filePath = path.join(cacheDir, fileName);

      // Write to temp file first, then rename for atomicity
      final tempPath = '$filePath.tmp';
      await fs.writeString(tempPath, content);

      // Delete original if exists
      if (await fs.exists(filePath)) {
        await fs.delete(filePath);
      }

      // Rename temp to final
      await fs.copy(tempPath, filePath);
      await fs.delete(tempPath);
    } finally {
      _isWriting = false;
    }
  }
}
