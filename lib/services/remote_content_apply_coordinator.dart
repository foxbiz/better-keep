import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/async_operation_coalescer.dart';
import 'package:better_keep/services/remote_content_retry_ledger.dart';
import 'package:better_keep/services/remote_note_apply_result.dart';

enum RemoteContentHandlingDisposition { applied, waiting, deferred, exhausted }

class RemoteContentHandlingResult {
  const RemoteContentHandlingResult({
    required this.revision,
    required this.localId,
    required this.disposition,
    this.ledgerEntry,
  });

  final String revision;
  final int localId;
  final RemoteContentHandlingDisposition disposition;
  final RemoteContentRetryEntry? ledgerEntry;

  bool get checkpointSafe => true;
  bool get isApplied => disposition == RemoteContentHandlingDisposition.applied;
}

typedef RemoteContentAttempt =
    Future<RemoteNoteApplyResult> Function(int resolvedLocalId);
typedef RemoteContentLocalIdResolver =
    Future<int> Function(RemoteContentRetryEntry? existing);
typedef RemoteContentHandledCallback =
    Future<void> Function(RemoteContentHandlingResult result);

/// Owns attempt coalescing, per-document ordering, and durable retry updates.
class RemoteContentApplyCoordinator {
  RemoteContentApplyCoordinator(
    this._ledger, {
    AsyncOperationCoalescer<String, RemoteContentHandlingResult>? coalescer,
    AsyncKeyedSerializer<String>? serializer,
    DateTime Function()? now,
  }) : _coalescer = coalescer ?? AsyncOperationCoalescer(),
       _serializer = serializer ?? AsyncKeyedSerializer(),
       _now = now ?? DateTime.now;

  final RemoteContentRetryLedger _ledger;
  final AsyncOperationCoalescer<String, RemoteContentHandlingResult> _coalescer;
  final AsyncKeyedSerializer<String> _serializer;
  final DateTime Function() _now;

  Future<RemoteContentHandlingResult> handleAutomatic({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required RemoteContentLocalIdResolver resolveLocalId,
    required RemoteContentAttempt attempt,
    required RemoteContentHandledCallback onHandled,
  }) {
    final revisionKey = 'automatic:$userId:$remoteDocumentId:$revision';
    final documentKey = '$userId:$remoteDocumentId';
    return _coalescer.run(
      revisionKey,
      () => _serializer.run(
        documentKey,
        () => _handleAutomatic(
          userId: userId,
          remoteDocumentId: remoteDocumentId,
          revision: revision,
          resolveLocalId: resolveLocalId,
          attempt: attempt,
          onHandled: onHandled,
        ),
      ),
    );
  }

  Future<RemoteContentHandlingResult> _handleAutomatic({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required RemoteContentLocalIdResolver resolveLocalId,
    required RemoteContentAttempt attempt,
    required RemoteContentHandledCallback onHandled,
  }) async {
    var existing = await _ledger.get(userId, remoteDocumentId);
    if (existing != null && existing.revision == revision) {
      if (existing.state == RemoteContentRetryState.exhausted ||
          existing.state == RemoteContentRetryState.deferred ||
          (existing.nextRetryAt?.isAfter(_now().toUtc()) ?? false)) {
        final result = _fromEntry(existing);
        await onHandled(result);
        return result;
      }
    }

    final localId = await resolveLocalId(existing);
    if (existing != null && existing.revision != revision) {
      await _ledger.clear(userId, remoteDocumentId);
      existing = null;
    }

    final applyResult = await attempt(localId);
    late final RemoteContentHandlingResult handled;
    if (applyResult.isSuccess) {
      await _ledger.clear(userId, remoteDocumentId);
      handled = RemoteContentHandlingResult(
        revision: revision,
        localId: localId,
        disposition: RemoteContentHandlingDisposition.applied,
      );
    } else {
      final category =
          applyResult.category ?? RemoteNoteFailureCategory.invalidPayload;
      final code = applyResult.code ?? 'unknown-content-failure';
      final entry = applyResult.isDeferred
          ? await _ledger.recordDeferred(
              userId: userId,
              remoteDocumentId: remoteDocumentId,
              revision: revision,
              localId: localId,
              category: category,
              errorCode: code,
              now: _now(),
            )
          : await _ledger.recordAutomaticFailure(
              userId: userId,
              remoteDocumentId: remoteDocumentId,
              revision: revision,
              localId: localId,
              category: category,
              errorCode: code,
              permanent: applyResult.isPermanent,
              now: _now(),
            );
      handled = _fromEntry(entry);
    }
    await onHandled(handled);
    return handled;
  }

  Future<RemoteContentHandlingResult> handleManual({
    required String userId,
    required String remoteDocumentId,
    required String revision,
    required RemoteContentLocalIdResolver resolveLocalId,
    required RemoteContentAttempt attempt,
    required RemoteContentHandledCallback onHandled,
  }) {
    final revisionKey = 'manual:$userId:$remoteDocumentId:$revision';
    final documentKey = '$userId:$remoteDocumentId';
    return _coalescer.run(
      revisionKey,
      () => _serializer.run(documentKey, () async {
        final existing = await _ledger.get(userId, remoteDocumentId);
        final localId = await resolveLocalId(existing);
        final applyResult = await attempt(localId);
        late final RemoteContentHandlingResult handled;
        if (applyResult.isSuccess) {
          await _ledger.clear(userId, remoteDocumentId);
          handled = RemoteContentHandlingResult(
            revision: revision,
            localId: localId,
            disposition: RemoteContentHandlingDisposition.applied,
          );
        } else {
          final category =
              applyResult.category ?? RemoteNoteFailureCategory.invalidPayload;
          final code = applyResult.code ?? 'manual-content-retry-failed';
          final entry = applyResult.isDeferred
              ? await _ledger.recordDeferred(
                  userId: userId,
                  remoteDocumentId: remoteDocumentId,
                  revision: revision,
                  localId: localId,
                  category: category,
                  errorCode: code,
                  now: _now(),
                )
              : await _ledger.recordManualFailure(
                  userId: userId,
                  remoteDocumentId: remoteDocumentId,
                  revision: revision,
                  localId: localId,
                  category: category,
                  errorCode: code,
                  now: _now(),
                );
          handled = _fromEntry(entry);
        }
        await onHandled(handled);
        return handled;
      }),
    );
  }

  Future<void> waitForIdle() => _coalescer.waitForIdle();

  static RemoteContentHandlingResult _fromEntry(RemoteContentRetryEntry entry) {
    final disposition = switch (entry.state) {
      RemoteContentRetryState.waiting =>
        RemoteContentHandlingDisposition.waiting,
      RemoteContentRetryState.deferred =>
        RemoteContentHandlingDisposition.deferred,
      RemoteContentRetryState.exhausted =>
        RemoteContentHandlingDisposition.exhausted,
    };
    return RemoteContentHandlingResult(
      revision: entry.revision,
      localId: entry.localId,
      disposition: disposition,
      ledgerEntry: entry,
    );
  }
}
