import 'dart:async';
import 'dart:io';
import 'package:better_keep/pages/file_preview_page.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Service to handle intents for opening/sharing files
class IntentHandlerService {
  static IntentHandlerService? _instance;
  static IntentHandlerService get instance {
    _instance ??= IntentHandlerService._();
    return _instance!;
  }

  IntentHandlerService._();

  StreamSubscription? _intentDataStreamSubscription;
  bool _initialized = false;

  /// Initialize intent handlers
  void init() {
    if (_initialized) {
      AppLogger.log('[IntentHandler] Already initialized, skipping');
      return;
    }
    if (kIsWeb) return; // Web doesn't support intents

    if (!Platform.isAndroid && !Platform.isIOS) {
      return; // Only Android and iOS support intents
    }

    AppLogger.log('[IntentHandler] Initializing intent handlers');
    _initialized = true;

    // Listen for files shared while app is running
    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          (files) {
            AppLogger.log(
              '[IntentHandler] Stream received ${files.length} file(s)',
            );
            _handleSharedFiles(files);
          },
          onError: (err) {
            AppLogger.error(
              '[IntentHandler] Error receiving shared files',
              err,
            );
          },
        );

    // Check for files shared when app was closed
    _checkInitialIntent();
  }

  /// Check for pending intents - call this when app resumes
  Future<void> checkPendingIntents() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    AppLogger.log('[IntentHandler] Checking for pending intents on resume');
    await _checkInitialIntent();
  }

  /// Check if app was opened with shared content
  Future<void> _checkInitialIntent() async {
    try {
      // Check for shared files
      final sharedFiles = await ReceiveSharingIntent.instance.getInitialMedia();
      if (sharedFiles.isNotEmpty) {
        AppLogger.log(
          '[IntentHandler] App opened with ${sharedFiles.length} shared file(s)',
        );
        _handleSharedFiles(sharedFiles);
        // Reset the intent so it doesn't trigger again
        ReceiveSharingIntent.instance.reset();
      }
    } catch (e) {
      AppLogger.error('[IntentHandler] Error checking initial intent', e);
    }
  }

  /// Handle shared files (e.g., .txt, .md files)
  void _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) {
      AppLogger.log('[IntentHandler] No files received');
      return;
    }

    AppLogger.log('[IntentHandler] Processing ${files.length} shared file(s)');

    for (final file in files) {
      try {
        final path = file.path;
        final type = file.type;
        final mimeType = file.mimeType;

        AppLogger.log(
          '[IntentHandler] File: $path, Type: $type, MimeType: $mimeType',
        );

        // Skip deep link URIs (betterkeep://, http://, https://) - these are handled by app_links
        if (_isDeepLinkUri(path)) {
          AppLogger.log('[IntentHandler] Skipping deep link URI: $path');
          continue;
        }

        // Check if it's a text or markdown file (by extension or mime type)
        if (!_isTextOrMarkdownFile(path, mimeType)) {
          AppLogger.log('[IntentHandler] Skipping non-text file: $path');
          _showError(
            'Unsupported file type. Only .txt and .md files are supported.',
          );
          continue;
        }

        // Read file content
        final result = await _readFile(path);
        if (result.error != null) {
          AppLogger.log('[IntentHandler] ${result.error}: $path');
          _showError(result.error!);
          continue;
        }

        final fileContent = result.content;
        if (fileContent == null || fileContent.isEmpty) {
          AppLogger.log('[IntentHandler] File is empty: $path');
          _showError('The file is empty.');
          continue;
        }

        // Extract filename
        final fileName = path.split('/').last;
        final isMarkdown = _isMarkdownFile(path);

        // Navigate to preview page
        _navigateToPreview(
          fileName: fileName,
          content: fileContent,
          isMarkdown: isMarkdown,
        );
      } catch (e) {
        AppLogger.error('[IntentHandler] Error processing file', e);
        _showError('An error occurred while opening the file.');
      }
    }
  }

  /// Check if the file is a markdown file
  bool _isMarkdownFile(String path) {
    final lowerPath = path.toLowerCase();
    return lowerPath.endsWith('.md') || lowerPath.endsWith('.markdown');
  }

  /// Check if the path is a deep link URI (not a file)
  bool _isDeepLinkUri(String path) {
    final lowerPath = path.toLowerCase();
    // Skip custom scheme deep links and web URLs
    return lowerPath.startsWith('betterkeep://') ||
        lowerPath.startsWith('http://') ||
        lowerPath.startsWith('https://');
  }

  /// Check if the file is a text or markdown file
  bool _isTextOrMarkdownFile(String path, String? mimeType) {
    final lowerPath = path.toLowerCase();
    final hasTextExtension =
        lowerPath.endsWith('.txt') ||
        lowerPath.endsWith('.md') ||
        lowerPath.endsWith('.markdown');

    // Also check mime type for content:// URIs where extension might not be available
    final hasTextMimeType =
        mimeType != null &&
        (mimeType.startsWith('text/') ||
            mimeType == 'application/octet-stream');

    return hasTextExtension || hasTextMimeType;
  }

  /// Read file content as string
  Future<_FileReadResult> _readFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return _FileReadResult(error: 'File not found.');
      }

      // Check file size (limit to 5MB for safety)
      final fileSize = await file.length();
      if (fileSize > 5 * 1024 * 1024) {
        AppLogger.log('[IntentHandler] File too large: $fileSize bytes');
        return _FileReadResult(error: 'File is too large (max 5MB).');
      }

      final content = await file.readAsString();
      return _FileReadResult(content: content);
    } catch (e) {
      AppLogger.error('[IntentHandler] Error reading file: $path', e);
      return _FileReadResult(error: 'Could not read the file.');
    }
  }

  /// Show error message to user
  void _showError(String message) {
    final scaffoldMessenger = AppState.scaffoldMessengerKey.currentState;
    if (scaffoldMessenger != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Navigate to the file preview page
  void _navigateToPreview({
    required String fileName,
    required String content,
    required bool isMarkdown,
  }) {
    final context = AppState.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => FilePreviewPage(
            fileName: fileName,
            content: content,
            isMarkdown: isMarkdown,
          ),
        ),
      );
    } else {
      AppLogger.log('[IntentHandler] Cannot navigate - context not available');
      _showError('Could not open the file. Please try again.');
    }
  }

  /// Dispose of subscriptions
  void dispose() {
    _intentDataStreamSubscription?.cancel();
  }
}

/// Result class for file reading operation
class _FileReadResult {
  final String? content;
  final String? error;

  _FileReadResult({this.content, this.error});
}
