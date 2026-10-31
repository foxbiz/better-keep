import 'package:flutter/foundation.dart';

import '../../models/app_progress.dart';
import '../cloud_session_recovery.dart';
import 'library_sync_session.dart';

/// Drain bounded capture batches for one explicit refresh, preserving the target
/// generations selected at its start. A disconnect/reconnect is not success.
Future<SyncRefreshOutcome?> refreshExternalSession(
  LibrarySyncSession session, {
  required bool Function() isCurrent,
  required SyncProgress Function() progress,
  int maxPasses = 20,
  Duration timeLimit = const Duration(minutes: 2),
}) async {
  if (!isCurrent()) return SyncRefreshOutcome.deferred;
  await session.connections.waitForMetadata();
  if (!isCurrent()) return SyncRefreshOutcome.deferred;
  Set<String> targets() => session.connections.connections.values
      .where(
        (c) =>
            c.enabled &&
            c.state != 'disconnected' &&
            session.connections.isSelected(c.provider),
      )
      .map((c) => c.replicaId)
      .toSet();
  final selected = targets();
  if (selected.isEmpty) {
    return progress().isFailure ? SyncRefreshOutcome.failed : null;
  }
  final elapsed = Stopwatch()..start();
  var passes = 0;
  do {
    await session.scheduler.syncNow();
    if (!isCurrent() || !setEquals(selected, targets())) {
      return SyncRefreshOutcome.deferred;
    }
    final state = progress();
    if (state.phase == SyncPhase.unavailable) {
      return SyncRefreshOutcome.unavailable;
    }
    if (state.isFailure) return SyncRefreshOutcome.failed;
    if (state.isSuccess) return SyncRefreshOutcome.complete;
    final remaining = session.scheduler.progress.values;
    if (!remaining.any((p) => p.pendingLocalChanges) ||
        remaining.any((p) => p.failure != null || p.blockedEntities > 0)) {
      return SyncRefreshOutcome.deferred;
    }
  } while (++passes < maxPasses && elapsed.elapsed < timeLimit);
  return SyncRefreshOutcome.deferred;
}
