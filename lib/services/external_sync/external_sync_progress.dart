import '../../models/app_progress.dart';
import 'storage_connection.dart';
import 'sync_provider_adapter.dart';
import 'sync_scheduler.dart';

/// Only enabled destinations participate; a successful provider cannot conceal
/// another provider's failure or outstanding local changes.
SyncProgress externalSyncProgress({
  required Iterable<StorageConnection> connections,
  required Map<String, SyncConnectionProgress> progress,
  Map<String, SyncProviderFailureKind> errors = const {},
  Set<String> blockedProviders = const {},
  bool metadataReady = true,
  bool automatic = true,
  SyncProviderFailureKind? metadataFailure,
}) {
  final selected = connections
      .where((c) => c.enabled && c.state != 'disconnected')
      .toList();
  if (selected.any((c) => progress[c.replicaId]?.running == true)) {
    return const SyncProgress(SyncPhase.syncing);
  }
  final failures = <SyncProviderFailureKind>[
    ?metadataFailure,
    for (final c in selected)
      if (c.state == 'reconnect_required')
        SyncProviderFailureKind.reconnectRequired
      else if (errors[c.provider] != null)
        errors[c.provider]!
      else if (progress[c.replicaId]?.failure != null)
        progress[c.replicaId]!.failure!,
  ];
  if (failures.contains(SyncProviderFailureKind.quotaExceeded)) {
    return const SyncProgress(SyncPhase.storageFull);
  }
  if (failures.isNotEmpty) {
    if (failures.every(
      (f) => f == SyncProviderFailureKind.sharedSetupRequired,
    )) {
      return const SyncProgress(SyncPhase.providerSetupRequired);
    }
    return SyncProgress(
      failures.every(
            (f) =>
                f == SyncProviderFailureKind.unavailable ||
                f == SyncProviderFailureKind.rateLimited,
          )
          ? SyncPhase.unavailable
          : SyncPhase.failed,
    );
  }
  if (!metadataReady) return const SyncProgress(SyncPhase.preparing);
  if (selected.isEmpty) return SyncProgress.idle;
  if (selected.any(
    (c) =>
        blockedProviders.contains(c.provider) ||
        !c.isReady ||
        (progress[c.replicaId]?.blockedEntities ?? 0) > 0,
  )) {
    return SyncProgress(
      SyncPhase.failed,
      failedCount: selected.fold<int>(
        0,
        (count, c) => count + (progress[c.replicaId]?.blockedEntities ?? 0),
      ),
    );
  }
  if (selected.any((c) => progress[c.replicaId]?.pendingLocalChanges == true)) {
    // Queued edits are normal while waiting for the debounce or a manual sync.
    // Only an explicit refresh that cannot finish should ask the user to retry.
    return automatic
        ? const SyncProgress(SyncPhase.preparing)
        : SyncProgress.idle;
  }
  // Restoring a connection precedes creating its adapter and starting its first
  // pass. No successful pass yet is normal startup, not a request to retry.
  if (selected.any((c) => progress[c.replicaId]?.lastSuccess == null)) {
    return automatic
        ? const SyncProgress(SyncPhase.preparing)
        : SyncProgress.idle;
  }
  return const SyncProgress(SyncPhase.complete);
}
