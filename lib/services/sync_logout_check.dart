import 'package:sqflite/sqflite.dart';

import '../models/label.dart';
import '../state.dart';
import 'auth_service.dart';
import 'external_sync/external_sync_service.dart';
import 'external_sync/sync_mutation_journal.dart';
import 'external_sync/firebase_order_tombstones.dart';
import 'firebase_sync_preference.dart';

enum SyncLogoutState { complete, pending, unknown }

/// Read durable acknowledgements, not a past successful pass or UI counters.
/// This only assesses the local library; it never starts a sync or removes data.
Future<SyncLogoutState> inspectSyncBeforeLogout({
  required Database database,
  required bool? firebaseEnabled,
  required String? firebaseAccountId,
  required String? scope,
  required Iterable<String> externalReplicaIds,
  required bool metadataReady,
  required bool Function() isCurrent,
}) async {
  final destinations = externalReplicaIds.toSet();
  // Startup recreates these two labels even on a read-only restore. Only an
  // untouched seed is disposable; user labels, renames and tombstones count.
  final seedNames =
      'WITH seed_names(name) AS (VALUES ${List.filled(Label.systemLabelNames.length, '(?)').join(',')})';
  final seed =
      'l.is_system IS 1 AND l.name IN (SELECT name FROM seed_names) AND l.created_at IS NOT NULL AND l.created_at IS l.updated_at';
  try {
    final result = await database.transaction((txn) async {
      if (!isCurrent()) return SyncLogoutState.unknown;
      // With no selected external destination, paused Firebase queues still
      // reveal local-only changes that would otherwise disappear on sign-out.
      if (firebaseEnabled != false || destinations.isEmpty) {
        final pending = await txn.rawQuery('''
          $seedNames
          SELECT 1 FROM sync_track WHERE status IS NOT 'synced'
          UNION ALL SELECT 1 FROM label_sync_track t WHERE status IS NOT 'synced'
            AND NOT EXISTS (SELECT 1 FROM label l WHERE l.id = t.local_id AND $seed
              AND t.action = 'upload' AND (t.remote_id IS NULL OR t.remote_id = l.sync_id))
          UNION ALL SELECT 1 FROM note_sort_context WHERE dirty != 0
          UNION ALL SELECT 1 FROM note n
            WHERE NOT EXISTS (SELECT 1 FROM sync_track t
              WHERE t.local_id = n.id AND t.status = 'synced' AND t.remote_id IS NOT NULL)
          UNION ALL SELECT 1 FROM label l
            WHERE NOT ($seed) AND NOT EXISTS (SELECT 1 FROM label_sync_track t
              WHERE t.local_id = l.id AND t.status = 'synced' AND t.remote_id IS NOT NULL)
          LIMIT 1
        ''', Label.systemLabelNames);
        if (pending.isNotEmpty) return SyncLogoutState.pending;
        if (firebaseAccountId == null) return SyncLogoutState.unknown;
        if ((await FirebaseOrderTombstones.pending(
          txn,
          firebaseAccountId,
          limit: 1,
        )).isNotEmpty) {
          return SyncLogoutState.pending;
        }
      }
      if (destinations.isNotEmpty && scope == null) {
        return SyncLogoutState.unknown;
      }
      for (final destination in destinations) {
        final pending = await txn.rawQuery(
          '''
          $seedNames
          SELECT 1 FROM ${SyncMutationJournal.table} v
          WHERE NOT EXISTS (SELECT 1 FROM replica_acknowledgements a
            WHERE a.scope = ? AND a.connection_id = ? AND a.kind = v.kind
              AND a.entity_id = v.entity_id AND a.revision_id = v.revision_id)
          AND NOT (v.kind = 'label' AND v.deleted = 0 AND EXISTS (
            SELECT 1 FROM label l WHERE l.sync_id = v.entity_id AND $seed))
          LIMIT 1
        ''',
          [...Label.systemLabelNames, scope, destination],
        );
        if (pending.isNotEmpty) return SyncLogoutState.pending;
      }
      return metadataReady && firebaseEnabled != null
          ? SyncLogoutState.complete
          : SyncLogoutState.unknown;
    });
    return isCurrent() ? result : SyncLogoutState.unknown;
  } catch (_) {
    // A closed/unavailable database is not proof that everything is backed up.
    return SyncLogoutState.unknown;
  }
}

Future<SyncLogoutState> currentSyncLogoutState() async {
  final database = AppState.get('db');
  if (database is! Database) return SyncLogoutState.unknown;
  final accountCurrent = AuthService.captureSession();
  final service = ExternalSyncService.instance;
  final session = service.session;
  final connections = session?.connections;
  final firebase = FirebaseSyncPreference.instance;
  final firebaseEnabled = firebase.enabled;
  final selectedProvider = firebase.selectedProvider;
  final externalSelected =
      selectedProvider != null &&
      selectedProvider != 'none' &&
      selectedProvider != 'firebase';
  final selected = connections?.connections[selectedProvider];
  bool metadataReady() =>
      selectedProvider != null &&
      (!externalSelected ||
          connections?.canVerifyBackup(selectedProvider) == true) &&
      !firebase.loading &&
      !firebase.failed &&
      !firebase.busy;
  final ready = metadataReady();
  bool current() {
    final live = connections?.connections[selectedProvider];
    return accountCurrent() &&
        identical(database, AppState.get('db')) &&
        identical(session, service.session) &&
        (session?.isCurrent ?? true) &&
        firebase.enabled == firebaseEnabled &&
        firebase.selectedProvider == selectedProvider &&
        metadataReady() == ready &&
        live?.replicaId == selected?.replicaId &&
        live?.libraryId == selected?.libraryId &&
        live?.enabled == selected?.enabled &&
        live?.state == selected?.state;
  }

  if (externalSelected && !ready) return SyncLogoutState.unknown;
  return inspectSyncBeforeLogout(
    database: database,
    firebaseEnabled: firebaseEnabled,
    firebaseAccountId: AuthService.currentUser?.uid,
    scope: session?.engine.store.scope,
    externalReplicaIds: [
      if (externalSelected && selected != null) selected.replicaId,
    ],
    metadataReady: ready,
    isCurrent: current,
  );
}
