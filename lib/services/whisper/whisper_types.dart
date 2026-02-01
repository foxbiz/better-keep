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
