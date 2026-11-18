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
  checkingConnection,
  preparing,
  unavailable,
  waitingForApproval,
  signInRequired,
  providerSetupRequired,
  storageFull,
  deferred,
  uploadRestricted,
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

enum NoteTransferStage { checking, checkingUpdates, downloading, uploading }

typedef NoteTransfer = ({
  NoteTransferStage stage,
  int done,
  int? total,
  int? minutesLeft,
});

extension NoteTransferFraction on NoteTransfer {
  double? get fraction {
    final count = total;
    return count == null || count <= 0 ? null : (done / count).clamp(0.0, 1.0);
  }
}

/// Measures one transfer phase. Provider listing and later upload work have
/// independent costs. Transfers update at most twice a second between phase
/// boundaries. Checking reports its first result and final count.
class NoteTransferMeter {
  NoteTransferMeter(
    this.stage,
    this.total,
    this.publish, {
    Duration Function()? elapsed,
  }) {
    final clock = Stopwatch()..start();
    _elapsed = elapsed ?? (() => clock.elapsed);
    _emit();
  }

  final NoteTransferStage stage;
  final int? total;
  final void Function(NoteTransfer) publish;
  late final Duration Function() _elapsed;
  Duration _last = Duration.zero;
  int _done = 0;
  int _excluded = 0;
  int _publishedItems = 0;
  final _samples = <({Duration at, int done})>[];

  // A deferred or superseded revision is no longer part of this pass.
  void exclude([int count = 1]) {
    _excluded += count;
    _publishIfDue();
  }

  void flush() {
    if (_publishedItems != _done + _excluded) _emit();
  }

  void advance([int count = 1]) {
    if (count <= 0) return;
    _done += count;
    final at = _elapsed();
    // Retain one completion snapshot per second so fast transfers still span
    // enough time to estimate throughput. Initial preparation is excluded.
    if (_samples.isNotEmpty && _samples.last.at.inSeconds == at.inSeconds) {
      _samples.removeLast();
    }
    _samples.add((at: at, done: _done));
    if (_samples.length > 32) _samples.removeAt(0);
    _publishIfDue();
  }

  void _publishIfDue() {
    if (stage == NoteTransferStage.checking ||
        stage == NoteTransferStage.checkingUpdates) {
      if (_done > 0 && _publishedItems == 0) _emit();
      return;
    }
    if (_done + _excluded == total ||
        _elapsed() - _last >= const Duration(milliseconds: 500)) {
      _emit();
    }
  }

  void _emit() {
    _last = _elapsed();
    // A concurrent local change can expand a previously counted upload queue.
    _publishedItems = _done + _excluded;
    final expected = total;
    if (expected == null) {
      publish((stage: stage, done: _done, total: null, minutesLeft: null));
      return;
    }
    final eligible = expected - _excluded;
    final knownTotal = eligible > 0 && _done <= eligible ? eligible : null;
    final remaining = eligible - _done;
    int? minutes;
    if (_samples.length >= 4 && remaining > 0) {
      final first = _samples.first;
      final completed = _done - first.done;
      final interval = _samples.last.at - first.at;
      if (completed >= 8 && interval >= const Duration(seconds: 10)) {
        final seconds = interval.inMilliseconds * remaining / completed / 1000;
        minutes = seconds < 60 ? 0 : (seconds / 60).round();
      }
    }
    if (expected <= 0) return;
    publish((
      stage: stage,
      done: stage == NoteTransferStage.downloading ? _publishedItems : _done,
      total: stage == NoteTransferStage.downloading ? total : knownTotal,
      minutesLeft: minutes,
    ));
  }
}

/// Typed sync presentation state. Technical per-note diagnostics remain in the
/// sync service logs and ledgers rather than leaking through this UI channel.
class SyncProgress {
  const SyncProgress(this.phase, {this.failedCount = 0, this.notes});

  static const idle = SyncProgress(SyncPhase.idle);

  final SyncPhase phase;
  final int failedCount;
  final NoteTransfer? notes;

  bool get isEmpty => phase == SyncPhase.idle;
  bool get isSuccess => phase == SyncPhase.complete;
  bool get isFailure =>
      phase == SyncPhase.failed || phase == SyncPhase.storageFull;
  bool get isActive => const {
    SyncPhase.checkingConnection,
    SyncPhase.preparing,
    SyncPhase.resuming,
    SyncPhase.checkingForUpdates,
    SyncPhase.syncing,
    SyncPhase.restarting,
    SyncPhase.savingChanges,
    SyncPhase.fetchingUpdates,
    SyncPhase.uploadingMedia,
  }.contains(phase);

  @override
  bool operator ==(Object other) =>
      other is SyncProgress &&
      other.phase == phase &&
      other.failedCount == failedCount &&
      other.notes == notes;

  @override
  int get hashCode => Object.hash(phase, failedCount, notes);
}
