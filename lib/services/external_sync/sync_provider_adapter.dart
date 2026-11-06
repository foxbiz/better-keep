import 'dart:typed_data';

import 'sync_revision.dart';

/// One configured remote library. Registration is the only provider-specific
/// knowledge required by the coordinator; cursors are opaque to the core.
abstract interface class SyncProviderAdapter {
  String get connectionId;

  Future<SyncChangePage> changes(String? cursor);

  Future<Uint8List> readObject(String objectId);

  /// Retry-safe publication: an existing ID must contain identical bytes.
  Future<void> putObject(String objectId, Uint8List encryptedBytes);

  /// Publish only after every referenced encrypted object is durable remotely.
  /// The adapter encodes/encrypts the metadata before exposing it remotely.
  Future<void> publish(SyncRevision revision);
}

/// Optional bounded prefetch. Oversized objects remain on the serial read path.
abstract interface class SmallSyncObjectReader {
  Future<bool> get supportsSmallReads;
  Future<Uint8List?> readSmallObject(String objectId);
}

/// Optional immutable batch writes. A failed batch must not be acknowledged;
/// retrying any subset must validate existing content rather than overwrite it.
abstract interface class BatchSyncWriter {
  Future<bool> get supportsBatchWrites;
  Future<void> putObjects(Map<String, Uint8List> objects);
  Future<void> publishBatch(List<SyncRevision> revisions);
}

class SyncChangePage {
  SyncChangePage({
    required Iterable<SyncRevision> revisions,
    required this.cursor,
    required this.hasMore,
  }) : revisions = List.unmodifiable(revisions);

  final List<SyncRevision> revisions;
  final String? cursor;
  final bool hasMore;
}

enum SyncProviderFailureKind {
  unavailable,
  reconnectRequired,
  sharedSetupRequired,
  quotaExceeded,
  rateLimited,
  invalidCursor,
  corruptData,
  unsupported,
}

class SyncProviderFailure implements Exception {
  const SyncProviderFailure(this.kind, {this.retryAfter});

  final SyncProviderFailureKind kind;
  final Duration? retryAfter;

  // Never expose raw provider responses, which may contain credentials.
  @override
  String toString() => 'SyncProviderFailure(${kind.name})';
}
