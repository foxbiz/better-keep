/// Stub implementation for web platform where Whisper is not available.
/// This file is used on web to avoid importing dart:ffi which doesn't exist.
library;

export 'whisper_types.dart';

import 'whisper_types.dart';

/// Stub service for web platform - Whisper is not available on web
class WhisperService {
  WhisperService._();

  static final WhisperService instance = WhisperService._();

  /// Default model to use
  static const WhisperModelSize defaultModelSize = WhisperModelSize.tiny;

  /// Current model size
  WhisperModelSize get currentModelSize => defaultModelSize;

  /// Whether the service is available on this platform
  bool get isAvailable => false;

  /// Whether a download is in progress
  bool get isDownloading => false;

  /// Check if a model is downloaded
  Future<bool> isModelDownloaded([WhisperModelSize? modelSize]) async => false;

  /// Get the size of a downloaded model
  Future<int> getDownloadedModelSize([WhisperModelSize? modelSize]) async => 0;

  /// Initialize the Whisper instance with the specified model
  Future<bool> initialize([WhisperModelSize? modelSize]) async => false;

  /// Transcribe an audio file
  Future<String?> transcribe(String audioPath, {String? language}) async =>
      null;

  /// Delete a downloaded model
  Future<void> deleteModel([WhisperModelSize? modelSize]) async {}

  /// Download the model with progress callback
  Future<String?> downloadModel({
    WhisperModelSize? modelSize,
    void Function(int received, int total)? onProgress,
  }) async => null;

  /// Dispose the service
  void dispose() {}
}

/// Type alias for backwards compatibility with settings page
typedef WhisperModelService = WhisperService;
