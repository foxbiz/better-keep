/// Stub implementation for web platform where Whisper is not available.
/// This file is used on web to avoid importing dart:ffi which doesn't exist.
library;

/// Whisper model sizes available for download
enum WhisperModelSize { tiny, base, small, medium, largeV1, largeV2 }

extension WhisperModelSizeExtension on WhisperModelSize {
  String get displayName {
    switch (this) {
      case WhisperModelSize.tiny:
        return 'Tiny (~75 MB)';
      case WhisperModelSize.base:
        return 'Base (~142 MB)';
      case WhisperModelSize.small:
        return 'Small (~466 MB)';
      case WhisperModelSize.medium:
        return 'Medium (~1.5 GB)';
      case WhisperModelSize.largeV1:
        return 'Large V1 (~3 GB)';
      case WhisperModelSize.largeV2:
        return 'Large V2 (~3 GB)';
    }
  }

  String get fileName {
    switch (this) {
      case WhisperModelSize.tiny:
        return 'ggml-tiny.bin';
      case WhisperModelSize.base:
        return 'ggml-base.bin';
      case WhisperModelSize.small:
        return 'ggml-small.bin';
      case WhisperModelSize.medium:
        return 'ggml-medium.bin';
      case WhisperModelSize.largeV1:
        return 'ggml-large-v1.bin';
      case WhisperModelSize.largeV2:
        return 'ggml-large-v2.bin';
    }
  }

  int get approximateSizeBytes {
    switch (this) {
      case WhisperModelSize.tiny:
        return 75 * 1024 * 1024; // 75 MB
      case WhisperModelSize.base:
        return 142 * 1024 * 1024; // 142 MB
      case WhisperModelSize.small:
        return 466 * 1024 * 1024; // 466 MB
      case WhisperModelSize.medium:
        return 1536 * 1024 * 1024; // 1.5 GB
      case WhisperModelSize.largeV1:
        return 3072 * 1024 * 1024; // 3 GB
      case WhisperModelSize.largeV2:
        return 3072 * 1024 * 1024; // 3 GB
    }
  }
}

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
