import 'sync_limits.dart';

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
class FileSyncAdapter implements SyncProviderAdapter {
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
    final revisions = <SyncRevision>[];
    for (final name in page.names.toSet()) {
      if (!RegExp(r'^c-[0-9a-f]{64}\.json$').hasMatch(name)) continue;
      final revision = await _readCommit(name);
      revisions.add(revision);
    }
    return SyncChangePage(
      revisions: revisions,
      cursor: page.cursor,
      hasMore: page.hasMore,
    );
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
          revision = await normalize(revision, readObject);
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
