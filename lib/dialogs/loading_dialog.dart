import 'dart:async';
import 'package:flutter/material.dart';

/// Configuration for the loading dialog
class LoadingDialogConfig {
  /// Message to display while loading
  final String message;

  /// Duration after which to show cancel button (default: 5 seconds)
  final Duration showCancelAfter;

  /// Duration after which to auto-timeout (default: 30 seconds)
  final Duration timeout;

  /// Message to show when timeout occurs
  final String timeoutMessage;

  const LoadingDialogConfig({
    required this.message,
    this.showCancelAfter = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 30),
    this.timeoutMessage = 'This is taking longer than expected.',
  });
}

/// Result from the loading operation
class LoadingDialogResult<T> {
  final bool success;
  final T? data;
  final String? error;
  final bool cancelled;
  final bool timedOut;

  const LoadingDialogResult({
    required this.success,
    this.data,
    this.error,
    this.cancelled = false,
    this.timedOut = false,
  });

  factory LoadingDialogResult.successful(T data) =>
      LoadingDialogResult(success: true, data: data);

  factory LoadingDialogResult.cancelled() =>
      const LoadingDialogResult(success: false, cancelled: true);

  factory LoadingDialogResult.timedOut() =>
      const LoadingDialogResult(success: false, timedOut: true);

  factory LoadingDialogResult.failed(String error) =>
      LoadingDialogResult(success: false, error: error);
}

/// Shows a loading dialog that can be cancelled and has a timeout.
///
/// [config] configures the loading dialog appearance and behavior.
/// [operation] is the async operation to perform. It receives a cancellation
/// token that the operation can check to abort early if needed.
///
/// Returns [LoadingDialogResult] with the operation result, or cancelled/timeout status.
Future<LoadingDialogResult<T>> showLoadingDialog<T>({
  required BuildContext context,
  required LoadingDialogConfig config,
  required Future<T> Function() operation,
}) async {
  // Create a completer to track if the dialog was cancelled or timed out
  final completer = Completer<LoadingDialogResult<T>>();

  // Track if dialog is still showing
  bool dialogActive = true;

  // Show the dialog
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: _LoadingDialogContent(
        config: config,
        onCancel: () {
          if (dialogActive) {
            dialogActive = false;
            Navigator.of(dialogContext).pop();
            if (!completer.isCompleted) {
              completer.complete(LoadingDialogResult.cancelled());
            }
          }
        },
      ),
    ),
  );

  // Set up timeout
  final timeoutTimer = Timer(config.timeout, () {
    if (dialogActive && !completer.isCompleted) {
      dialogActive = false;
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      completer.complete(LoadingDialogResult.timedOut());
    }
  });

  try {
    // Run the operation
    final result = await operation();

    // Cancel the timeout timer
    timeoutTimer.cancel();

    // Close dialog and return result if still active
    if (dialogActive) {
      dialogActive = false;
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      if (!completer.isCompleted) {
        completer.complete(LoadingDialogResult.successful(result));
      }
    }
  } catch (e) {
    // Cancel the timeout timer
    timeoutTimer.cancel();

    // Close dialog and return error if still active
    if (dialogActive) {
      dialogActive = false;
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      if (!completer.isCompleted) {
        completer.complete(LoadingDialogResult.failed(e.toString()));
      }
    }
  }

  return completer.future;
}

class _LoadingDialogContent extends StatefulWidget {
  final LoadingDialogConfig config;
  final VoidCallback onCancel;

  const _LoadingDialogContent({required this.config, required this.onCancel});

  @override
  State<_LoadingDialogContent> createState() => _LoadingDialogContentState();
}

class _LoadingDialogContentState extends State<_LoadingDialogContent> {
  bool _showCancel = false;
  bool _showTimeoutWarning = false;
  Timer? _cancelTimer;
  Timer? _warningTimer;

  @override
  void initState() {
    super.initState();
    // Show cancel button after specified duration
    _cancelTimer = Timer(widget.config.showCancelAfter, () {
      if (mounted) {
        setState(() => _showCancel = true);
      }
    });

    // Show timeout warning at 2/3 of timeout duration
    final warningDuration = Duration(
      milliseconds: (widget.config.timeout.inMilliseconds * 0.67).toInt(),
    );
    _warningTimer = Timer(warningDuration, () {
      if (mounted) {
        setState(() => _showTimeoutWarning = true);
      }
    });
  }

  @override
  void dispose() {
    _cancelTimer?.cancel();
    _warningTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(widget.config.message, textAlign: TextAlign.center),
              if (_showTimeoutWarning) ...[
                const SizedBox(height: 12),
                Text(
                  widget.config.timeoutMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (_showCancel) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
