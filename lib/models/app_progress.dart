/// User-visible authentication progress without embedding presentation text in
/// the authentication service.
enum AuthProgress {
  startingSignIn,
  waitingForSignIn,
  signingIn,
  creatingAccount,
  verifying,
  checkingAccount,
  protectingNotes,
}

/// User-visible protected-note initialization progress.
enum ProtectionProgress {
  gettingReady,
  checkingAccount,
  connecting,
  protectingNotes,
  addingDevice,
  verifying,
  almostThere,
}

/// User-visible recovery progress.
enum RecoveryProgress {
  checkingAccount,
  verifying,
  addingDevice,
  protectingNotes,
  almostThere,
}

enum SyncPhase {
  idle,
  resuming,
  checkingForUpdates,
  syncing,
  restarting,
  savingChanges,
  fetchingUpdates,
  uploadingMedia,
  complete,
  failed,
}

enum ExportPhase {
  idle,
  preparing,
  notes,
  labels,
  attachments,
  packaging,
  compressing,
  saving,
  complete,
  failed,
}

/// Typed sync presentation state. Technical per-note diagnostics remain in the
/// sync service logs and ledgers rather than leaking through this UI channel.
class SyncProgress {
  const SyncProgress(this.phase, {this.failedCount = 0});

  static const idle = SyncProgress(SyncPhase.idle);

  final SyncPhase phase;
  final int failedCount;

  bool get isEmpty => phase == SyncPhase.idle;
  bool get isSuccess => phase == SyncPhase.complete;
  bool get isFailure => phase == SyncPhase.failed;

  @override
  bool operator ==(Object other) =>
      other is SyncProgress &&
      other.phase == phase &&
      other.failedCount == failedCount;

  @override
  int get hashCode => Object.hash(phase, failedCount);
}
