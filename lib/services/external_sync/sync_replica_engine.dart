import '../../models/app_progress.dart';
import '../note_sync_batch.dart';

import 'dart:typed_data';

import '../bounded_async.dart';
import 'sync_limits.dart';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'sync_provider_adapter.dart';
import 'sync_replica_store.dart';
import 'sync_revision.dart';

/// Implemented by the app's encrypted payload/media codec. Object IDs are the
/// SHA-256 of encrypted bytes; identical IDs always represent identical bytes.
abstract interface class SyncReplicaContent {
  Future<bool> contains(String objectId);
  Future<Uint8List?> read(String objectId);
  Future<void> cache(String objectId, Uint8List bytes);

  /// All referenced objects are already cached. Update notes/labels/order in
  /// this transaction, preserving the supplied revision and modification time.
  Future<void> apply(Transaction txn, SyncRevision revision);
}

/// Content implementations may prepare files/decryption outside the SQLite
/// transaction. The returned action must still check the local change journal.
abstract interface class PreparingSyncReplicaContent {
  Future<PreparedSyncApplication> prepare(SyncRevision revision);
  Future<void> captureLocalChanges();
  Future<SyncVersion?> localVersion(SyncEntityKind kind, String entityId);
}

class PreparedSyncApplication {
  const PreparedSyncApplication({required this.apply, this.didCommit});
  final Future<void> Function(Transaction) apply;
  final Future<void> Function()? didCommit;
}

/// A newer local edit is durable but its encrypted objects are still preparing.
class SyncLocalMutationPending implements Exception {
  const SyncLocalMutationPending();
}

/// Shared two-way replication; adapters contain no conflict or fan-out policy.
class SyncReplicaEngine {
  SyncReplicaEngine({
    required this.store,
    required this.content,
    required this.isCurrent,
    this.availableAdapters,
    this.onPublished,
    this.isEmptyLibrary,
    this.onProgress,
  });

  final Future<bool> Function()? isEmptyLibrary;
  final noteBatch = NoteSyncBatch();
  final void Function(String connectionId)? onPublished;
  final void Function(SyncProviderAdapter adapter, NoteTransfer? progress)?
  onProgress;
  final SyncReplicaStore store;
  final SyncReplicaContent content;
  final bool Function() isCurrent;
  final Iterable<SyncProviderAdapter> Function()? availableAdapters;
  final Map<
    String,
    ({SyncProviderAdapter adapter, bool downloadOnly, Future<void> task})
  >
  _running = {};
  final _tasks = <Future<void>>{};

  Future<void> sync(SyncProviderAdapter adapter, {bool downloadOnly = false}) {
    final running = _running[adapter.connectionId];
    if (running != null) {
      if (identical(running.adapter, adapter) &&
          running.downloadOnly == downloadOnly) {
        return running.task;
      }
      return _track(
        running.task.then(
          (_) => sync(adapter, downloadOnly: downloadOnly),
          onError: (Object _, StackTrace _) =>
              sync(adapter, downloadOnly: downloadOnly),
        ),
      );
    }
    final task = _track(
      _sync(adapter, downloadOnly: downloadOnly).whenComplete(() {
        _running.remove(adapter.connectionId);
        onProgress?.call(adapter, null);
      }),
    );
    _running[adapter.connectionId] = (
      adapter: adapter,
      downloadOnly: downloadOnly,
      task: task,
    );
    return task;
  }

  /// A failure on one connection cannot cancel another connection's work.
  Future<Map<String, Object>> syncAll(
    Iterable<SyncProviderAdapter> adapters,
  ) async {
    final failures = <String, Object>{};
    await Future.wait(
      adapters.map((adapter) async {
        try {
          await sync(adapter);
        } catch (error) {
          failures[adapter.connectionId] = error;
        }
      }),
    );
    return failures;
  }

  Future<void> _track(Future<void> operation) {
    late final Future<void> task;
    task = operation.whenComplete(() => _tasks.remove(task));
    _tasks.add(task);
    return task;
  }

  Future<void> waitForIdle() async {
    while (_tasks.isNotEmpty) {
      await Future.wait(
        _tasks.toList().map(
          (task) =>
              task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
    }
  }

  Future<void> _sync(
    SyncProviderAdapter adapter, {
    required bool downloadOnly,
  }) async {
    _guard();
    final preparing = content is PreparingSyncReplicaContent
        ? content as PreparingSyncReplicaContent
        : null;
    // Replay durable downloads first on restart. The journal comparison in
    // _applyIncoming defers newer local edits until capture finishes below.
    await _applyInbox(adapter, deferIdentityConflicts: true);
    if (preparing != null && !downloadOnly) {
      await preparing.captureLocalChanges();
      _guard();
    }
    var cursor = await store.cursor(adapter.connectionId);
    var resetCursor = false;
    var discovered = 0;
    void reportChecked(int count) {
      if (isCurrent()) {
        onProgress?.call(adapter, (
          stage: NoteTransferStage.checking,
          done: count,
          total: null,
          minutesLeft: null,
        ));
      }
    }

    reportChecked(0);
    while (true) {
      _guard();
      late final SyncChangePage page;
      try {
        page = await adapter.changes(
          cursor,
          onCheckedNotes: (count) => reportChecked(discovered + count),
        );
      } on SyncProviderFailure catch (error) {
        if (error.kind != SyncProviderFailureKind.invalidCursor ||
            resetCursor) {
          rethrow;
        }
        cursor = null;
        resetCursor = true;
        continue;
      }
      _guard();
      if (page.hasMore && page.cursor == cursor) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      // Count the whole incoming phase before applying it. Only the current
      // page is held in memory. A failed listing leaves its staged pages and
      // cursor durable for the initial inbox replay on the next attempt.
      await store.stagePage(adapter.connectionId, page, ensureCurrent: _guard);
      discovered += page.revisions
          .where((r) => r.kind == SyncEntityKind.note)
          .length;
      if (discovered > 0) reportChecked(discovered);
      cursor = page.cursor;
      if (!page.hasMore) break;
    }
    await _applyInbox(adapter, deferIdentityConflicts: true);
    if (preparing != null && !downloadOnly) {
      await preparing.captureLocalChanges();
      _guard();
    }
    // Fetch all pages before rejecting a retained identity conflict: a valid
    // newer revision can supersede it. Unresolved conflicts still fail closed.
    // This also resolves local edits materialized during the download.
    await _applyInbox(adapter);
    if (downloadOnly) return;
    final count = await store.pendingNoteCount(adapter.connectionId);
    _guard();
    await noteBatch.run(
      count,
      (meter) => _publishPending(adapter, preparing, meter),
      stage: NoteTransferStage.uploading,
      onProgress: (value) => onProgress?.call(adapter, value),
    );
  }

  Future<void> _publishPending(
    SyncProviderAdapter adapter,
    PreparingSyncReplicaContent? preparing,
    NoteTransferMeter upload,
  ) async {
    (String, String)? after;
    while (true) {
      final pending = await store.pending(adapter.connectionId, after: after);
      if (pending.isEmpty) break;
      if (pending.length > 1 &&
          adapter is BatchSyncWriter &&
          await (adapter as BatchSyncWriter).supportsBatchWrites) {
        await _publishBatchPage(adapter, pending, preparing, upload);
        after = (pending.last.kind.name, pending.last.entityId);
        continue;
      }
      // Keep this bounded by the pending page. Immutable objects shared by
      // several notes need only one successful upload to this provider per page.
      // Never retain this across runs: retries must recheck remote durability.
      final uploadedObjects = <String>{};
      for (final revision in pending) {
        _guard();
        if (!await _isOutgoingCurrent(revision, preparing)) {
          if (revision.kind == SyncEntityKind.note) upload.exclude();
          continue;
        }
        for (final id in [...revision.blobIds, ?revision.payloadObjectId]) {
          if (uploadedObjects.contains(id)) continue;
          final bytes = await _object(id, adapter);
          await adapter.putObject(id, bytes);
          _guard();
          uploadedObjects.add(id);
        }
        if (!await _isOutgoingCurrent(revision, preparing)) {
          if (revision.kind == SyncEntityKind.note) upload.exclude();
          continue;
        }
        await adapter.publish(revision);
        _guard();
        await store.database.transaction((txn) async {
          _guard();
          await store.acknowledge(txn, adapter.connectionId, revision);
          await store.queueSignal(
            txn,
            adapter.connectionId,
            revision.revisionId,
          );
          _guard();
        });
        if (revision.kind == SyncEntityKind.note) upload.advance();
        onPublished?.call(adapter.connectionId);
      }
      after = (pending.last.kind.name, pending.last.entityId);
    }
  }

  Future<void> _publishBatchPage(
    SyncProviderAdapter adapter,
    List<SyncRevision> pending,
    PreparingSyncReplicaContent? preparing,
    NoteTransferMeter upload,
  ) async {
    final writer = adapter as BatchSyncWriter;
    final objects = <String, Uint8List>{};
    final uploaded = <String>{};
    final ready = <SyncRevision>[];
    var size = 0;
    Future<void> flush() async {
      if (objects.isEmpty) return;
      _guard();
      await writer.putObjects(Map.unmodifiable(objects));
      _guard();
      uploaded.addAll(objects.keys);
      objects.clear();
      size = 0;
    }

    for (final revision in pending) {
      if (!await _isOutgoingCurrent(revision, preparing)) continue;
      for (final id in [...revision.blobIds, ?revision.payloadObjectId]) {
        if (uploaded.contains(id) || objects.containsKey(id)) continue;
        final bytes = await _object(id, adapter);
        if (size + bytes.length > SyncLimits.batchBytes ||
            objects.length >= SyncLimits.batchFiles) {
          await flush();
        }
        if (bytes.length > SyncLimits.batchBytes) {
          // Preserve the existing serial/chunked path for large attachments.
          await adapter.putObject(id, bytes);
          _guard();
          uploaded.add(id);
        } else {
          objects[id] = bytes;
          size += bytes.length;
        }
      }
      ready.add(revision);
    }
    await flush();
    final current = <SyncRevision>[];
    for (final revision in ready) {
      if (await _isOutgoingCurrent(revision, preparing)) current.add(revision);
    }
    final skipped =
        pending.where((r) => r.kind == SyncEntityKind.note).length -
        current.where((r) => r.kind == SyncEntityKind.note).length;
    if (skipped > 0) upload.exclude(skipped);
    if (current.isEmpty) return;
    _guard();
    await writer.publishBatch(current);
    _guard();
    // A partial/lost batch response leaves every revision pending for verified
    // immutable retry. Never infer remote durability from upload-session start.
    await store.database.transaction((txn) async {
      for (final revision in current) {
        _guard();
        await store.acknowledge(txn, adapter.connectionId, revision);
      }
      await store.queueSignal(
        txn,
        adapter.connectionId,
        current.last.revisionId,
      );
      _guard();
    });
    for (final revision in current) {
      if (revision.kind == SyncEntityKind.note) upload.advance();
    }
    onPublished?.call(adapter.connectionId);
  }

  Future<bool> _isOutgoingCurrent(
    SyncRevision revision,
    PreparingSyncReplicaContent? preparing,
  ) async {
    final current = await store.current(
      store.database,
      revision.kind,
      revision.entityId,
    );
    final local = await preparing?.localVersion(
      revision.kind,
      revision.entityId,
    );
    _guard();
    return current?.revisionId == revision.revisionId &&
        (local == null || local.compareTo(revision) <= 0);
  }

  Future<void> _applyInbox(
    SyncProviderAdapter adapter, {
    bool deferIdentityConflicts = false,
  }) async {
    final count = await store.incomingNoteCount(adapter.connectionId);
    _guard();
    await noteBatch.run(
      count,
      (meter) => _applyIncoming(adapter, deferIdentityConflicts, meter),
      isEmptyLibrary: isEmptyLibrary,
      onProgress: (value) => onProgress?.call(adapter, value),
    );
  }

  Future<void> _applyIncoming(
    SyncProviderAdapter adapter,
    bool deferIdentityConflicts,
    NoteTransferMeter meter,
  ) async {
    (String, String, String)? after;
    while (true) {
      // Commit the first network batch promptly, including after a restart.
      // Later pages retain the normal bulk prefetch throughput.
      final incoming = await store.inbox(
        adapter.connectionId,
        after: after,
        limit: after == null ? 16 : 100,
      );
      if (incoming.isEmpty) break;
      await _prefetchSmallObjects(adapter, incoming);
      for (final revision in incoming) {
        _guard();
        final countsAsDownload =
            revision.kind == SyncEntityKind.note && !revision.deleted;
        final before = await store.current(
          store.database,
          revision.kind,
          revision.entityId,
        );
        final preparing = content is PreparingSyncReplicaContent
            ? content as PreparingSyncReplicaContent
            : null;
        final local = await preparing?.localVersion(
          revision.kind,
          revision.entityId,
        );
        _guard();
        if (local != null &&
            local.compareTo(revision) > 0 &&
            (before == null || local.compareTo(before) > 0)) {
          // The newer edit is not encrypted yet. Do not download obsolete media
          // (which may no longer exist) or allow it to block the winning upload.
          if (countsAsDownload) meter.exclude();
          continue;
        }
        if (before == null || revision.compareTo(before) > 0) {
          for (final id in [...revision.blobIds, ?revision.payloadObjectId]) {
            await _object(id, adapter);
          }
        }
        final application =
            (before == null || revision.compareTo(before) > 0) &&
                preparing != null
            ? await preparing.prepare(revision)
            : null;
        var applied = false;
        try {
          await store.database.transaction((txn) async {
            _guard();
            if (await store.accept(txn, revision)) {
              if (application != null) {
                await application.apply(txn);
              } else {
                await content.apply(txn, revision);
              }
              applied = true;
            }
            await store.acknowledge(txn, adapter.connectionId, revision);
            await store.removeIncoming(txn, adapter.connectionId, revision);
            _guard();
          });
        } on SyncRevisionIdentityConflict {
          if (!deferIdentityConflicts) rethrow;
          // The transaction rolled back. Keep this entry for the strict final
          // pass; never apply or acknowledge its conflicting content.
          if (countsAsDownload) meter.exclude();
          continue;
        } on SyncLocalMutationPending {
          // Keep the inbox record: a later pass can compare it to the prepared
          // local winner. Other notes and destinations can continue meanwhile.
          if (countsAsDownload) meter.exclude();
          continue;
        }
        if (applied && application?.didCommit != null) {
          await application!.didCommit!();
        }
        if (countsAsDownload) {
          if (applied) {
            meter.advance();
          } else {
            meter.exclude();
          }
        }
      }
      after = (
        incoming.last.kind.name,
        incoming.last.entityId,
        incoming.last.revisionId,
      );
    }
  }

  Future<void> _prefetchSmallObjects(
    SyncProviderAdapter adapter,
    List<SyncRevision> incoming,
  ) async {
    if (adapter is! SmallSyncObjectReader) return;
    final reader = adapter as SmallSyncObjectReader;
    if (!await reader.supportsSmallReads) return;
    _guard();
    final preparing = content is PreparingSyncReplicaContent
        ? content as PreparingSyncReplicaContent
        : null;
    final candidates = <String>{};
    for (final revision in incoming) {
      final current = await store.current(
        store.database,
        revision.kind,
        revision.entityId,
      );
      final local = await preparing?.localVersion(
        revision.kind,
        revision.entityId,
      );
      _guard();
      if ((current != null && revision.compareTo(current) <= 0) ||
          (local != null && local.compareTo(revision) > 0)) {
        continue;
      }
      candidates.addAll([...revision.blobIds, ?revision.payloadObjectId]);
    }
    final missing = <String>[];
    // Existence is only a prefetch hint; _object still verifies cached bytes.
    for (final id in candidates) {
      if (!await content.contains(id)) missing.add(id);
      _guard();
    }
    ({Object error, StackTrace stack})? cacheFailure;
    try {
      await forEachBounded(missing, (id) async {
        _guard();
        final bytes = await reader.readSmallObject(id);
        _guard();
        if (bytes == null) return;
        if (bytes.length > SyncLimits.prefetchBytes) {
          throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
        }
        _verify(id, bytes);
        try {
          await content.cache(id, bytes);
        } catch (error, stack) {
          cacheFailure ??= (error: error, stack: stack);
          rethrow;
        }
        _guard();
      }, concurrency: 8);
    } catch (_) {
      _guard();
      final failure = cacheFailure;
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      // Network prefetch failures fall back to verified serial reads.
    }
  }

  void _guard() {
    if (!isCurrent()) throw const SyncReplicaCancelled();
  }

  Future<Uint8List> _object(String id, SyncProviderAdapter preferred) async {
    _guard();
    final cached = await content.read(id);
    _guard();
    if (cached != null) {
      _verify(id, cached);
      return cached;
    }
    // Provider storage is immutable and IDs authenticate ciphertext. A cache
    // eviction must not strand a revision already retained on another provider.
    final tried = <String>{};
    SyncProviderFailure? failure;
    for (final adapter in [preferred, ...?availableAdapters?.call()]) {
      if (!tried.add(adapter.connectionId)) continue;
      _guard();
      late Uint8List bytes;
      try {
        bytes = await adapter.readObject(id);
        _guard();
        _verify(id, bytes);
      } on SyncReplicaCancelled {
        rethrow;
      } catch (error) {
        _guard();
        failure ??= error is SyncProviderFailure
            ? error
            : const SyncProviderFailure(SyncProviderFailureKind.unavailable);
        continue;
      }
      await content.cache(id, bytes);
      _guard();
      return bytes;
    }
    throw failure ??
        const SyncProviderFailure(SyncProviderFailureKind.unavailable);
  }

  static void _verify(String id, Uint8List bytes) {
    if (sha256.convert(bytes).toString() != id) {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
  }
}

class SyncReplicaCancelled implements Exception {
  const SyncReplicaCancelled();
}
