import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firestore_operation_retry.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

typedef FirestoreQueryRetryLogger =
    void Function(Object error, int nextAttempt, Duration delay);

/// Server-backed Firestore reads used by note synchronization.
///
/// Emulator acceptance tests use this repository too, so they exercise the
/// same database instance, query shape, source selection, and retry behavior.
class NoteCloudRepository {
  NoteCloudRepository({FirebaseFirestore Function()? firestore})
    : _firestore = firestore ?? (() => FirebaseBackend.firestore);

  final FirebaseFirestore Function() _firestore;

  CollectionReference<Map<String, dynamic>> notes(String uid) {
    return _firestore().collection('users').doc(uid).collection('notes');
  }

  Future<QuerySnapshot<Map<String, dynamic>>> captureBootstrapBoundary(
    String uid, {
    FirestoreQueryRetryLogger? onRetry,
  }) {
    return _getServerDocuments(
      notes(uid)
          .orderBy(cloudSyncCommittedAtField, descending: true)
          .orderBy(FieldPath.documentId, descending: true)
          .limit(1),
      onRetry: onRetry,
    );
  }

  Future<QuerySnapshot<Map<String, dynamic>>> fetchPage({
    required String uid,
    required CloudSyncCheckpoint? checkpoint,
    required bool isBootstrap,
    required int pageSize,
    DocumentSnapshot<Map<String, dynamic>>? lastDocument,
    FirestoreQueryRetryLogger? onRetry,
  }) {
    Query<Map<String, dynamic>> query;
    if (isBootstrap) {
      query = notes(uid).orderBy(FieldPath.documentId).limit(pageSize);
    } else {
      query = notes(uid)
          .orderBy(cloudSyncCommittedAtField)
          .orderBy(FieldPath.documentId)
          .limit(pageSize);
      if (lastDocument == null && checkpoint?.cursor != null) {
        final cursor = checkpoint!.cursor!;
        query = query.startAfter([cursor.timestamp, cursor.documentId]);
      }
    }

    if (lastDocument != null) {
      query = query.startAfterDocument(lastDocument);
    }
    return _getServerDocuments(query, onRetry: onRetry);
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _getServerDocuments(
    Query<Map<String, dynamic>> query, {
    FirestoreQueryRetryLogger? onRetry,
  }) {
    return retryTransientFirestoreOperation(
      () => query.get(const GetOptions(source: Source.server)),
      onRetry: onRetry,
    );
  }
}
