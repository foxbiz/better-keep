import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a remote note document that needs to be synced locally.
/// This is used to cache fetched remote data for reliable sync with retry support.
class PendingRemoteSync {
  /// The local note ID
  final int localId;

  /// The Firestore document ID
  final String remoteDocId;

  /// The remote note data as fetched from Firebase
  final Map<String, dynamic> remoteData;

  /// When this data was fetched from Firebase
  final DateTime fetchedAt;

  /// Number of sync attempts made
  int retryCount;

  /// Last error message if sync failed
  String? lastError;

  /// Sync status
  PendingRemoteSyncStatus status;

  PendingRemoteSync({
    required this.localId,
    required this.remoteDocId,
    required this.remoteData,
    required this.fetchedAt,
    this.retryCount = 0,
    this.lastError,
    this.status = PendingRemoteSyncStatus.pending,
  });

  factory PendingRemoteSync.fromJson(Map<String, dynamic> json) {
    return PendingRemoteSync(
      localId: json['local_id'] as int,
      remoteDocId: json['remote_doc_id'] as String,
      remoteData: Map<String, dynamic>.from(json['remote_data'] as Map),
      fetchedAt: DateTime.parse(json['fetched_at'] as String),
      retryCount: json['retry_count'] as int? ?? 0,
      lastError: json['last_error'] as String?,
      status: PendingRemoteSyncStatus.values.byName(
        json['status'] as String? ?? 'pending',
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'local_id': localId,
      'remote_doc_id': remoteDocId,
      'remote_data': _convertForJson(remoteData),
      'fetched_at': fetchedAt.toIso8601String(),
      'retry_count': retryCount,
      'last_error': lastError,
      'status': status.name,
    };
  }

  /// Recursively convert Firestore Timestamp objects to ISO8601 strings for JSON encoding
  static dynamic _convertForJson(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    } else if (value is DateTime) {
      return value.toIso8601String();
    } else if (value is Map) {
      return value.map((k, v) => MapEntry(k, _convertForJson(v)));
    } else if (value is List) {
      return value.map(_convertForJson).toList();
    }
    return value;
  }

  /// Update the remote data (e.g., when real-time listener receives an update)
  PendingRemoteSync copyWith({
    Map<String, dynamic>? remoteData,
    int? retryCount,
    String? lastError,
    PendingRemoteSyncStatus? status,
  }) {
    return PendingRemoteSync(
      localId: localId,
      remoteDocId: remoteDocId,
      remoteData: remoteData ?? this.remoteData,
      fetchedAt: fetchedAt,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      status: status ?? this.status,
    );
  }
}

enum PendingRemoteSyncStatus {
  /// Waiting to be synced
  pending,

  /// Currently being synced
  inProgress,

  /// Sync failed, will retry
  failed,

  /// Sync succeeded (will be removed from cache)
  completed,
}

/// Represents a page of pending remote syncs
class PendingRemoteSyncPage {
  /// Page number (0-indexed)
  final int pageIndex;

  /// The pending syncs in this page
  final Map<int, PendingRemoteSync> syncs;

  /// Firestore cursor for fetching next page (last document snapshot ID)
  final String? lastDocumentId;

  /// Whether there are more pages to fetch
  final bool hasMore;

  /// When this page was fetched
  final DateTime fetchedAt;

  PendingRemoteSyncPage({
    required this.pageIndex,
    required this.syncs,
    this.lastDocumentId,
    this.hasMore = false,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory PendingRemoteSyncPage.fromJson(Map<String, dynamic> json) {
    final syncsJson = json['syncs'] as Map<String, dynamic>;
    final syncs = <int, PendingRemoteSync>{};
    for (final entry in syncsJson.entries) {
      final sync = PendingRemoteSync.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      syncs[int.parse(entry.key)] = sync;
    }

    return PendingRemoteSyncPage(
      pageIndex: json['page_index'] as int,
      syncs: syncs,
      lastDocumentId: json['last_document_id'] as String?,
      hasMore: json['has_more'] as bool? ?? false,
      fetchedAt: DateTime.parse(json['fetched_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    final syncsJson = <String, dynamic>{};
    for (final entry in syncs.entries) {
      syncsJson[entry.key.toString()] = entry.value.toJson();
    }

    return {
      'page_index': pageIndex,
      'syncs': syncsJson,
      'last_document_id': lastDocumentId,
      'has_more': hasMore,
      'fetched_at': fetchedAt.toIso8601String(),
    };
  }

  /// Check if all syncs in this page are completed
  bool get allCompleted =>
      syncs.values.every((s) => s.status == PendingRemoteSyncStatus.completed);

  /// Get count of pending syncs
  int get pendingCount => syncs.values
      .where(
        (s) =>
            s.status == PendingRemoteSyncStatus.pending ||
            s.status == PendingRemoteSyncStatus.failed,
      )
      .length;
}

/// Cache metadata for tracking pagination state
class RemoteSyncCacheMetadata {
  /// Total pages fetched
  int totalPages;

  /// Current page being synced
  int currentSyncPage;

  /// Last sync time used for the query - updated as pages are fetched
  /// This tracks the max updated_at from fetched docs to avoid re-fetching
  DateTime? lastSyncedAt;

  /// Whether all pages have been fetched from Firebase
  bool allPagesFetched;

  /// Whether sync is complete (all pages synced successfully)
  bool syncComplete;

  /// When the cache was created
  final DateTime createdAt;

  /// When the cache was last updated
  DateTime updatedAt;

  RemoteSyncCacheMetadata({
    this.totalPages = 0,
    this.currentSyncPage = 0,
    this.lastSyncedAt,
    this.allPagesFetched = false,
    this.syncComplete = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory RemoteSyncCacheMetadata.fromJson(Map<String, dynamic> json) {
    return RemoteSyncCacheMetadata(
      totalPages: json['total_pages'] as int? ?? 0,
      currentSyncPage: json['current_sync_page'] as int? ?? 0,
      lastSyncedAt: json['last_synced_at'] != null
          ? DateTime.parse(json['last_synced_at'] as String)
          : null,
      allPagesFetched: json['all_pages_fetched'] as bool? ?? false,
      syncComplete: json['sync_complete'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'total_pages': totalPages,
      'current_sync_page': currentSyncPage,
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      'all_pages_fetched': allPagesFetched,
      'sync_complete': syncComplete,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}
