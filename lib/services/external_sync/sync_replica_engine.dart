import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'sync_provider_adapter.dart';
import 'sync_replica_store.dart';
import 'sync_revision.dart';

/// Implemented by the app's encrypted payload/media codec. Object IDs are the
/// SHA-256 of encrypted bytes; identical IDs always represent identical bytes.
abstract interface class SyncReplicaContent {
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
  });

  final void Function(String connectionId)? onPublished;
  final SyncReplicaStore store;
  final SyncReplicaContent content;
  final bool Function() isCurrent;
  final Iterable<SyncProviderAdapter> Function()? availableAdapters;
  final Map<String, Future<void>> _running = {};

  Future<void> sync(SyncProviderAdapter adapter) {
    final running = _running[adapter.connectionId];
    if (running != null) return running;
    final task = _sync(adapter).whenComplete(() {
      _running.remove(adapter.connectionId);
    });
    _running[adapter.connectionId] = task;
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

  Future<void> waitForIdle() async {
    while (_running.isNotEmpty) {
      await Future.wait(
        _running.values.toList().map(
          (task) =>
              task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ),
      );
    }
  }

  Future<void> _sync(SyncProviderAdapter adapter) async {
    _guard();
    final preparing = content is PreparingSyncReplicaContent
        ? content as PreparingSyncReplicaContent
        : null;
    if (preparing != null) {
      await preparing.captureLocalChanges();
      _guard();
    }
    await _applyInbox(adapter, deferIdentityConflicts: true);
    var cursor = await store.cursor(adapter.connectionId);
    var resetCursor = false;
    while (true) {
      _guard();
      late final SyncChangePage page;
      try {
        page = await adapter.changes(cursor);
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
      await store.stagePage(adapter.connectionId, page, ensureCurrent: _guard);
      await _applyInbox(adapter, deferIdentityConflicts: true);
      cursor = page.cursor;
      if (!page.hasMore) break;
    }
    if (preparing != null) {
      await preparing.captureLocalChanges();
      _guard();
    }
    // Fetch all pages before rejecting a retained identity conflict: a valid
    // newer revision can supersede it. Unresolved conflicts still fail closed.
    // This also resolves local edits materialized during the download.
    await _applyInbox(adapter);
    (String, String)? after;
    while (true) {
      final pending = await store.pending(adapter.connectionId, after: after);
      if (pending.isEmpty) break;
      for (final revision in pending) {
        _guard();
        if (!await _isOutgoingCurrent(revision, preparing)) continue;
        for (final id in [...revision.blobIds, ?revision.payloadObjectId]) {
          final bytes = await _object(id, adapter);
          await adapter.putObject(id, bytes);
          _guard();
        }
        if (!await _isOutgoingCurrent(revision, preparing)) continue;
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
        onPublished?.call(adapter.connectionId);
      }
      after = (pending.last.kind.name, pending.last.entityId);
    }
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
    (String, String, String)? after;
    while (true) {
      final incoming = await store.inbox(adapter.connectionId, after: after);
      if (incoming.isEmpty) break;
      for (final revision in incoming) {
        _guard();
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
          continue;
        } on SyncLocalMutationPending {
          // Keep the inbox record: a later pass can compare it to the prepared
          // local winner. Other notes and destinations can continue meanwhile.
          continue;
        }
        if (applied && application?.didCommit != null) {
          await application!.didCommit!();
        }
      }
      after = (
        incoming.last.kind.name,
        incoming.last.entityId,
        incoming.last.revisionId,
      );
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
