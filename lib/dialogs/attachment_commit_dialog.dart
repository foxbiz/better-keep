import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';

enum AttachmentCommitFailureAction { retry, discard }

typedef AttachmentSourceDiscard = Future<void> Function(String sourcePath);

final Set<String> _activeAttachmentCommits = <String>{};

void showAttachmentProcessingDialog(BuildContext context, String message) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(message),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void dismissAttachmentProcessingDialog(BuildContext context) {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (navigator.canPop()) navigator.pop();
}

/// Awaits a complete note attachment commit and offers an explicit retry or
/// discard choice without ever claiming success early.
Future<bool> commitAttachmentWithRetry({
  required BuildContext context,
  required String sourcePath,
  required Future<void> Function() commit,
  Future<void> Function()? beforeFailurePrompt,
  Future<void> Function()? beforeRetry,
  AttachmentSourceDiscard? discardSource,
  UncommittedAttachmentSourceLease? sourceLease,
}) async {
  if (sourceLease != null && sourceLease.sourcePath != sourcePath) {
    throw ArgumentError.value(
      sourceLease.sourcePath,
      'sourceLease',
      'The prepared source lease must match sourcePath',
    );
  }
  if (!_activeAttachmentCommits.add(sourcePath)) {
    sourceLease?.relinquishToExistingCommit();
    return false;
  }
  sourceLease?.transferToCommit();
  var committed = false;
  try {
    while (true) {
      try {
        await commit();
        committed = true;
        sourceLease?.markCommitted();
        return true;
      } catch (error, stackTrace) {
        AppLogger.error('Failed to add attachment to note', error, stackTrace);
        try {
          await beforeFailurePrompt?.call();
        } catch (callbackError, callbackStackTrace) {
          AppLogger.error(
            'Failed to prepare the attachment failure prompt',
            callbackError,
            callbackStackTrace,
          );
          return false;
        }
        if (!context.mounted) return false;

        AttachmentCommitFailureAction? action;
        try {
          action = await showDialog<AttachmentCommitFailureAction>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: Text(dialogContext.l10n.attachmentCommitFailedTitle),
              content: Text(dialogContext.l10n.attachmentCommitFailedMessage),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    AttachmentCommitFailureAction.discard,
                  ),
                  child: Text(dialogContext.l10n.discard),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    AttachmentCommitFailureAction.retry,
                  ),
                  child: Text(dialogContext.l10n.retry),
                ),
              ],
            ),
          );
        } catch (dialogError, dialogStackTrace) {
          AppLogger.error(
            'Failed to show the attachment failure prompt',
            dialogError,
            dialogStackTrace,
          );
          return false;
        }

        if (action != AttachmentCommitFailureAction.retry) {
          return false;
        }
        try {
          await beforeRetry?.call();
        } catch (callbackError, callbackStackTrace) {
          AppLogger.error(
            'Failed to prepare an attachment retry',
            callbackError,
            callbackStackTrace,
          );
          return false;
        }
        if (!context.mounted) return false;
      }
    }
  } finally {
    _activeAttachmentCommits.remove(sourcePath);
    if (!committed) {
      try {
        if (sourceLease != null) {
          await sourceLease.releaseAfterFailedCommit();
        } else {
          await (discardSource ?? _discardUncommittedSource)(sourcePath);
        }
      } catch (error, stackTrace) {
        AppLogger.error(
          'Could not safely discard uncommitted attachment source',
          error,
          stackTrace,
        );
      }
    }
  }
}

Future<void> _discardUncommittedSource(String sourcePath) async {
  try {
    final cleaned = await scheduleUncommittedAttachmentSourceCleanup(
      sourcePath,
    );
    if (!cleaned) {
      AppLogger.log('Deferred cleanup of an uncommitted attachment source');
    }
  } catch (error, stackTrace) {
    // Preservation is safer than deleting when reference discovery fails.
    AppLogger.error(
      'Could not safely discard uncommitted attachment source',
      error,
      stackTrace,
    );
  }
}
