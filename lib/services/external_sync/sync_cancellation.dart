/// A superseded replica session must stop without publishing a sync failure.
class SyncReplicaCancelled implements Exception {
  const SyncReplicaCancelled();
}
