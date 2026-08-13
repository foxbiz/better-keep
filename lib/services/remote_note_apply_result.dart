enum RemoteNoteApplyDisposition {
  success,
  retryableFailure,
  permanentFailure,
  deferredDependency,
}

enum RemoteNoteFailureCategory {
  attachment,
  decryption,
  invalidPayload,
  localApply,
}

class RemoteNoteApplyResult {
  const RemoteNoteApplyResult._(this.disposition, {this.category, this.code});

  const RemoteNoteApplyResult.success()
    : this._(RemoteNoteApplyDisposition.success);

  const RemoteNoteApplyResult.retryable(
    RemoteNoteFailureCategory category,
    String code,
  ) : this._(
        RemoteNoteApplyDisposition.retryableFailure,
        category: category,
        code: code,
      );

  const RemoteNoteApplyResult.permanent(
    RemoteNoteFailureCategory category,
    String code,
  ) : this._(
        RemoteNoteApplyDisposition.permanentFailure,
        category: category,
        code: code,
      );

  const RemoteNoteApplyResult.deferred(
    RemoteNoteFailureCategory category,
    String code,
  ) : this._(
        RemoteNoteApplyDisposition.deferredDependency,
        category: category,
        code: code,
      );

  final RemoteNoteApplyDisposition disposition;
  final RemoteNoteFailureCategory? category;
  final String? code;

  bool get isSuccess => disposition == RemoteNoteApplyDisposition.success;
  bool get isRetryable =>
      disposition == RemoteNoteApplyDisposition.retryableFailure;
  bool get isPermanent =>
      disposition == RemoteNoteApplyDisposition.permanentFailure;
  bool get isDeferred =>
      disposition == RemoteNoteApplyDisposition.deferredDependency;
}
