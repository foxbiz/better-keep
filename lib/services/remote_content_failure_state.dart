import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';

Set<int> combinedRemoteSyncFailureIds({
  required Set<int> transientFailures,
  required Iterable<RemoteContentRetryEntry> contentFailures,
}) => {...transientFailures, ...contentFailures.map((entry) => entry.localId)};

Map<int, RemoteContentRetryEntry> upsertRemoteContentFailure(
  Map<int, RemoteContentRetryEntry> current,
  RemoteContentRetryEntry entry,
) {
  final updated = Map<int, RemoteContentRetryEntry>.from(current);
  updated.removeWhere(
    (_, existing) =>
        existing.remoteDocumentId == entry.remoteDocumentId &&
        existing.localId != entry.localId,
  );
  updated[entry.localId] = entry;
  return updated;
}

Map<int, RemoteContentRetryEntry> removeRemoteContentFailure(
  Map<int, RemoteContentRetryEntry> current,
  String remoteDocumentId,
) =>
    Map<int, RemoteContentRetryEntry>.from(current)
      ..removeWhere((_, entry) => entry.remoteDocumentId == remoteDocumentId);

String remoteContentFailureStatus(
  RemoteContentRetryEntry entry, {
  required int maxAttempts,
}) {
  final subject = entry.category == RemoteNoteFailureCategory.attachment
      ? 'Attachment download'
      : entry.category == RemoteNoteFailureCategory.decryption
      ? 'Decryption'
      : 'Remote note';
  if (entry.state == RemoteContentRetryState.exhausted) {
    return '$subject failed; automatic retries stopped '
        '(${entry.attempts}/$maxAttempts)';
  }
  if (entry.state == RemoteContentRetryState.deferred) {
    return '$subject waiting for encryption keys';
  }
  return '$subject retry scheduled (${entry.attempts}/$maxAttempts)';
}
