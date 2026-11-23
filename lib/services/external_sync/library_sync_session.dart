import '../../models/app_progress.dart';
import '../../models/note.dart';

import 'package:flutter/foundation.dart';

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../cloud_operation.dart';
import '../file_system_base.dart';
import 'library_replica_content.dart';
import 'portable_sync_codec.dart';
import 'storage_connection_controller.dart';
import 'sync_attachment_store.dart';
import 'sync_cipher.dart';
import 'sync_object_cache.dart';
import 'sync_mutation_journal.dart';
import 'sync_replica_engine.dart';
import 'sync_replica_store.dart';
import 'sync_scheduler.dart';
import 'sync_provider_adapter.dart';
import 'sync_status_store.dart';
import 'sync_change_signals.dart';

/// Owns every resource for one account, database and encryption-key generation.
/// Invalidation is synchronous; draining must finish before local data removal.
class LibrarySyncSession extends ChangeNotifier {
  LibrarySyncSession({
    required String uid,
    required Database database,
    required FileSystem files,
    required String documentRoot,
    required String cacheRoot,
    required this.cipher,
    required this._isCurrent,
    required StorageConnectionController Function(bool Function() isCurrent)
    createConnections,
    Future<void> Function(SyncAppliedChange change)? onApplied,
    SyncAttachmentReader Function(
      SyncAttachmentReader readLocal,
      bool Function() isCurrent,
    )?
    createAttachmentReader,
    bool foreground = true,
    bool automatic = true,
    SyncChangeSignals Function(SyncReplicaStore, void Function(String))?
    createSignals,
  }) : _foreground = foreground,
       _automatic = automatic {
    final scope = '$uid:${cipher.libraryId}';
    final store = SyncReplicaStore(database, scope: scope);
    status = SyncStatusStore(
      database: database,
      scope: scope,
      isCurrent: _current,
      onChanged: _progressChanged,
    );
    objects = SyncObjectCache(
      database: database,
      files: files,
      root: p.join(documentRoot, 'external_sync'),
      scope: scope,
      cipher: cipher,
    );
    attachments = SyncAttachmentStore(
      database: database,
      files: files,
      scope: scope,
      root: p.join(documentRoot, 'external_sync_media', cipher.libraryId),
      allowedSourceRoots: [documentRoot, cacheRoot],
      isCurrent: _current,
    );
    content = LibraryReplicaContent(
      store: store,
      objects: objects,
      codec: PortableSyncCodec(
        cache: objects,
        readAttachment:
            createAttachmentReader?.call(attachments.read, _current) ??
            attachments.read,
        writeAttachment: attachments.materialize,
      ),
      isCurrent: _current,
      onApplied: (change) async {
        if (!_current()) throw const SyncReplicaCancelled();
        await onApplied?.call(change);
        // Received revisions are already acknowledged by the engine. Local
        // edits made during this pass are detected by the journal below.
      },
    );
    final publications = <String, int>{};
    engine = SyncReplicaEngine(
      store: store,
      content: content,
      isCurrent: _current,
      availableAdapters: () => connections.adapters,
      isEmptyLibrary: () => Note.libraryIsEmpty(database),
      onProgress: (adapter, value) {
        if (!_current()) return;
        // Keep the last transfer visible until the scheduler has finished its
        // durability checks. Clearing it at engine return flashes "Syncing...".
        transfers[adapter.connectionId] = value;
        _progressChanged();
      },
      onPublished: (id) {
        publications[id] = (publications[id] ?? 0) + 1;
        signals?.published(id);
      },
    );
    connections = createConnections(_current);
    Future<void> run(
      SyncProviderAdapter adapter, {
      bool downloadOnly = false,
    }) => runCloudOperation(_current, () async {
      // A session can outlive the startup/recovery operation that created it.
      // Nested local writes must use this library's account/key/database guard.
      final capturedBefore = content.capturedRevisions;
      final publishedBefore = publications[adapter.connectionId] ?? 0;
      await engine.sync(adapter, downloadOnly: downloadOnly);
      if (!_current()) throw const SyncReplicaCancelled();
      final pending = await content.pendingUploadState(adapter.connectionId);
      if (!_current()) throw const SyncReplicaCancelled();
      _pendingLocalChanges = pending.pending;
      _runnableLocalChanges = pending.runnable;
      if (!downloadOnly && pending.runnable) {
        scheduler.continueUpload(
          adapter.connectionId,
          madeProgress:
              content.capturedRevisions != capturedBefore ||
              (publications[adapter.connectionId] ?? 0) != publishedBefore,
        );
      }
    });

    scheduler = SyncScheduler(
      sync: run,
      onPassStarted: (adapter) => transfers.remove(adapter.connectionId),
      restore: (adapter) => run(adapter, downloadOnly: true),
      isCurrent: _current,
      blockedEntities: () => content.captureFailures.length,
      notesRequiringUnlock: () => content.notesRequiringUnlock,
      pendingLocalChanges: () => _pendingLocalChanges,
      hasRunnableUpload: () => _runnableLocalChanges,
      hasSourceReadFailures: () => content.hasSourceReadFailures,
      loadLastSuccess: status.read,
      saveLastSuccess: status.save,
      loadPendingUpload: status.hasPendingUpload,
      savePendingUpload: status.setPendingUpload,
      foreground: foreground,
      automatic: automatic,
    );
    signals = createSignals?.call(store, scheduler.remoteChanged);
    connections.addListener(_connectionsChanged);
    scheduler.addListener(_schedulerProgressChanged);
    _connectionsChanged();
    unawaited(status.load().catchError((Object _) {}));
  }

  final transfers = <String, NoteTransfer>{};
  SyncChangeSignals? signals;
  bool _foreground, _automatic;
  bool _runnableLocalChanges = false;
  final SyncCipher cipher;
  final bool Function() _isCurrent;
  late final SyncObjectCache objects;
  late final SyncAttachmentStore attachments;
  late final LibraryReplicaContent content;
  late final SyncReplicaEngine engine;
  late final StorageConnectionController connections;
  late final SyncScheduler scheduler;
  late final SyncStatusStore status;
  bool _retired = false;
  bool _disposed = false;
  bool _pendingLocalChanges = false;
  Future<void>? _closing;
  final _changeChecks = <Future<void>>{};

  bool _current() => !_retired && _isCurrent();
  bool get isCurrent => _current();

  void _connectionsChanged() {
    if (!_current()) return;
    scheduler.setAdapters(connections.adapters);
    _updateSignals();
    notifyListeners();
  }

  void _schedulerProgressChanged() {
    final progress = scheduler.progress;
    transfers.removeWhere((id, _) => progress[id]?.running != true);
    _progressChanged();
  }

  void _progressChanged() {
    if (_current()) notifyListeners();
  }

  void localChanged() => scheduler.localChanged();

  // Remote/UI refreshes are not edits. Only durable uncaptured revisions need
  // another pass (including Firebase changes during a provider switch).
  void persistedChanged() {
    if (!_current()) return;
    late final Future<void> task;
    task =
        (() async {
              final pending = await SyncMutationJournal.pending(
                content.store.database,
                content.store.scope,
                limit: 1,
              );
              if (_current() && pending.isNotEmpty) scheduler.localChanged();
            })()
            .catchError((Object _) {
              // Resume/manual sync rechecks the journal if a local read is unavailable.
            })
            .whenComplete(() => _changeChecks.remove(task));
    _changeChecks.add(task);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    scheduler.setForeground(foreground);
    _updateSignals();
  }

  void setAutomatic(bool enabled) {
    _automatic = enabled;
    scheduler.setAutomatic(enabled);
    _updateSignals();
  }

  void _updateSignals() {
    final active = connections.adapters.map((a) => a.connectionId).toSet();
    signals?.setConnections(
      _automatic && _foreground
          ? connections.connections.values.where(
              (c) => active.contains(c.replicaId),
            )
          : const [],
    );
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    engine.noteBatch.reset();
    connections.removeListener(_connectionsChanged);
    scheduler.removeListener(_schedulerProgressChanged);
    signals?.dispose();
    connections.dispose();
    scheduler.dispose();
    cipher.dispose();
  }

  Future<void> close({bool pruneCache = true}) {
    retire();
    return _closing ??= _drain(pruneCache);
  }

  Future<void> _drain(bool pruneCache) async {
    try {
      await Future.wait(_changeChecks.toList());
      await scheduler.waitForIdle();
      await engine.waitForIdle();
      await signals?.waitForIdle();
      await attachments.waitForIdle();
      await objects.waitForIdle();
      await status.waitForIdle();
      try {
        if (pruneCache) await objects.pruneUnreferenced();
      } catch (_) {
        // Optional maintenance must not prevent account replacement or recovery.
        // A malformed reference fails closed, before any cached object is removed.
      }
    } finally {
      dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    retire();
    _disposed = true;
    super.dispose();
  }
}
