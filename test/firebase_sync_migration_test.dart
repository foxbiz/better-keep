import 'package:better_keep/services/external_sync/firebase_sync_migration.dart';
import 'package:better_keep/services/external_sync/firebase_sync_version.dart';
import 'package:better_keep/services/external_sync/sync_version.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/offline_firebase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineFirestore firestore;
  const path = 'users/owner/notes/note';
  const legacy = {'title': 'Old content', 'updated_at': '2026-10-24T12:00:00'};
  final stamp = Timestamp.fromDate(DateTime.utc(2026, 10, 23));
  void checkCurrent() {}
  setUp(() {
    firestore = OfflineFirestore();
    firestore.documents[path] = {...legacy};
  });
  tearDown(() async {
    FirebaseSyncMigration.stampOverride = null;
    await firestore.events.close();
  });
  DocumentReference<Map<String, dynamic>> ref() =>
      firestore.collection('users/owner/notes').doc('note');
  Future<Map<String, dynamic>> resolve() => FirebaseSyncMigration.resolve(
    ref(),
    SyncEntityKind.note,
    {...legacy},
    checkCurrent,
  );

  test(
    'pull resolves the server stamp without changing cached content',
    () async {
      FirebaseSyncMigration.stampOverride = (_, _) async {
        firestore.documents[path]!['sync_committed_at'] = stamp;
      };
      final data = await resolve();
      expect(data['title'], legacy['title']);
      expect(
        FirebaseSyncVersion.read(
          SyncEntityKind.note,
          'note',
          data,
        ).modifiedAtMicros,
        stamp.microsecondsSinceEpoch,
      );
    },
  );
  test(
    'concurrent remote edit cannot lend its timestamp to old content',
    () async {
      FirebaseSyncMigration.stampOverride = (_, _) async {
        firestore.documents[path] = {
          ...legacy,
          'title': 'Concurrent edit',
          'sync_committed_at': stamp,
        };
      };
      await expectLater(resolve(), throwsFormatException);
    },
  );
  test(
    'transaction retries once and preserves newer remote comparison',
    () async {
      var attempts = 0;
      var migrations = 0;
      FirebaseSyncMigration.stampOverride = (_, _) async {
        migrations++;
        firestore.documents[path]!['sync_committed_at'] = stamp;
      };
      final version = await FirebaseSyncMigration.retry(
        ref(),
        SyncEntityKind.note,
        checkCurrent,
        () async {
          attempts++;
          return FirebaseSyncVersion.read(
            SyncEntityKind.note,
            'note',
            firestore.documents[path]!,
          );
        },
      );
      expect(version.modifiedAtMicros, stamp.microsecondsSinceEpoch);
      expect(attempts, 2);
      expect(migrations, 1);
      FirebaseSyncMigration.stampOverride = (_, _) async {
        migrations++;
      };
      await expectLater(
        FirebaseSyncMigration.retry(
          ref(),
          SyncEntityKind.note,
          checkCurrent,
          () async {
            throw const MissingFirebaseSyncTimestamp();
          },
        ),
        throwsA(isA<MissingFirebaseSyncTimestamp>()),
      );
      expect(migrations, 2);
    },
  );
  test(
    'logout while awaiting migration prevents reading or applying a result',
    () async {
      var active = true;
      FirebaseSyncMigration.stampOverride = (_, _) async {
        active = false;
      };
      await expectLater(
        FirebaseSyncMigration.resolve(
          ref(),
          SyncEntityKind.note,
          {...legacy},
          () {
            if (!active) throw StateError('Session ended');
          },
        ),
        throwsStateError,
      );
      expect(firestore.reads, isEmpty);
    },
  );
}
