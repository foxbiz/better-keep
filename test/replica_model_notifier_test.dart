import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/external_sync/library_replica_content.dart';
import 'package:better_keep/services/external_sync/replica_model_notifier.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  late ReplicaModelNotifier notifier;
  late bool current;
  var noteSyncs = 0, labelSyncs = 0, reconciliations = 0;
  final cancelled = <int>[];
  final noteEvents = <NoteEvent>[];
  final labelEvents = <LabelEvent>[];
  void noteListener(NoteEvent event) => noteEvents.add(event);
  void labelListener(LabelEvent event) => labelEvents.add(event);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(db);
    await Label.createTable(db);
    await SyncMutationJournal.install(db);
    current = true;
    noteSyncs = labelSyncs = reconciliations = 0;
    cancelled.clear();
    noteEvents.clear();
    labelEvents.clear();
    Note.on('changed', noteListener);
    Label.on('changed', labelListener);
    notifier = ReplicaModelNotifier(
      database: db,
      isCurrent: () => current,
      queueNoteSync: () async {
        noteSyncs++;
      },
      queueLabelSync: () async {
        labelSyncs++;
      },
      reconcileReminders: () {
        reconciliations++;
      },
      cancelReminder: (id) async {
        cancelled.add(id);
      },
    );
  });
  tearDown(() async {
    Note.off('changed', noteListener);
    Label.off('changed', labelListener);
    await db.close();
  });

  Future<SyncAppliedChange> change(
    SyncEntityKind kind,
    String event, {
    int time = 1,
  }) async {
    final deleted = event == 'deleted';
    final revision = SyncRevision(
      kind: kind,
      entityId: 'entity',
      revisionId: 'source-$time',
      modifiedAtMicros: time,
      deleted: deleted,
      payloadObjectId: deleted ? null : 'a' * 64,
    );
    await db.transaction(
      (txn) => SyncMutationJournal.received(txn, revision, '7'),
    );
    return SyncAppliedChange(
      revision: revision,
      localId: '7',
      event: event,
      row: kind == SyncEntityKind.note
          ? {
              'id': 7,
              'sync_id': 'entity',
              'title': 'Received',
              'content': '',
              'attachments': '[]',
            }
          : {'id': 7, 'sync_id': 'entity', 'name': 'Work'},
    );
  }

  test('note notifications preserve source versions and schedule Firebase and reminders', () async {
    final applied = await change(SyncEntityKind.note, 'created');
    await notifier.apply(applied);
    expect(noteEvents.single.event, 'created');
    expect(noteEvents.single.origin, ModelChangeOrigin.remoteSync);
    expect(noteEvents.single.note.title, 'Received');
    expect(noteSyncs, 1);
    expect(labelSyncs, 0);
    expect(reconciliations, 1);
    expect(cancelled, isEmpty);
    expect(
      (await SyncMutationJournal.current(
        db,
        SyncEntityKind.note,
        'entity',
      ))!.revisionId,
      'source-1',
    );
    await notifier.apply(await change(SyncEntityKind.note, 'deleted', time: 2));
    expect(noteEvents.last.event, 'deleted');
    expect(cancelled, [7]);
    expect(noteSyncs, 2);
  });

  test('label create, update and deletion reach model listeners with remote origin', () async {
    for (final entry in ['created', 'updated', 'deleted'].indexed) {
      await notifier.apply(
        await change(SyncEntityKind.label, entry.$2, time: entry.$1 + 1),
      );
    }
    expect(labelEvents.map((event) => event.event), [
      'created',
      'updated',
      'deleted',
    ]);
    expect(
      labelEvents.every(
        (event) => event.origin == ModelChangeOrigin.remoteSync,
      ),
      isTrue,
    );
    expect(labelSyncs, 3);
    expect(noteSyncs, 0);
  });

  test(
    'superseded commits and retired sessions do not emit stale UI or sync work',
    () async {
      final stale = await change(SyncEntityKind.note, 'created');
      final latest = await change(SyncEntityKind.note, 'updated', time: 2);
      await notifier.apply(stale);
      expect(noteEvents, isEmpty);
      current = false;
      await notifier.apply(latest);
      expect(noteEvents, isEmpty);
      expect(noteSyncs, 0);
      expect(reconciliations, 0);
    },
  );
}
