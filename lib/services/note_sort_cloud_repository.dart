import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

abstract interface class NoteSortCloudRepository {
  int get schemaVersion;

  Future<Map<String, dynamic>?> readManifest(String contextKey);

  Future<List<Map<String, dynamic>>?> readChunks(
    String revision,
    int chunkCount,
  );

  Future<void> writeChunks(String revision, List<List<String>> chunks);

  Future<NoteSortCloudCommitResult> commitManifest({
    required String contextKey,
    required String sortMode,
    required String revision,
    required String? baseRevision,
    required int chunkCount,
    required int noteCount,
  });

  Future<void> deleteRevision(String revision, int chunkCount);
}

class FirestoreNoteSortCloudRepository implements NoteSortCloudRepository {
  FirestoreNoteSortCloudRepository({
    required this.firestore,
    required this.userId,
    required this.schemaVersion,
  });

  final FirebaseFirestore firestore;
  final String userId;
  @override
  final int schemaVersion;

  CollectionReference<Map<String, dynamic>> get _manifests => firestore
      .collection('users')
      .doc(userId)
      .collection('note_order_contexts');

  DocumentReference<Map<String, dynamic>> _chunkRef(
    String revision,
    int index,
  ) => firestore
      .collection('users')
      .doc(userId)
      .collection('note_order_context_snapshots')
      .doc(revision)
      .collection('chunks')
      .doc(index.toString().padLeft(6, '0'));

  @override
  Future<Map<String, dynamic>?> readManifest(String contextKey) async {
    final document = await _manifests.doc(contextKey).get();
    return document.exists ? document.data() : null;
  }

  @override
  Future<List<Map<String, dynamic>>?> readChunks(
    String revision,
    int chunkCount,
  ) async {
    final chunks = <Map<String, dynamic>>[];
    for (var index = 0; index < chunkCount; index++) {
      final document = await _chunkRef(revision, index).get();
      final data = document.data();
      if (!document.exists || data == null) return null;
      chunks.add(data);
    }
    return chunks;
  }

  @override
  Future<void> writeChunks(String revision, List<List<String>> chunks) async {
    for (var batchStart = 0; batchStart < chunks.length; batchStart += 450) {
      final batch = firestore.batch();
      final batchEnd = min(batchStart + 450, chunks.length);
      for (var index = batchStart; index < batchEnd; index++) {
        batch.set(_chunkRef(revision, index), {
          'schema_version': schemaVersion,
          'revision': revision,
          'note_ids': chunks[index],
        });
      }
      await batch.commit();
    }
  }

  @override
  Future<NoteSortCloudCommitResult> commitManifest({
    required String contextKey,
    required String sortMode,
    required String revision,
    required String? baseRevision,
    required int chunkCount,
    required int noteCount,
  }) {
    final manifest = _manifests.doc(contextKey);
    return firestore.runTransaction((transaction) async {
      final current = await transaction.get(manifest);
      final currentData = current.data();
      final revisionValue = currentData?['revision'];
      final chunkCountValue = currentData?['chunk_count'];
      final previousRevision = revisionValue is String ? revisionValue : null;
      final previousChunkCount = chunkCountValue is int ? chunkCountValue : 0;
      if (current.exists &&
          previousRevision != baseRevision &&
          previousRevision != revision) {
        return NoteSortCloudCommitResult.conflict(
          previousRevision: previousRevision,
          previousChunkCount: previousChunkCount,
        );
      }
      transaction.set(manifest, {
        'schema_version': schemaVersion,
        'context_key': contextKey,
        'sort_mode': sortMode,
        'revision': revision,
        'chunk_count': chunkCount,
        'note_count': noteCount,
        'updated_at': FieldValue.serverTimestamp(),
      });
      return NoteSortCloudCommitResult.committed(
        previousRevision: previousRevision,
        previousChunkCount: previousChunkCount,
      );
    });
  }

  @override
  Future<void> deleteRevision(String revision, int chunkCount) async {
    for (var batchStart = 0; batchStart < chunkCount; batchStart += 450) {
      final batch = firestore.batch();
      final batchEnd = min(batchStart + 450, chunkCount);
      for (var index = batchStart; index < batchEnd; index++) {
        batch.delete(_chunkRef(revision, index));
      }
      await batch.commit();
    }
  }
}

class NoteSortCloudCommitResult {
  const NoteSortCloudCommitResult.committed({
    required this.previousRevision,
    required this.previousChunkCount,
  }) : outcome = NoteSortCloudCommitOutcome.committed;

  const NoteSortCloudCommitResult.conflict({
    required this.previousRevision,
    required this.previousChunkCount,
  }) : outcome = NoteSortCloudCommitOutcome.conflict;

  final NoteSortCloudCommitOutcome outcome;
  final String? previousRevision;
  final int previousChunkCount;
}

enum NoteSortCloudCommitOutcome { committed, conflict }
