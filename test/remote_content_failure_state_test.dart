import 'package:better_keep/services/remote_content_failure_state.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 30);

  RemoteContentRetryEntry failure({
    required String remoteDocumentId,
    required int localId,
    required RemoteNoteFailureCategory category,
    required RemoteContentRetryState state,
    int attempts = 1,
  }) => RemoteContentRetryEntry(
    userId: 'user',
    remoteDocumentId: remoteDocumentId,
    revision: 'revision-$remoteDocumentId',
    localId: localId,
    attempts: attempts,
    category: category,
    errorCode: 'sanitized-code',
    state: state,
    nextRetryAt: state == RemoteContentRetryState.waiting ? now : null,
    updatedAt: now,
  );

  test('clearing transient failures cannot hide durable content failures', () {
    final durable = failure(
      remoteDocumentId: 'remote-1',
      localId: 11,
      category: RemoteNoteFailureCategory.attachment,
      state: RemoteContentRetryState.exhausted,
      attempts: 5,
    );

    expect(
      combinedRemoteSyncFailureIds(
        transientFailures: const {},
        contentFailures: [durable],
      ),
      {11},
    );
  });

  test('success removal clears only the matching remote document', () {
    final first = failure(
      remoteDocumentId: 'remote-1',
      localId: 11,
      category: RemoteNoteFailureCategory.attachment,
      state: RemoteContentRetryState.exhausted,
    );
    final second = failure(
      remoteDocumentId: 'remote-2',
      localId: 22,
      category: RemoteNoteFailureCategory.decryption,
      state: RemoteContentRetryState.deferred,
      attempts: 0,
    );

    final remaining = removeRemoteContentFailure({
      first.localId: first,
      second.localId: second,
    }, first.remoteDocumentId);

    expect(remaining.keys, {22});
    expect(remaining[22]?.remoteDocumentId, 'remote-2');
  });

  test('attachment, decryption, and retry states remain distinct', () {
    final attachment = failure(
      remoteDocumentId: 'attachment',
      localId: 1,
      category: RemoteNoteFailureCategory.attachment,
      state: RemoteContentRetryState.waiting,
    );
    final decryption = failure(
      remoteDocumentId: 'decryption',
      localId: 2,
      category: RemoteNoteFailureCategory.decryption,
      state: RemoteContentRetryState.exhausted,
      attempts: 5,
    );
    final deferred = failure(
      remoteDocumentId: 'deferred',
      localId: 3,
      category: RemoteNoteFailureCategory.decryption,
      state: RemoteContentRetryState.deferred,
      attempts: 0,
    );

    expect(
      remoteContentFailureStatus(attachment, maxAttempts: 5),
      contains('Attachment download'),
    );
    expect(
      remoteContentFailureStatus(decryption, maxAttempts: 5),
      contains('Decryption failed'),
    );
    expect(
      remoteContentFailureStatus(deferred, maxAttempts: 5),
      contains('waiting for encryption keys'),
    );
    expect(
      combinedRemoteSyncFailureIds(
        transientFailures: const {},
        contentFailures: [deferred],
      ),
      isEmpty,
      reason: 'Deferred key waits are neutral, not failed syncs.',
    );
    expect(remoteSyncDeferredIds([deferred]), {3});
  });
}
