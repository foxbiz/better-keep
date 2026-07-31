import 'package:better_keep/models/cloud_sync_cursor.dart';
import 'package:better_keep/models/pending_remote_sync.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudSyncCursor', () {
    test('round-trips Firestore nanosecond precision', () {
      const cursor = CloudSyncCursor(
        seconds: 1770000000,
        nanoseconds: 987654321,
        documentId: 'note-b',
      );

      final restored = CloudSyncCursor.fromJson(cursor.toJson());

      expect(restored, cursor);
      expect(restored.timestamp.seconds, 1770000000);
      expect(restored.timestamp.nanoseconds, 987654321);
    });

    test('uses document ID as an exact timestamp tie-breaker', () {
      const first = CloudSyncCursor(
        seconds: 100,
        nanoseconds: 200,
        documentId: 'note-a',
      );
      const second = CloudSyncCursor(
        seconds: 100,
        nanoseconds: 200,
        documentId: 'note-b',
      );

      expect(first.compareTo(second), lessThan(0));
      expect(first.max(second), second);
    });

    test('reads only a Firestore timestamp marker', () {
      final cursor = CloudSyncCursor.fromDocument({
        cloudSyncCommittedAtField: Timestamp(11, 12),
      }, 'note-a');

      expect(
        cursor,
        const CloudSyncCursor(
          seconds: 11,
          nanoseconds: 12,
          documentId: 'note-a',
        ),
      );
      expect(
        CloudSyncCursor.fromDocument({
          cloudSyncCommittedAtField: '2026-01-01T00:00:00Z',
        }, 'note-a'),
        isNull,
      );
    });
  });

  group('CloudSyncCheckpoint', () {
    test('persists a completed bootstrap with no stamped documents', () {
      const checkpoint = CloudSyncCheckpoint(bootstrapped: true, cursor: null);

      final restored = CloudSyncCheckpoint.fromJson(checkpoint.toJson());

      expect(restored.bootstrapped, isTrue);
      expect(restored.requiresBootstrap, isFalse);
      expect(restored.cursor, isNull);
    });

    test('rejects incompatible checkpoint schemas', () {
      expect(
        () => CloudSyncCheckpoint.fromJson({
          'schema_version': 1,
          'bootstrapped': true,
        }),
        throwsFormatException,
      );
    });
  });

  test('legacy remote caches do not masquerade as durable checkpoints', () {
    final metadata = RemoteSyncCacheMetadata.fromJson({
      'total_pages': 1,
      'current_sync_page': 0,
      'last_synced_at': '2026-01-01T00:00:00.000Z',
      'all_pages_fetched': true,
      'sync_complete': false,
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-01T00:00:00.000Z',
    });

    expect(metadata.cursorSchemaVersion, 1);
    expect(metadata.lastCursor, isNull);
  });
}
