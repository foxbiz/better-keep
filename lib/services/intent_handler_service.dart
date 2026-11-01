import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/content_preview_page.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/shared_image_note_service.dart';
import 'package:better_keep/services/ios_image_share_inbox.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Called only after startup services settle. Backgrounded engines may not
/// produce a frame, so rendering must not leave imports waiting forever.
void completeImageIntentStartup(Completer<void> ready) {
  final watchdog = Timer(const Duration(seconds: 5), () {
    if (!ready.isCompleted) ready.complete();
  });
  WidgetsBinding.instance.addPostFrameCallback((_) {
    watchdog.cancel();
    if (!ready.isCompleted) ready.complete();
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}

/// Service to handle intents for opening/sharing files
class IntentHandlerService {
  static IntentHandlerService? _instance;
  static IntentHandlerService get instance {
    _instance ??= IntentHandlerService();
    return _instance!;
  }

  IntentHandlerService({
    SharedImageNoteService? imageNotes,
    ReceiveSharingIntent? sharingIntent,
    this.importIosImages,
    void Function(Note)? openImageNote,
  }) : _imageNotes = imageNotes ?? SharedImageNoteService(),
       _openImageNote = openImageNote ?? _openImageEditor,
       _sharingIntent = sharingIntent ?? ReceiveSharingIntent.instance;

  final ReceiveSharingIntent _sharingIntent;
  final Future<int> Function()? importIosImages;
  final void Function(Note) _openImageNote;
  late final _iosInbox = IosImageShareInbox(
    _imageNotes,
    onImportFailed: _showImageError,
    onImported: _openImageNote,
    onBusy: _setImageImportBusy,
  );
  final ValueNotifier<bool> importingImages = ValueNotifier(false);
  int _imageImports = 0;

  void _setImageImportBusy(bool busy) {
    _imageImports += busy ? 1 : -1;
    importingImages.value = _imageImports > 0;
  }

  bool _checkAgain = false;
  bool _inboxUnavailable = false;
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final SharedImageNoteService _imageNotes;
  Future<void>? _initialIntentCheck;
  Future<void> _ready = Future.value();
  Completer<void> _readyGate = Completer<void>()..complete();
  Future<void> _sharedFilesTail = Future.value();

  StreamSubscription? _intentDataStreamSubscription;
  bool _initialized = false;

  /// Subscribe immediately; defer imports until startup completes [ready].
  void init({Future<void>? ready}) {
    if (!_supported) return;
    if (ready != null && !identical(ready, _ready)) {
      _ready = ready;
      final previous = _readyGate;
      final next = Completer<void>();
      _readyGate = next;
      if (!previous.isCompleted) previous.complete();
      unawaited(
        ready.then<void>(
          (_) {
            if (!next.isCompleted) next.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!next.isCompleted) next.completeError(error, stack);
          },
        ),
      );
    }
    if (_initialized) {
      AppLogger.log('[IntentHandler] Already initialized, skipping');
      unawaited(checkPendingIntents().catchError(_reportUnhandledShare));
      return;
    }

    AppLogger.log('[IntentHandler] Initializing intent handlers');
    _initialized = true;

    // Listen for files shared while app is running
    _intentDataStreamSubscription = _sharingIntent.getMediaStream().listen(
      (files) {
        AppLogger.log(
          '[IntentHandler] Stream received ${files.length} file(s)',
        );
        unawaited(handleSharedFiles(files).catchError(_reportUnhandledShare));
      },
      onError: (err) {
        AppLogger.error('[IntentHandler] Error receiving shared files', err);
      },
    );

    // Check for files shared when app was closed
    unawaited(checkPendingIntents().catchError(_reportUnhandledShare));
  }

  /// Check for pending intents - call this when app resumes
  Future<void> checkPendingIntents() async {
    if (!_supported || !_initialized) return;

    AppLogger.log('[IntentHandler] Checking for pending intents on resume');
    await _checkInitialIntent();
  }

  Future<void> _waitUntilReady() async {
    while (true) {
      final gate = _readyGate;
      // A remounted startup owner can replace an abandoned readiness future.
      await gate.future;
      if (identical(gate, _readyGate)) return;
    }
  }

  void _reportUnhandledShare(Object error, StackTrace stack) {
    AppLogger.error(
      '[IntentHandler] Could not process shared content',
      error,
      stack,
    );
  }

  /// Check if app was opened with shared content
  Future<void> _checkInitialIntent() {
    _checkAgain = true;
    return _initialIntentCheck ??= _drainInitialIntents().whenComplete(() {
      _initialIntentCheck = null;
    });
  }

  Future<void> _drainInitialIntents() async {
    while (_checkAgain) {
      _checkAgain = false;
      await _readInitialIntent();
    }
  }

  Future<void> _readInitialIntent() async {
    await _waitUntilReady();
    if (defaultTargetPlatform == TargetPlatform.iOS && !_inboxUnavailable) {
      try {
        await (importIosImages ?? _iosInbox.importPending)();
      } catch (error, stack) {
        if (error is PlatformException &&
            error.code == 'image_share_unavailable') {
          _inboxUnavailable = true;
        }
        AppLogger.error(
          '[IntentHandler] Image inbox unavailable',
          error,
          stack,
        );
      }
    }
    try {
      // Check for shared files
      final sharedFiles = List<SharedMediaFile>.of(
        await _sharingIntent.getInitialMedia(),
      );
      if (sharedFiles.isNotEmpty) {
        AppLogger.log(
          '[IntentHandler] App opened with ${sharedFiles.length} shared file(s)',
        );
        // Reset the intent so it doesn't trigger again
        await _sharingIntent.reset();
        await handleSharedFiles(sharedFiles);
      }
    } catch (e) {
      AppLogger.error('[IntentHandler] Error checking initial intent', e);
      _showError(currentAppLocalizations().couldNotOpenFile);
    }
  }

  /// Handle one share, grouping its images into a single note.
  Future<void> handleSharedFiles(List<SharedMediaFile> files) {
    final batch = List<SharedMediaFile>.of(files);
    final result = _sharedFilesTail.then((_) => _handleSharedFiles(batch));
    // Initial intents and stream events share one queue. A failed batch must
    // not block later shares or allow multiple image decoders to overlap.
    _sharedFilesTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    await _waitUntilReady();
    if (files.isEmpty) {
      AppLogger.log('[IntentHandler] No files received');
      return;
    }

    AppLogger.log('[IntentHandler] Processing ${files.length} shared file(s)');

    final images = files
        .where((file) => !_isDeepLinkUri(file.path))
        .where(SharedImageNoteService.isImage)
        .toList();
    if (images.isNotEmpty) {
      _setImageImportBusy(true);
      try {
        final note = await _imageNotes.create(images);
        _openImageNote(note);
      } catch (error, stackTrace) {
        AppLogger.error(
          '[IntentHandler] Error creating shared image note',
          error,
          stackTrace,
        );
        _showImageError(error);
      } finally {
        _setImageImportBusy(false);
      }
    }

    final imagePaths = images.map((image) => image.path).toSet();
    for (final file in files) {
      if (imagePaths.contains(file.path)) continue;
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

        // Handle shared text (from text selection or share menu)
        if (type == SharedMediaType.text) {
          AppLogger.log('[IntentHandler] Handling shared text');
          await _createNoteFromSharedText(path);
          continue;
        }

        // Check if it's a text or markdown file (by extension or mime type)
        if (!_isTextOrMarkdownFile(path, mimeType)) {
          AppLogger.log('[IntentHandler] Skipping non-text file: $path');
          _showFileError(_SharedFileFailure.unsupportedType);
          continue;
        }

        // Read file content
        final result = await _readFile(path);
        if (result.failure != null) {
          AppLogger.log('[IntentHandler] ${result.failure!.name}: $path');
          _showFileError(result.failure!);
          continue;
        }

        final fileContent = result.content;
        if (fileContent == null || fileContent.isEmpty) {
          AppLogger.log('[IntentHandler] File is empty: $path');
          _showFileError(_SharedFileFailure.empty);
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
          labelName: Label.sharedFileLabelName,
        );
      } catch (e) {
        AppLogger.error('[IntentHandler] Error processing file', e);
        _showFileError(_SharedFileFailure.openFailed);
      }
    }
  }

  static void _openImageEditor(Note note) {
    final navigator = AppState.navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return;
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(builder: (_) => NoteEditor(note: note)),
      ),
    );
  }

  void _showImageError(Object error) {
    final l10n = currentAppLocalizations();
    if (error is SharedImagePathCollision) {
      _showError(l10n.sharedImageNamesConflict);
      return;
    }
    _showError(
      error is SharedImageImportException
          ? l10n.sharedImageImportFailed(error.fileName)
          : l10n.failedToCreateImageNote,
    );
  }

  /// Create a note directly from shared text (silently saves)
  Future<void> _createNoteFromSharedText(String sharedText) async {
    sharedText = sharedText.trim();
    if (sharedText.isEmpty) {
      AppLogger.log('[IntentHandler] Shared text is empty');
      return;
    }

    try {
      // Create Quill Delta for plain text
      final delta = <Map<String, dynamic>>[];

      // Add content
      delta.add({'insert': "\n$sharedText\n"});

      // Get or create the "Shared Text" system label
      final label = await Label.getOrCreateSystemLabel(
        Label.sharedTextLabelName,
      );

      // Create and save the note with the system label
      final note = Note(
        title: '',
        content: json.encode(delta),
        plainText: sharedText,
        labels: label.name,
      );
      await note.save();

      AppLogger.log(
        '[IntentHandler] Created note from shared text: ${note.id}',
      );

      // Show confirmation
      _showSuccess(currentAppLocalizations().noteSaved);
    } catch (e) {
      AppLogger.error(
        '[IntentHandler] Error creating note from shared text',
        e,
      );
      _showError(currentAppLocalizations().failedSaveNote);
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
        return const _FileReadResult(failure: _SharedFileFailure.notFound);
      }

      // Check file size (limit to 5MB for safety)
      final fileSize = await file.length();
      if (fileSize > 5 * 1024 * 1024) {
        AppLogger.log('[IntentHandler] File too large: $fileSize bytes');
        return const _FileReadResult(failure: _SharedFileFailure.tooLarge);
      }

      final content = await file.readAsString();
      return _FileReadResult(content: content);
    } catch (e) {
      AppLogger.error('[IntentHandler] Error reading file: $path', e);
      return const _FileReadResult(failure: _SharedFileFailure.readFailed);
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

  void _showFileError(_SharedFileFailure failure) {
    final l10n = currentAppLocalizations();
    final message = switch (failure) {
      _SharedFileFailure.unsupportedType => l10n.unsupportedTextFile,
      _SharedFileFailure.empty => l10n.sharedFileEmpty,
      _SharedFileFailure.notFound => l10n.fileNotFound,
      _SharedFileFailure.tooLarge => l10n.fileTooLarge,
      _SharedFileFailure.readFailed => l10n.couldNotReadFile,
      _SharedFileFailure.openFailed => l10n.couldNotOpenFile,
    };
    _showError(message);
  }

  /// Show success message to user
  void _showSuccess(String message) {
    final scaffoldMessenger = AppState.scaffoldMessengerKey.currentState;
    if (scaffoldMessenger != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Navigate to the content preview page
  void _navigateToPreview({
    required String fileName,
    required String content,
    required bool isMarkdown,
    String? labelName,
  }) {
    final context = AppState.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ContentPreviewPage(
            title: fileName,
            content: content,
            isMarkdown: isMarkdown,
            labelName: labelName,
          ),
        ),
      );
    } else {
      AppLogger.log('[IntentHandler] Cannot navigate - context not available');
      _showFileError(_SharedFileFailure.openFailed);
    }
  }

  /// Dispose of subscriptions
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _initialized = false;
  }
}

/// Result class for file reading operation
class _FileReadResult {
  final String? content;
  final _SharedFileFailure? failure;

  const _FileReadResult({this.content, this.failure});
}

enum _SharedFileFailure {
  unsupportedType,
  empty,
  notFound,
  tooLarge,
  readFailed,
  openFailed,
}
