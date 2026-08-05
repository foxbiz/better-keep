import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/remote_document_revision.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('commit revision is stable across Firestore and cached ISO forms', () {
    const documentId = 'remote-note';
    final timestamp = Timestamp(1785373200, 456789000);
    final cachedTimestamp = timestamp.toDate().toUtc().toIso8601String();

    final firestoreRevision = remoteDocumentRevision({
      cloudSyncCommittedAtField: timestamp,
    }, documentId);
    final cachedRevision = remoteDocumentRevision({
      cloudSyncCommittedAtField: cachedTimestamp,
    }, documentId);

    expect(cachedRevision, firestoreRevision);
    expect(firestoreRevision, endsWith(':$documentId'));
  });

  test('legacy documents use updated_at plus document ID', () {
    final revision = remoteDocumentRevision({
      'updated_at': '2026-07-30T01:02:03.000Z',
    }, 'legacy-note');

    expect(revision, 'legacy:1785373323000000:legacy-note');
  });

  test('documents without a valid commit or legacy timestamp are rejected', () {
    expect(
      () => remoteDocumentRevision({'updated_at': 'invalid'}, 'broken-note'),
      throwsFormatException,
    );
  });
}
