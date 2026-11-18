import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_progress.dart';

/// Defers expensive projections during the initial download into an empty
/// library. A transfer always continues independently of its presentation.
class NoteSyncBatch {
  static const threshold = 20;
  static const _inactivityLimit = Duration(minutes: 2);
  static final _active = ValueNotifier(false);
  static ValueListenable<bool> get active => _active;
  static final _progress = ValueNotifier<NoteTransfer?>(null);
  static ValueListenable<NoteTransfer?> get progress => _progress;
  static final _runs = <_RestoreRun>{};
  static Completer<void>? _idle;
  static Future<void>? get pending => _idle?.future;
  int _generation = 0;

  void reset() {
    _generation++;
    for (final run in _runs.where((r) => identical(r.owner, this)).toList()) {
      _release(run);
    }
  }

  static void _release(_RestoreRun run) {
    run.timeout?.cancel();
    if (!_runs.remove(run)) return;
    _progress.value = _runs.firstOrNull?.latest;
    if (_runs.isEmpty) {
      final idle = _idle;
      _idle = null;
      _active.value = false;
      idle?.complete();
    }
  }

  Future<void> run(
    int noteCount,
    Future<void> Function(NoteTransferMeter) work, {
    NoteTransferStage stage = NoteTransferStage.downloading,
    Future<bool> Function()? isEmptyLibrary,
    void Function(NoteTransfer)? onProgress,
  }) async {
    final generation = _generation;
    var showRestore = false;
    if (stage == NoteTransferStage.downloading &&
        noteCount >= threshold &&
        isEmptyLibrary != null) {
      try {
        showRestore = await isEmptyLibrary();
      } catch (error) {
        // Presentation is optional. Let the guarded sync operation handle
        // database errors and complete its normal recovery lifecycle.
        if (kDebugMode) {
          debugPrint('Restore view unavailable (${error.runtimeType})');
        }
      }
    }
    _RestoreRun? restore;
    if (showRestore && generation == _generation) {
      restore = _RestoreRun(this);
      _runs.add(restore);
      _idle ??= Completer<void>();
      _active.value = true;
    }
    final run = restore;
    try {
      final meter = NoteTransferMeter(stage, noteCount, (value) {
        if (generation != _generation) return;
        if (run != null && _runs.contains(run)) {
          run.latest = value;
          run.timeout?.cancel();
          run.timeout = Timer(_inactivityLimit, () => _release(run));
          if (identical(_runs.first, run)) _progress.value = value;
        }
        onProgress?.call(value);
      });
      await work(meter);
      meter.flush();
    } finally {
      if (run != null) _release(run);
    }
  }
}

class _RestoreRun {
  _RestoreRun(this.owner);
  final NoteSyncBatch owner;
  NoteTransfer? latest;
  Timer? timeout;
}
