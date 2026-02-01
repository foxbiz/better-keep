import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

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

  WhisperModel get whisperModel {
    switch (this) {
      case WhisperModelSize.tiny:
        return WhisperModel.tiny;
      case WhisperModelSize.base:
        return WhisperModel.base;
      case WhisperModelSize.small:
        return WhisperModel.small;
      case WhisperModelSize.medium:
        return WhisperModel.medium;
      case WhisperModelSize.largeV1:
        return WhisperModel.largeV1;
      case WhisperModelSize.largeV2:
        return WhisperModel.largeV2;
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

/// Service for managing Whisper model and transcription
/// Also exported as WhisperModelService for backwards compatibility
class WhisperService {
  WhisperService._();

  static final WhisperService instance = WhisperService._();

  /// Default model to use
  static const WhisperModelSize defaultModelSize = WhisperModelSize.tiny;

  /// Current model size
  WhisperModelSize _currentModelSize = defaultModelSize;
  WhisperModelSize get currentModelSize => _currentModelSize;

  /// Whisper instance
  Whisper? _whisper;

  /// Whether the service is available on this platform
  bool get isAvailable =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Whether a download is in progress
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  /// Check if a model is downloaded
  Future<bool> isModelDownloaded([WhisperModelSize? modelSize]) async {
    if (!isAvailable) return false;

    modelSize ??= _currentModelSize;
    final modelPath = await _getModelPath(modelSize);
    final file = File(modelPath);
    return file.existsSync();
  }

  /// Get the path where whisper_flutter_new stores models
  /// This must match the package's internal storage location
  Future<String> _getModelPath(WhisperModelSize modelSize) async {
    // whisper_flutter_new uses different directories per platform:
    // - Android: getApplicationSupportDirectory()
    // - iOS/macOS: getLibraryDirectory()
    final Directory modelDir;
    if (Platform.isAndroid) {
      modelDir = await getApplicationSupportDirectory();
    } else {
      // iOS and macOS
      modelDir = await getLibraryDirectory();
    }
    return '${modelDir.path}/${modelSize.fileName}';
  }

  /// Get the size of a downloaded model
  Future<int> getDownloadedModelSize([WhisperModelSize? modelSize]) async {
    modelSize ??= _currentModelSize;
    final modelPath = await _getModelPath(modelSize);
    final file = File(modelPath);
    if (file.existsSync()) {
      return file.lengthSync();
    }
    return 0;
  }

  /// Initialize the Whisper instance with the specified model
  /// The model must already be downloaded
  Future<bool> initialize([WhisperModelSize? modelSize]) async {
    if (!isAvailable) return false;

    modelSize ??= _currentModelSize;
    _currentModelSize = modelSize;

    // Check if model is downloaded first
    final downloaded = await isModelDownloaded(modelSize);
    if (!downloaded) {
      debugPrint('Whisper model not downloaded yet');
      return false;
    }

    try {
      // Create the whisper instance pointing to our model directory
      _whisper = Whisper(
        model: modelSize.whisperModel,
        downloadHost:
            'https://huggingface.co/ggerganov/whisper.cpp/resolve/main',
      );

      // Verify the model is accessible by getting version
      final version = await _whisper!.getVersion();
      debugPrint('Whisper initialized with version: $version');

      return true;
    } catch (e) {
      debugPrint('Failed to initialize Whisper: $e');
      _whisper = null;
      return false;
    }
  }

  /// Transcribe an audio file
  /// Returns the transcription text or null if failed
  Future<String?> transcribe(String audioPath, {String? language}) async {
    if (_whisper == null) {
      final initialized = await initialize();
      if (!initialized) return null;
    }

    try {
      final result = await _whisper!.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioPath,
          isTranslate: false, // Keep original language
          isNoTimestamps: true,
          splitOnWord: true,
        ),
      );

      // The result is a WhisperTranscribeResponse object
      final text = result.text;
      if (text.isNotEmpty) {
        return text.trim();
      }

      return null;
    } catch (e) {
      debugPrint('Whisper transcription failed: $e');
      return null;
    }
  }

  /// Delete a downloaded model
  Future<void> deleteModel([WhisperModelSize? modelSize]) async {
    modelSize ??= _currentModelSize;
    final modelPath = await _getModelPath(modelSize);
    final file = File(modelPath);
    if (file.existsSync()) {
      await file.delete();
    }

    // Clear whisper instance if it was using this model
    if (modelSize == _currentModelSize) {
      _whisper = null;
    }
  }

  /// Download the model with progress callback
  /// This is used by the settings page to show download progress
  /// Returns the model path on success, null on failure
  Future<String?> downloadModel({
    WhisperModelSize? modelSize,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!isAvailable) return null;

    modelSize ??= _currentModelSize;
    _currentModelSize = modelSize;
    _isDownloading = true;

    try {
      final modelPath = await _getModelPath(modelSize);
      final modelFile = File(modelPath);

      // Check if already downloaded
      if (modelFile.existsSync()) {
        _isDownloading = false;
        // Initialize whisper with the existing model
        await initialize(modelSize);
        return modelPath;
      }

      // Download URL from HuggingFace
      const downloadHost =
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';
      final url = '$downloadHost/${modelSize.fileName}';

      debugPrint('Downloading Whisper model from: $url');

      // Create HTTP client and make request
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client.send(request);

        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }

        final totalBytes =
            response.contentLength ?? modelSize.approximateSizeBytes;
        int receivedBytes = 0;

        // Create file and write chunks with proper cleanup
        final sink = modelFile.openWrite();
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            onProgress?.call(receivedBytes, totalBytes);
          }
          await sink.close();
        } catch (e) {
          await sink.close();
          // Clean up partial file on download failure
          if (modelFile.existsSync()) {
            try {
              await modelFile.delete();
            } catch (_) {}
          }
          rethrow;
        }

        debugPrint('Whisper model downloaded to: $modelPath');

        // Initialize whisper with the downloaded model
        _whisper = Whisper(
          model: modelSize.whisperModel,
          downloadHost: downloadHost,
        );

        _isDownloading = false;
        return modelPath;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('Failed to download Whisper model: $e');
      _whisper = null;
      _isDownloading = false;
      return null;
    }
  }

  /// Dispose the service
  void dispose() {
    _whisper = null;
  }
}

/// Type alias for backwards compatibility with settings page
typedef WhisperModelService = WhisperService;
