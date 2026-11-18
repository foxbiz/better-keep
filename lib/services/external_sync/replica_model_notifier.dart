import 'package:sqflite/sqflite.dart';

import '../../models/base_model.dart';
import '../../models/label.dart';
import '../../models/note.dart';
import '../label_sync_service.dart';
import '../note_sort_service.dart';
import '../note_sync_service.dart';
import '../reminder_coordinator.dart';
import 'library_replica_content.dart';
import 'sync_mutation_journal.dart';
import 'sync_revision.dart';

/// Emits only committed replica changes that are still the current local
/// revision. Delayed decryption must not replace a newer local model in the UI.
class ReplicaModelNotifier {
  ReplicaModelNotifier({
    required this.database,
    required this.isCurrent,
    Future<void> Function()? queueNoteSync,
    Future<void> Function()? queueLabelSync,
    void Function()? reconcileReminders,
    Future<void> Function(int)? cancelReminder,
  }) : queueNoteSync = queueNoteSync ?? NoteSyncService().sync,
       queueLabelSync = queueLabelSync ?? LabelSyncService().sync,
       reconcileReminders =
           reconcileReminders ??
           ReminderCoordinator.instance.requestReconciliation,
       cancelReminder = cancelReminder ?? ReminderCoordinator.instance.cancel;

  final Database database;
  final bool Function() isCurrent;
  final Future<void> Function() queueNoteSync, queueLabelSync;
  final void Function() reconcileReminders;
  final Future<void> Function(int) cancelReminder;

  Future<bool> _stillCurrent(SyncAppliedChange change) async {
    if (!isCurrent()) return false;
    final current = await SyncMutationJournal.current(
      database,
      change.revision.kind,
      change.revision.entityId,
    );
    return isCurrent() &&
        current != null &&
        current.compareTo(change.revision) == 0;
  }

  Future<void> apply(SyncAppliedChange change) async {
    if (!isCurrent()) return;
    switch (change.revision.kind) {
      case SyncEntityKind.order:
        await NoteSortService().refreshFromReplica(
          change.localId,
          database: database,
          isCurrent: isCurrent,
        );
      case SyncEntityKind.note:
        final row = change.row;
        final note = row == null
            ? Note(
                id: int.parse(change.localId),
                syncId: change.revision.entityId,
              )
            : await Note.fromJsonAsync(Map<String, dynamic>.from(row));
        if (!await _stillCurrent(change)) return;
        note.notify(change.event, false, ModelChangeOrigin.remoteSync);
        if (!isCurrent()) return;
        if (change.revision.deleted) {
          await cancelReminder(note.id!);
          if (!isCurrent()) return;
        }
        reconcileReminders();
        await queueNoteSync();
      case SyncEntityKind.label:
        final label = change.row == null
            ? Label(
                id: int.parse(change.localId),
                name: '',
                syncId: change.revision.entityId,
              )
            : Label.fromJson(change.row!);
        if (!await _stillCurrent(change)) return;
        label.notifyWithOrigin(change.event, ModelChangeOrigin.remoteSync);
        if (!isCurrent()) return;
        await queueLabelSync();
    }
  }
}
