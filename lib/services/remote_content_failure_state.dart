import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';

Set<int> combinedRemoteSyncFailureIds({
  required Set<int> transientFailures,
  required Iterable<RemoteContentRetryEntry> contentFailures,
}) => {
  ...transientFailures,
  ...contentFailures
      .where((entry) => entry.state != RemoteContentRetryState.deferred)
      .map((entry) => entry.localId),
};

Set<int> remoteSyncDeferredIds(
  Iterable<RemoteContentRetryEntry> contentFailures,
) => contentFailures
    .where((entry) => entry.state == RemoteContentRetryState.deferred)
    .map((entry) => entry.localId)
    .toSet();

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
  final subject = switch (entry.category) {
    RemoteNoteFailureCategory.attachment => 'Attachment download',
    RemoteNoteFailureCategory.decryption => 'Decryption',
    RemoteNoteFailureCategory.invalidPayload => 'Remote note',
    RemoteNoteFailureCategory.localApply => 'Local note update',
  };
  if (entry.state == RemoteContentRetryState.exhausted) {
    return '$subject failed; automatic retries stopped '
        '(${entry.attempts}/$maxAttempts)';
  }
  if (entry.state == RemoteContentRetryState.deferred) {
    return '$subject waiting for encryption keys';
  }
  return '$subject retry scheduled (${entry.attempts}/$maxAttempts)';
}
