import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';

import 'external_sync/firebase_sync_version.dart';
import 'external_sync/sync_version.dart';

/// The immutable chunks are authenticated by the manifest's ordered-ID hash.
/// Logical edit identity is separate from legacy chunk-directory names.
class NoteSortCloudManifest {
  static String contentHash(Iterable<String> ids) =>
      sha256.convert(utf8.encode(jsonEncode(ids.toList()))).toString();

  static SyncVersion version(Map<String, dynamic> data) =>
      FirebaseSyncVersion.read(
        SyncEntityKind.order,
        data['context_key'] as String,
        data,
      );

  static Map<String, dynamic> encode({
    required int schemaVersion,
    required String contextKey,
    required String sortMode,
    required String revision,
    required DateTime updatedAt,
    required int chunkCount,
    required int noteCount,
    required String contentHash,
    bool deleted = false,
  }) {
    if (deleted &&
        (sortMode != 'custom' ||
            chunkCount != 0 ||
            noteCount != 0 ||
            contentHash != NoteSortCloudManifest.contentHash(const []))) {
      throw const FormatException('Order tombstone cannot reference content');
    }
    final result = FirebaseSyncVersion.bind(
      {
        'schema_version': schemaVersion,
        'context_key': contextKey,
        'sort_mode': sortMode,
        'revision': revision,
        'chunk_count': chunkCount,
        'note_count': noteCount,
        'content_hash': contentHash,
      },
      SyncVersion(
        kind: SyncEntityKind.order,
        entityId: contextKey,
        revisionId: revision,
        modifiedAtMicros: updatedAt.microsecondsSinceEpoch,
        deleted: deleted,
      ),
    );
    // Existing Firebase clients and rules expect this field to be a Timestamp.
    result['updated_at'] = Timestamp.fromDate(updatedAt.toUtc());
    return result;
  }
}
