import 'package:better_keep/services/note_sort_cloud_manifest.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_firebase.dart';

void main() {
  const context = 'main:grid';
  const path = 'users/account-a/note_order_contexts/main:grid';
  late OfflineFirestore firestore;
  late FirestoreNoteSortCloudRepository repository;
  setUp(() {
    firestore = OfflineFirestore();
    repository = FirestoreNoteSortCloudRepository(
      firestore: firestore,
      userId: 'account-a',
      schemaVersion: 2,
    );
  });
  Future<NoteSortCloudCommitResult> publish(
    String revision,
    DateTime time, {
    List<String> ids = const ['one'],
    String? base,
    bool deleted = false,
  }) => repository.commitManifest(
    contextKey: context,
    sortMode: 'custom',
    revision: revision,
    baseRevision: base,
    chunkCount: ids.isEmpty ? 0 : 1,
    noteCount: ids.length,
    updatedAt: time,
    contentHash: NoteSortCloudManifest.contentHash(ids),
    deleted: deleted,
  );

  test(
    'source versions win independent of upload order or base revision',
    () async {
      final early = DateTime.utc(2026, 1, 1);
      final later = early.add(const Duration(microseconds: 1));
      expect(
        (await publish('first', early)).outcome,
        NoteSortCloudCommitOutcome.committed,
      );
      expect(
        (await publish('newer', later, base: 'unrelated-provider')).outcome,
        NoteSortCloudCommitOutcome.committed,
      );
      expect(
        (await publish('older', early, base: 'newer')).outcome,
        NoteSortCloudCommitOutcome.conflict,
      );
      final payload = firestore.documents[path]!;
      final version = NoteSortCloudManifest.version(payload);
      expect(version.revisionId, 'newer');
      expect(version.modifiedAtMicros, later.microsecondsSinceEpoch);
      expect(payload['updated_at'], Timestamp.fromDate(later));
      expect(
        (await publish('newer', later)).outcome,
        NoteSortCloudCommitOutcome.committed,
      );
    },
  );

  test(
    'tombstones retain source identity, win ties and allow newer revivals',
    () async {
      final time = DateTime.utc(2026);
      await publish('live', time);
      final deletion = await publish('deleted', time, ids: [], deleted: true);
      expect(deletion.outcome, NoteSortCloudCommitOutcome.committed);
      final data = firestore.documents[path]!;
      final version = NoteSortCloudManifest.version(data);
      expect(version.deleted, isTrue);
      expect(version.revisionId, 'deleted');
      expect(version.modifiedAtMicros, time.microsecondsSinceEpoch);
      expect(data['chunk_count'], 0);
      expect(data['note_count'], 0);
      expect(
        (await publish('stale-live', time)).outcome,
        NoteSortCloudCommitOutcome.conflict,
      );
      expect(
        (await publish(
          'revived',
          time.add(const Duration(microseconds: 1)),
        )).outcome,
        NoteSortCloudCommitOutcome.committed,
      );
      expect(firestore.documents[path], isNot(contains('deleted')));
    },
  );

  test('tombstones cannot reference content or delete a newer order', () async {
    final time = DateTime.utc(2026);
    expect(
      () => publish('invalid-delete', time, deleted: true),
      throwsFormatException,
    );
    await publish('newer', time.add(const Duration(seconds: 1)));
    expect(
      (await publish('older-delete', time, ids: [], deleted: true)).outcome,
      NoteSortCloudCommitOutcome.conflict,
    );
    expect(firestore.documents[path]!['revision'], 'newer');
  });

  test('transaction retry observes a concurrent newer edit', () async {
    final time = DateTime.utc(2026, 1, 1);
    firestore.commit = () async {
      firestore.commit = null;
      firestore.documents[path] = NoteSortCloudManifest.encode(
        schemaVersion: 2,
        contextKey: context,
        sortMode: 'updatedNewest',
        revision: 'concurrent',
        updatedAt: time.add(const Duration(seconds: 1)),
        chunkCount: 1,
        noteCount: 1,
        contentHash: NoteSortCloudManifest.contentHash(['other']),
      );
    };
    expect(
      (await publish('candidate', time)).outcome,
      NoteSortCloudCommitOutcome.conflict,
    );
    expect(firestore.documents[path]!['revision'], 'concurrent');
  });

  test('changed chunk contents cannot reuse a source version', () async {
    final time = DateTime.utc(2026, 1, 1);
    await publish('same', time);
    await expectLater(
      publish('same', time, ids: ['different']),
      throwsFormatException,
    );
    await expectLater(
      repository.commitManifest(
        contextKey: context,
        sortMode: 'updatedNewest',
        revision: 'same',
        baseRevision: 'same',
        chunkCount: 1,
        noteCount: 1,
        updatedAt: time,
        contentHash: NoteSortCloudManifest.contentHash(['one']),
      ),
      throwsFormatException,
    );
    expect(
      firestore.documents[path]!['content_hash'],
      NoteSortCloudManifest.contentHash(['one']),
    );
  });

  test(
    'chunk retries are immutable and missing chunks can be restored',
    () async {
      const chunkPath =
          'users/account-a/note_order_context_snapshots/source/chunks/000000';
      await repository.writeChunks('source', [
        ['one', 'two'],
      ]);
      await repository.writeChunks('source', [
        ['one', 'two'],
      ]);
      await expectLater(
        repository.writeChunks('source', [
          ['two', 'one'],
        ]),
        throwsFormatException,
      );
      expect(firestore.documents[chunkPath]!['note_ids'], ['one', 'two']);
      firestore.documents.remove(chunkPath);
      await repository.writeChunks('source', [
        ['one', 'two'],
      ]);
      expect(firestore.documents[chunkPath]!['note_ids'], ['one', 'two']);
    },
  );

  test(
    'legacy payload changes invalidate retained metadata deterministically',
    () async {
      final time = DateTime.utc(2026, 1, 1);
      await publish('source', time);
      final payload = firestore.documents[path]!;
      final changed = {...payload, 'sort_mode': 'createdNewest'};
      final legacy = NoteSortCloudManifest.version(changed);
      expect(legacy.revisionId, startsWith('firebase-'));
      expect(legacy.modifiedAtMicros, time.microsecondsSinceEpoch);
      expect(
        NoteSortCloudManifest.version(changed).revisionId,
        legacy.revisionId,
      );
      expect(
        () => NoteSortCloudManifest.version({...changed}..remove('updated_at')),
        throwsFormatException,
      );
    },
  );
}
