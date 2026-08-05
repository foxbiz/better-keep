import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Stable identity for one committed version of a remote document.
///
/// Current documents use the server commit timestamp. Legacy bootstrap
/// documents fall back to their content timestamp until a trigger stamps them.
String remoteDocumentRevision(
  Map<String, dynamic> data,
  String remoteDocumentId,
) {
  final committedAt = data[cloudSyncCommittedAtField];
  if (committedAt is Timestamp) {
    // Pending remote pages serialize Firestore timestamps as ISO strings.
    // Normalize both forms so cache/process restoration reuses the same
    // durable content-retry budget for this revision.
    return 'commit:${committedAt.toDate().toUtc().microsecondsSinceEpoch}:'
        '$remoteDocumentId';
  }
  if (committedAt is DateTime) {
    return 'commit:${committedAt.toUtc().microsecondsSinceEpoch}:'
        '$remoteDocumentId';
  }
  if (committedAt is String) {
    final parsed = DateTime.tryParse(committedAt);
    if (parsed != null) {
      return 'commit:${parsed.toUtc().microsecondsSinceEpoch}:'
          '$remoteDocumentId';
    }
  }

  final updatedAt = data['updated_at'];
  final legacyTimestamp = updatedAt is DateTime
      ? updatedAt
      : DateTime.tryParse(updatedAt?.toString() ?? '');
  if (legacyTimestamp == null) {
    throw const FormatException(
      'Remote document needs sync_committed_at or a valid updated_at',
    );
  }
  return 'legacy:${legacyTimestamp.toUtc().microsecondsSinceEpoch}:'
      '$remoteDocumentId';
}
