import 'sync_limits.dart';
import '../bounded_async.dart';
import '../async_keyed_serializer.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../utils/logger.dart';

import 'provider_http.dart';
import 'sync_cipher.dart';
import 'sync_provider_adapter.dart';
import 'sync_revision.dart';
import 'sync_metadata_index.dart';

/// Transport is already bound to one account/library directory. Names are
/// opaque single path segments; adapters must not follow authenticated redirects.
abstract interface class SyncFileTransport {
  Future<SyncFilePage> list(String? cursor);
  Future<Uint8List> read(String name);

  /// Returns false when a file already exists; never overwrites it.
  Future<bool> create(String name, Uint8List bytes);
}

/// Must enforce the small-read limit while receiving, before buffering a body.
abstract interface class SmallSyncFileReader {
  Future<Uint8List?> readSmall(String name);
}

abstract interface class BatchSyncFileWriter {
  /// Values indicate creation (true) or an existing file (false).
  Future<Map<String, bool>> createBatch(Map<String, Uint8List> files);
}

/// Version receipts from successful creates, never from a later metadata probe.
/// Optional: servers without trustworthy write receipts retain scan/read fallback.
mixin SyncFileWriteReceipts {
  final _createdVersions = <String, List<String>>{};

  void clearWriteReceipt(String name) => _createdVersions.remove(name);

  void recordWriteReceipt(String name, String? version) {
    if (!RegExp(r'^c-[0-9a-f]{64}\.json$').hasMatch(name) ||
        version == null ||
        version.isEmpty ||
        version.length > 1024) {
      return;
    }
    // Only commit receipts survive; failed/partial batches cannot grow this map.
    if (_createdVersions.length >= 128) {
      _createdVersions.remove(_createdVersions.keys.first);
    }
    _createdVersions[name] = [version];
  }

  List<String>? takeWriteReceipt(String name) => _createdVersions.remove(name);
}

class SmallSyncReadLimitExceeded implements Exception {
  const SmallSyncReadLimitExceeded();
}

/// Optional capability for stores such as Drive that permit duplicate names.
/// Every copy must authenticate and describe the same immutable content.
abstract interface class SyncFileCopies {
  Future<List<Uint8List>> readCopies(String name);
}

/// Explicitly authorized whole-library cleanup, never used by normal sync.
abstract interface class SyncFileCleanup {
  Future<void> clearLibrary();
}

/// Optional, replaceable metadata cache. It never replaces listing or commits.
abstract interface class SyncIndexFileTransport {
  Future<Uint8List?> readIndex({String name = SyncMetadataIndex.fileName});
  Future<void> writeIndex(
    Uint8List bytes, {
    String name = SyncMetadataIndex.fileName,
  });
}

/// Providers with duplicate names can try another bounded candidate when the
/// codec rejects a cache page. Validation stays with the authenticated codec.
abstract interface class SyncValidatedIndexFileTransport {
  /// Invoke [validate] on the exact candidate before returning it. Propagate or
  /// handle its synchronous rejection before this future completes; do not
  /// retain the callback or mutate the candidate after validation.
  Future<Uint8List?> readValidatedIndex(
    String name,
    void Function(Uint8List bytes) validate,
  );
}

class SyncFilePage {
  const SyncFilePage({
    required this.names,
    required this.cursor,
    required this.hasMore,
    this.maxParallelCommitReads = 8,
    this.commitVersions = const {},
  }) : assert(maxParallelCommitReads > 0);
  final List<String> names;
  final String? cursor;
  final bool hasMore;

  /// Current provider-controlled version tokens for each listed commit copy.
  /// Missing tokens disable index reuse for that entry.
  final Map<String, List<String>> commitVersions;

  /// Bounds metadata buffers independently of note and media downloads.
  final int maxParallelCommitReads;
}

/// Reusable encrypted file protocol for Drive, Dropbox and WebDAV transports.
class FileSyncAdapter
    implements
        SyncProviderAdapter,
        SmallSyncObjectReader,
        BatchSyncWriter,
        SyncIndexMaintenance {
  FileSyncAdapter({
    required this.connectionId,
    required this.transport,
    required this.cipher,
    this.normalizeLegacyRevision,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  @override
  final String connectionId;
  final SyncFileTransport transport;
  final SyncCipher cipher;
  final _legacyNormalization = AsyncKeyedSerializer<bool>();
  SyncMetadataIndex? _index;
  bool _indexAttempted = false;
  bool _canWriteIndex = false;
  Set<String>? _unseenIndexNames;
  String? _scanCursor;
  bool _scanComplete = false;
  Future<void>? _indexLoading;
  Stopwatch? _scanClock;
  int _cacheHits = 0, _commitReads = 0;
  final DateTime Function() _now;
  DateTime? _indexRetryAfter;
  final _reportedIndexFailures = <String>{};
  final _lastDiagnostic = <String, DateTime>{};
  final Future<SyncRevision> Function(
    SyncRevision revision,
    Future<Uint8List> Function(String) readObject,
  )?
  normalizeLegacyRevision;

  static String commitName(SyncRevision revision) =>
      'c-${sha256.convert(utf8.encode(jsonEncode([revision.kind.name, revision.entityId, revision.revisionId])))}.json';

  static String objectName(String id) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
      throw const FormatException('Invalid object digest');
    }
    return 'o-$id';
  }

  @override
  Future<SyncChangePage> changes(
    String? cursor, {
    void Function(int count)? onCheckedNotes,
  }) async {
    try {
      return await _changes(cursor, onCheckedNotes: onCheckedNotes);
    } catch (_) {
      // A resumed attempt excludes the failed page and time spent paused.
      _scanClock = null;
      _cacheHits = _commitReads = 0;
      rethrow;
    }
  }

  Future<SyncChangePage> _changes(
    String? cursor, {
    void Function(int count)? onCheckedNotes,
  }) async {
    if (cursor == null || _scanClock == null) {
      _scanClock = Stopwatch()..start();
      _cacheHits = _commitReads = 0;
    }
    if (cursor == null) {
      _unseenIndexNames = _index?.names;
      _scanComplete = false;
      _scanCursor = null;
    } else if (!_scanComplete && cursor != _scanCursor) {
      // A resumed/skipped scan is not a complete inventory for pruning.
      _unseenIndexNames = null;
    }
    final page = await transport.list(cursor);
    final names = page.names
        .toSet()
        .where((name) => RegExp(r'^c-[0-9a-f]{64}\.json$').hasMatch(name))
        .toList();
    // Recheck a clean cache on an explicit full scan so removed/corrupt remote
    // pages can be rebuilt in this session. Keep dirty/interrupted snapshots;
    // incremental polling never adds these reads.
    final reloadIndex = cursor == null && _index?.dirty == false;
    if ((!_indexAttempted || reloadIndex) &&
        (cursor == null || names.isNotEmpty)) {
      await _loadIndex(reloadIndex: reloadIndex);
      if (cursor == null) _unseenIndexNames = _index?.names;
    }
    var checkedNotes = 0;
    final revisions = List<SyncRevision?>.filled(names.length, null);
    // Commits are small, size-bounded metadata. Read them concurrently while
    // preserving page order and draining all work before a failed page returns.
    await forEachBounded(Iterable.generate(names.length), (index) async {
      final name = names[index];
      final versions = page.commitVersions[name];
      final cached = _index?.lookup(name, versions);
      var cacheable = true;
      final hit = cached != null && commitName(cached) == name;
      if (hit) {
        _cacheHits++;
      } else {
        _commitReads++;
      }
      final revision = hit
          ? cached
          : await _readCommit(name, onMultipleCopies: () => cacheable = false);
      if (cacheable) {
        _index?.remember(name, versions, revision);
      } else {
        // Equivalent duplicate commits may name different encrypted objects.
        // Keep resolving the remaining copies if one is later removed.
        _index?.forget(name);
      }
      revisions[index] = revision;
      if (revision.kind == SyncEntityKind.note) {
        checkedNotes++;
        if (checkedNotes == 1 || checkedNotes % 8 == 0) {
          onCheckedNotes?.call(checkedNotes);
        }
      }
    }, concurrency: page.maxParallelCommitReads);
    _unseenIndexNames?.removeAll(names);
    _scanCursor = page.cursor;
    if (_unseenIndexNames != null && !page.hasMore) {
      _scanComplete = true;
      _canWriteIndex = true;
    }
    if (!page.hasMore) {
      if (_cacheHits + _commitReads > 0) {
        _logDiagnostic(
          'scan',
          '[EXTERNAL_SYNC] Metadata check: '
              'cached=$_cacheHits fetched=$_commitReads '
              'elapsedMs=${_scanClock?.elapsedMilliseconds ?? 0}',
        );
      }
      _scanClock = null;
    }
    return SyncChangePage(
      revisions: revisions.cast<SyncRevision>(),
      cursor: page.cursor,
      hasMore: page.hasMore,
    );
  }

  Future<void> _loadIndex({bool reloadIndex = false, Duration? timeout}) =>
      _indexLoading ??= _readIndex(reloadIndex: reloadIndex, timeout: timeout)
          .whenComplete(() {
            _indexLoading = null;
          });

  Future<void> _readIndex({
    required bool reloadIndex,
    Duration? timeout,
  }) async {
    _indexAttempted = true;
    if (transport is SyncIndexFileTransport) {
      var index = SyncMetadataIndex(cipher, connectionId);
      _canWriteIndex = false;
      try {
        Future<bool> load() => index.loadChain(
          (name) => (transport as SyncIndexFileTransport).readIndex(name: name),
          readValidated: transport is SyncValidatedIndexFileTransport
              ? (transport as SyncValidatedIndexFileTransport)
                    .readValidatedIndex
              : null,
        );
        _canWriteIndex = timeout == null
            ? await load()
            : await ProviderHttp.withOperationTimeout(timeout, load);
      } catch (error) {
        // A timed-out reader may finish later; never expose its mutable cache.
        index = SyncMetadataIndex(cipher, connectionId);
        _reportIndexFailure('read', error);
      }
      if (!_canWriteIndex && reloadIndex) {
        // The failed remote load never exposed partial data. Keep the last
        // authenticated metadata, still checked against current inventory and
        // versions, but require all pages to be rewritten after a full scan.
        index = _index!;
        index.invalidateRemotePages();
      }
      _index = index;
    }
  }

  @override
  Future<void> maintainIndex() async {
    if (!_canWriteIndex || (_indexRetryAfter?.isAfter(_now()) ?? false)) return;
    try {
      final index = _index;
      if (index == null) return;
      // Called only after the engine validates incoming and outgoing work.
      if (_scanComplete) {
        for (final name in _unseenIndexNames ?? const <String>{}) {
          index.forget(name);
        }
        _unseenIndexNames = null;
        _scanComplete = false;
      }
      final dirty = index.dirty;
      final clock = Stopwatch()..start();
      await index.upload((name, bytes) async {
        final remaining = SyncMetadataIndex.writeTimeout - clock.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Index maintenance budget exhausted');
        }
        await ProviderHttp.withOperationTimeout(
          remaining,
          () => (transport as SyncIndexFileTransport).writeIndex(
            bytes,
            name: name,
          ),
        );
      });
      _indexRetryAfter = null;
      if (dirty) {
        _logDiagnostic(
          'write',
          '[EXTERNAL_SYNC] Metadata index saved: '
              'entries=${index.names.length} elapsedMs=${clock.elapsedMilliseconds}',
        );
      }
    } catch (error) {
      // Cache failures, including programming errors, cannot fail durable sync.
      // Report the type once per operation without payloads or credentials.
      _reportIndexFailure('write', error);
      _indexRetryAfter = _now().add(const Duration(minutes: 5));
    }
  }

  void _logDiagnostic(String category, String message) {
    final now = _now();
    final previous = _lastDiagnostic[category];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      return;
    }
    _lastDiagnostic[category] = now;
    unawaited(AppLogger.log(message));
  }

  void _reportIndexFailure(String operation, Object error) {
    if (_reportedIndexFailures.add(operation)) {
      unawaited(
        AppLogger.log(
          '[EXTERNAL_SYNC] Metadata index $operation skipped (${error.runtimeType})',
        ),
      );
    }
  }

  @override
  Future<bool> get supportsSmallReads async => transport is SmallSyncFileReader;

  @override
  Future<Uint8List?> readSmallObject(String objectId) async {
    final files = transport;
    if (files is! SmallSyncFileReader) return null;
    final bytes = await (files as SmallSyncFileReader).readSmall(
      objectName(objectId),
    );
    if (bytes != null) {
      if (bytes.length > SyncLimits.prefetchBytes) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      _verify(objectId, bytes);
    }
    return bytes;
  }

  @override
  Future<Uint8List> readObject(String objectId) async {
    final copies = await _copies(objectName(objectId));
    for (final bytes in copies) {
      if (bytes.length > SyncLimits.objectBytes) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      _verify(objectId, bytes);
    }
    return copies.first;
  }

  @override
  Future<void> putObject(String objectId, Uint8List encryptedBytes) async {
    if (encryptedBytes.length > SyncLimits.objectBytes) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    _verify(objectId, encryptedBytes);
    final name = objectName(objectId);
    if (!await transport.create(name, encryptedBytes)) {
      await readObject(objectId);
    }
  }

  @override
  Future<void> publish(SyncRevision revision) async {
    final name = commitName(revision);
    final encoded = await cipher.encodeCommit(revision);
    if (encoded.length > SyncLimits.commitBytes) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    if (!await transport.create(name, encoded)) {
      // Retries can encrypt the same commit with a different random nonce.
      final existing = await _readCommit(name);
      if (!existing.sameContent(revision)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
    } else {
      await _rememberPublished(revision);
    }
  }

  Future<void> _rememberPublished(SyncRevision revision) async {
    try {
      final files = transport;
      if (files is! SyncFileWriteReceipts) return;
      final name = commitName(revision);
      final versions = (files as SyncFileWriteReceipts).takeWriteReceipt(name);
      if (versions == null) return;
      // Old commits need the normal payload-based fingerprint migration before
      // they can enter the cache, even if this upload returned a fresh version.
      if (normalizeLegacyRevision != null &&
          _needsLegacyFingerprint(revision)) {
        return;
      }
      // A restarted session may have an empty incremental listing before its
      // first upload. Load the existing cache lazily, never on idle polling.
      if (!_indexAttempted || _indexLoading != null) {
        await _loadIndex(timeout: SyncMetadataIndex.writeTimeout);
      }
      _index?.remember(name, versions, revision);
      _unseenIndexNames?.remove(name);
    } catch (error) {
      // Optional cache work must never fail an acknowledged upload.
      _reportIndexFailure('seed', error);
    }
  }

  @override
  Future<bool> get supportsBatchWrites async =>
      transport is BatchSyncFileWriter;

  @override
  Future<void> putObjects(Map<String, Uint8List> objects) async {
    final files = <String, Uint8List>{};
    for (final entry in objects.entries) {
      _verify(entry.key, entry.value);
      files[objectName(entry.key)] = entry.value;
    }
    final created = await _createBatch(files);
    for (final id in objects.keys) {
      if (!created[objectName(id)]!) await readObject(id);
    }
  }

  @override
  Future<void> publishBatch(List<SyncRevision> revisions) async {
    final files = <String, Uint8List>{};
    final pending = <SyncRevision>[];
    var size = 0;
    Future<void> flush() async {
      if (files.isEmpty) return;
      final created = await _createBatch(files);
      for (final revision in pending) {
        if (created[commitName(revision)]!) {
          await _rememberPublished(revision);
        }
        if (!created[commitName(revision)]! &&
            !(await _readCommit(commitName(revision))).sameContent(revision)) {
          throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
        }
      }
      files.clear();
      pending.clear();
      size = 0;
    }

    for (final revision in revisions) {
      final bytes = await cipher.encodeCommit(revision);
      if (bytes.length > SyncLimits.commitBytes) {
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
      }
      if (files.length >= SyncLimits.batchFiles ||
          size + bytes.length > SyncLimits.batchBytes) {
        await flush();
      }
      final name = commitName(revision);
      if (files.containsKey(name)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      files[name] = bytes;
      pending.add(revision);
      size += bytes.length;
    }
    await flush();
  }

  Future<Map<String, bool>> _createBatch(Map<String, Uint8List> files) async {
    if (files.isEmpty) return {};
    if (files.length > SyncLimits.batchFiles ||
        files.values.fold<int>(0, (size, bytes) => size + bytes.length) >
            SyncLimits.batchBytes) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    final writer = transport;
    if (writer is! BatchSyncFileWriter) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    final result = await (writer as BatchSyncFileWriter).createBatch(files);
    if (result.length != files.length ||
        !files.keys.every(result.containsKey)) {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
    return result;
  }

  Future<List<Uint8List>> _copies(String name) async {
    final files = transport;
    final copies = files is SyncFileCopies
        ? await (files as SyncFileCopies).readCopies(name)
        : [await files.read(name)];
    if (copies.isEmpty) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    return copies;
  }

  static bool _needsLegacyFingerprint(SyncRevision revision) =>
      !revision.deleted &&
      revision.contentFingerprint != null &&
      revision.legacyContentFingerprints.isEmpty;

  Future<SyncRevision> _readCommit(
    String name, {
    void Function()? onMultipleCopies,
  }) async {
    SyncRevision? first;
    final copies = await _copies(name);
    if (copies.length > 1) onMultipleCopies?.call();
    for (final bytes in copies) {
      late SyncRevision revision;
      try {
        revision = await cipher.decodeCommit(bytes);
      } on StateError {
        rethrow; // A retired cipher is cancellation, not corrupt provider data.
      } catch (_) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      if (commitName(revision) != name) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      final normalize = normalizeLegacyRevision;
      if (normalize != null && _needsLegacyFingerprint(revision)) {
        try {
          // Legacy normalization can fetch a large payload. Only metadata reads
          // run concurrently; keep full-payload buffering bounded to one here.
          final value = revision;
          revision = await _legacyNormalization.run(
            true,
            () => normalize(value, readObject),
          );
        } on FormatException {
          throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
        }
      }
      if (first != null && !first.sameContent(revision)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      first = revision;
    }
    return first!;
  }

  static void _verify(String id, Uint8List bytes) {
    if (sha256.convert(bytes).toString() != id) {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
  }
}
