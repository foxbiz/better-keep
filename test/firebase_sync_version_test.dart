import 'package:better_keep/services/external_sync/firebase_sync_version.dart';
import 'package:better_keep/services/external_sync/sync_version.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final version = SyncVersion(
    kind: SyncEntityKind.note,
    entityId: 'note',
    revisionId: 'source-edit',
    modifiedAtMicros: 1800000000000000,
    deleted: false,
  );
  final body = <String, dynamic>{
    'title': 'Title',
    'content': 'Body',
    'updated_at': '2026-01-01T02:03:04Z',
    'attachments': <dynamic>[],
  };
  SyncVersion read(Map<String, dynamic> data) =>
      FirebaseSyncVersion.read(SyncEntityKind.note, 'note', data);

  test(
    'payload-bound identity survives server stamps and cache serialization',
    () {
      final wire = FirebaseSyncVersion.bind(body, version);
      expect(read(wire).revisionId, version.revisionId);
      wire['sync_committed_at'] = Timestamp.now();
      expect(read(wire).compareTo(version), 0);
      wire['sync_committed_at'] = DateTime.now().toUtc().toIso8601String();
      expect(read(wire).compareTo(version), 0);
      expect(
        read(Map.fromEntries(wire.entries.toList().reversed)).revisionId,
        version.revisionId,
      );
    },
  );

  test('Firebase retains edit identity across native and web numeric representations', () {
    final wire = FirebaseSyncVersion.bind({
      ...body,
      'aspectRatio': 1.0,
    }, version);
    expect(read({...wire, 'aspectRatio': 1}).revisionId, version.revisionId);
    final legacy = {
      ...wire,
      'sync_meta': {...wire['sync_meta'] as Map}..remove('payloadHashV2'),
    };
    expect(read(legacy).revisionId, version.revisionId);
    expect(
      read({...wire, 'aspectRatio': 2}).revisionId,
      isNot(version.revisionId),
    );
  });

  test('an old merge writer cannot carry the previous edit identity into new content', () {
    final wire = FirebaseSyncVersion.bind(body, version);
    final changed = {...wire, 'content': 'An old client edited this'};
    final normalized = read(changed);
    expect(normalized.revisionId, isNot(version.revisionId));
    expect(
      read({...changed, 'sync_committed_at': Timestamp.now()}).revisionId,
      normalized.revisionId,
    );
    expect(
      read({...changed, 'sync_meta': null}).revisionId,
      normalized.revisionId,
    );
    final deleted = read({...wire, 'deleted': true});
    expect(deleted.deleted, true);
    expect(deleted.compareTo(version), greaterThan(0));
    expect(deleted.revisionId, isNot(version.revisionId));
  });

  test('ambiguous legacy wall clocks never invent the producing timezone', () {
    expect(FirebaseSyncVersion.timestamp('2026-01-01T02:03:04'), null);
    expect(
      FirebaseSyncVersion.timestamp('2026-01-01T07:33:04+05:30'),
      DateTime.utc(2026, 1, 1, 2, 3, 4),
    );
    expect(
      read(body).modifiedAtMicros,
      DateTime.utc(2026, 1, 1, 2, 3, 4).microsecondsSinceEpoch,
    );
    expect(
      read({...body, 'title': 'Other'}).revisionId,
      isNot(read(body).revisionId),
    );
  });

  test(
    'legacy edits use server stamps; deletion time outranks stale updated_at',
    () {
      final stamp = DateTime.utc(2026, 1, 1, 10);
      final legacy = {...body, 'updated_at': '2026-01-01T15:30:00'};
      expect(() => read(legacy), throwsFormatException);
      expect(
        read({...legacy, 'sync_committed_at': Timestamp.fromDate(stamp)})
            .modifiedAtMicros,
        stamp.microsecondsSinceEpoch,
      );
      expect(
        read({
          ...body,
          'deleted': true,
          'deleted_at': Timestamp.fromDate(stamp),
        }).modifiedAtMicros,
        stamp.microsecondsSinceEpoch,
      );
    },
  );

  test('revivals remove tombstone fields and metadata cannot change document identity', () {
    final revived = FirebaseSyncVersion.bind({
      ...body,
      'deleted': true,
      'deleted_at': Timestamp.now(),
    }, version);
    expect(revived.containsKey('deleted'), false);
    expect(revived.containsKey('deleted_at'), false);
    final other = FirebaseSyncVersion.read(
      SyncEntityKind.note,
      'other',
      revived,
    );
    expect(other.entityId, 'other');
    expect(other.revisionId, isNot(version.revisionId));
    expect(() => read({'title': 'No timestamp'}), throwsFormatException);
  });
}
