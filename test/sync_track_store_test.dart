import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/sync_identity_migration.dart';
import 'package:better_keep/services/sync_track_store.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await NoteSyncTrack.createTable(database);
    await LabelSyncTrack.createTable(database);
  });

  tearDown(() => database.close());

  for (final fixture in _fixtures) {
    group(fixture.name, () {
      test('stale null identity preserves canonical remote ID', () async {
        final linked = fixture.track(
          localId: 1,
          remoteId: 'remote-1',
          action: fixture.upload,
          status: fixture.synced,
        );
        await linked.save();

        final stale = fixture.track(
          localId: 1,
          action: fixture.upload,
          status: fixture.pending,
        );
        await stale.save();

        final canonical = await fixture.getByLocalId(1);
        expect(canonical.remoteId, 'remote-1');
        expect(canonical.status, fixture.pending);
        expect(stale.remoteId, 'remote-1');
        expect(stale.id, linked.id);
      });

      test('delete and pending status dominate stale saves', () async {
        final track = fixture.track(
          localId: 2,
          remoteId: 'remote-2',
          action: fixture.upload,
          status: fixture.synced,
        );
        await track.save();

        final deleting = await fixture.getByLocalId(2);
        await deleting.setAction(fixture.delete);

        final stale = fixture.track(
          localId: 2,
          action: fixture.upload,
          status: fixture.synced,
        );
        await stale.save();

        final canonical = await fixture.getByLocalId(2);
        expect(canonical.action, fixture.delete);
        expect(canonical.status, fixture.pending);
        expect(canonical.remoteId, 'remote-2');
      });

      test('identity uniqueness and compare-and-set are enforced', () async {
        final first = fixture.track(
          localId: 3,
          remoteId: 'remote-3',
          action: fixture.upload,
          status: fixture.pending,
        );
        await first.save();

        final duplicate = fixture.track(
          localId: 4,
          remoteId: 'remote-3',
          action: fixture.upload,
          status: fixture.pending,
        );
        await expectLater(
          duplicate.save(),
          throwsA(isA<SyncTrackIdentityConflict>()),
        );

        final stale = await fixture.getByLocalId(3);
        final current = await fixture.getByLocalId(3);
        await current.claimRemoteId('remote-3-replaced');
        await expectLater(
          stale.claimRemoteId('remote-3-stale'),
          throwsA(isA<SyncTrackRemoteIdConflict>()),
        );

        final canonical = await fixture.getByLocalId(3);
        expect(canonical.remoteId, 'remote-3-replaced');
      });

      test('sync completion is atomic with concurrent local work', () async {
        final unchanged = fixture.track(
          localId: 5,
          action: fixture.upload,
          status: fixture.pending,
        );
        await unchanged.save();
        final unchangedStart = DateTime.now();
        final unchangedTimestamp = unchanged.updatedAt;
        await unchanged.claimRemoteId('remote-5');
        expect(unchanged.updatedAt, unchangedTimestamp);
        expect(await unchanged.markSyncedIfUnchanged(unchangedStart), isTrue);
        expect((await fixture.getByLocalId(5)).status, fixture.synced);

        final racing = fixture.track(
          localId: 6,
          remoteId: 'remote-6',
          action: fixture.upload,
          status: fixture.pending,
        );
        await racing.save();
        final syncStart = DateTime.now();
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final localEdit = await fixture.getByLocalId(6);
        await localEdit.setAction(fixture.upload);

        expect(await racing.markSyncedIfUnchanged(syncStart), isFalse);
        final canonical = await fixture.getByLocalId(6);
        expect(canonical.status, fixture.pending);
        expect(canonical.remoteId, 'remote-6');
      });
    });
  }
}

class _SyncTrackFixture {
  const _SyncTrackFixture({
    required this.name,
    required this.upload,
    required this.delete,
    required this.pending,
    required this.synced,
    required this.track,
    required this.getByLocalId,
  });

  final String name;
  final dynamic upload;
  final dynamic delete;
  final dynamic pending;
  final dynamic synced;
  final dynamic Function({
    required int localId,
    String? remoteId,
    required dynamic action,
    required dynamic status,
  })
  track;
  final Future<dynamic> Function(int localId) getByLocalId;
}

final _fixtures = <_SyncTrackFixture>[
  _SyncTrackFixture(
    name: 'note sync track',
    upload: SyncAction.upload,
    delete: SyncAction.delete,
    pending: SyncStatus.pending,
    synced: SyncStatus.synced,
    track:
        ({
          required int localId,
          String? remoteId,
          required dynamic action,
          required dynamic status,
        }) => NoteSyncTrack(
          localId: localId,
          remoteId: remoteId,
          action: action as SyncAction,
          status: status as SyncStatus,
        ),
    getByLocalId: (localId) async =>
        (await NoteSyncTrack.getByLocalId(localId))!,
  ),
  _SyncTrackFixture(
    name: 'label sync track',
    upload: LabelSyncAction.upload,
    delete: LabelSyncAction.delete,
    pending: LabelSyncStatus.pending,
    synced: LabelSyncStatus.synced,
    track:
        ({
          required int localId,
          String? remoteId,
          required dynamic action,
          required dynamic status,
        }) => LabelSyncTrack(
          localId: localId,
          remoteId: remoteId,
          action: action as LabelSyncAction,
          status: status as LabelSyncStatus,
        ),
    getByLocalId: (localId) async =>
        (await LabelSyncTrack.getByLocalId(localId))!,
  ),
];
