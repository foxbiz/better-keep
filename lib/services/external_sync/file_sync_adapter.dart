import 'sync_limits.dart';
import '../bounded_async.dart';
import '../async_keyed_serializer.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_cipher.dart';
import 'sync_provider_adapter.dart';
import 'sync_revision.dart';

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

class SyncFilePage {
  const SyncFilePage({
    required this.names,
    required this.cursor,
    required this.hasMore,
  });
  final List<String> names;
  final String? cursor;
  final bool hasMore;
}

/// Reusable encrypted file protocol for Drive, Dropbox and WebDAV transports.
class FileSyncAdapter
    implements SyncProviderAdapter, SmallSyncObjectReader, BatchSyncWriter {
  FileSyncAdapter({
    required this.connectionId,
    required this.transport,
    required this.cipher,
    this.normalizeLegacyRevision,
  });

  @override
  final String connectionId;
  final SyncFileTransport transport;
  final SyncCipher cipher;
  final _legacyNormalization = AsyncKeyedSerializer<bool>();
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
  Future<SyncChangePage> changes(String? cursor) async {
    final page = await transport.list(cursor);
    final names = page.names
        .toSet()
        .where((name) => RegExp(r'^c-[0-9a-f]{64}\.json$').hasMatch(name))
        .toList();
    final revisions = List<SyncRevision?>.filled(names.length, null);
    // Commits are small, size-bounded metadata. Read them concurrently while
    // preserving page order and draining all work before a failed page returns.
    await forEachBounded(Iterable.generate(names.length), (index) async {
      revisions[index] = await _readCommit(names[index]);
    }, concurrency: 8);
    return SyncChangePage(
      revisions: revisions.cast<SyncRevision>(),
      cursor: page.cursor,
      hasMore: page.hasMore,
    );
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

  Future<SyncRevision> _readCommit(String name) async {
    SyncRevision? first;
    for (final bytes in await _copies(name)) {
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
      if (normalize != null &&
          !revision.deleted &&
          revision.contentFingerprint != null &&
          revision.legacyContentFingerprints.isEmpty) {
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
