import 'external_sync/firebase_sync_migration.dart';
import 'external_sync/sync_version.dart';

import 'package:better_keep/services/cloud_read.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';

import 'dart:math';

import 'note_sort_cloud_manifest.dart';

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
    required DateTime updatedAt,
    required String contentHash,
    bool deleted = false,
  });

  Future<void> deleteRevision(String revision, int chunkCount);
}

class FirestoreNoteSortCloudRepository implements NoteSortCloudRepository {
  FirestoreNoteSortCloudRepository({
    required this.firestore,
    required this.userId,
    required this.schemaVersion,
    this.isCurrent,
  });

  final FirebaseFirestore firestore;
  final String userId;
  final bool Function()? isCurrent;
  void _checkCurrent() {
    if (isCurrent != null) requireCurrentSession(isCurrent!);
  }

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
    final document = await readCloudDocument(
      _manifests.doc(contextKey),
      isCurrent: isCurrent,
    );
    final data = document.data();
    return data == null
        ? null
        : FirebaseSyncMigration.resolve(
            _manifests.doc(contextKey),
            SyncEntityKind.order,
            data,
            _checkCurrent,
          );
  }

  @override
  Future<List<Map<String, dynamic>>?> readChunks(
    String revision,
    int chunkCount,
  ) async {
    final chunks = <Map<String, dynamic>>[];
    for (var index = 0; index < chunkCount; index++) {
      final document = await readCloudDocument(
        _chunkRef(revision, index),
        isCurrent: isCurrent,
      );
      final data = document.data();
      if (!document.exists || data == null) return null;
      chunks.add(data);
    }
    return chunks;
  }

  @override
  Future<void> writeChunks(String revision, List<List<String>> chunks) async {
    // The same edit may arrive independently from several providers. A retry
    // may fill missing chunks but must never overwrite a published revision.
    for (var start = 0; start < chunks.length; start += 8) {
      _checkCurrent();
      final end = min(start + 8, chunks.length);
      await firestore
          .runTransaction((transaction) async {
            final existing = <DocumentSnapshot<Map<String, dynamic>>>[];
            for (var index = start; index < end; index++) {
              existing.add(await transaction.get(_chunkRef(revision, index)));
              _checkCurrent();
            }
            for (var index = start; index < end; index++) {
              final stored = existing[index - start];
              if (stored.exists) {
                final data = stored.data();
                final ids = data?['note_ids'];
                if (data?['schema_version'] != schemaVersion ||
                    data?['revision'] != revision ||
                    ids is! List ||
                    ids.any((id) => id is! String) ||
                    NoteSortCloudManifest.contentHash(ids.cast<String>()) !=
                        NoteSortCloudManifest.contentHash(chunks[index])) {
                  throw const FormatException('Order revision content changed');
                }
              } else {
                transaction.set(_chunkRef(revision, index), {
                  'schema_version': schemaVersion,
                  'revision': revision,
                  'note_ids': chunks[index],
                });
              }
            }
            _checkCurrent();
          })
          .timeout(const Duration(seconds: 10));
      _checkCurrent();
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
    required DateTime updatedAt,
    required String contentHash,
    bool deleted = false,
  }) {
    final payload = NoteSortCloudManifest.encode(
      schemaVersion: schemaVersion,
      contextKey: contextKey,
      sortMode: sortMode,
      revision: revision,
      updatedAt: updatedAt,
      chunkCount: chunkCount,
      noteCount: noteCount,
      contentHash: contentHash,
      deleted: deleted,
    );
    final incoming = NoteSortCloudManifest.version(payload);
    final manifest = _manifests.doc(contextKey);
    _checkCurrent();
    return FirebaseSyncMigration.retry(
      manifest,
      SyncEntityKind.order,
      _checkCurrent,
      () => firestore
          .runTransaction((transaction) async {
            _checkCurrent();
            final current = await transaction.get(manifest);
            _checkCurrent();
            final currentData = current.data();
            final revisionValue = currentData?['revision'];
            final chunkCountValue = currentData?['chunk_count'];
            final previousRevision = revisionValue is String
                ? revisionValue
                : null;
            final previousChunkCount = chunkCountValue is int
                ? chunkCountValue
                : 0;
            if (current.exists &&
                (currentData?['schema_version'] != schemaVersion ||
                    currentData?['context_key'] != contextKey ||
                    incoming.compareTo(
                          NoteSortCloudManifest.version(currentData!),
                        ) <
                        0)) {
              return NoteSortCloudCommitResult.conflict(
                previousRevision: previousRevision,
                previousChunkCount: previousChunkCount,
              );
            }
            if (currentData != null &&
                incoming.compareTo(
                      NoteSortCloudManifest.version(currentData),
                    ) ==
                    0 &&
                (currentData['sort_mode'] != sortMode ||
                    currentData['chunk_count'] != chunkCount ||
                    currentData['note_count'] != noteCount ||
                    (currentData['content_hash'] != null &&
                        currentData['content_hash'] != contentHash))) {
              throw const FormatException('Order revision content changed');
            }
            transaction.set(manifest, payload);
            return NoteSortCloudCommitResult.committed(
              previousRevision: previousRevision,
              previousChunkCount: previousChunkCount,
            );
          })
          .timeout(const Duration(seconds: 10)),
    );
  }

  @override
  Future<void> deleteRevision(String revision, int chunkCount) async {
    for (var batchStart = 0; batchStart < chunkCount; batchStart += 450) {
      _checkCurrent();
      final batch = firestore.batch();
      final batchEnd = min(batchStart + 450, chunkCount);
      for (var index = batchStart; index < batchEnd; index++) {
        batch.delete(_chunkRef(revision, index));
      }
      await batch.commit().timeout(const Duration(seconds: 10));
      _checkCurrent();
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
