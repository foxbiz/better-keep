import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

export 'whisper_types.dart';

import 'whisper_types.dart';

/// Native-only extension for WhisperModel mapping
extension WhisperModelSizeNativeExtension on WhisperModelSize {
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
    return file.exists();
  }

  /// Get the path where whisper_flutter_new stores models.
  ///
  /// **IMPORTANT**: This method relies on knowledge of the `whisper_flutter_new`
  /// package's internal storage location. This is a known limitation - the package
  /// does not expose a public API to query the model path.
  ///
  /// If the package changes its internal storage location in a future version,
  /// this code will need to be updated. Consider:
  /// 1. Contributing to the package to expose a getModelPath() method
  /// 2. Storing models in an app-managed directory if the package supports custom paths
  ///
  /// Current behavior (as of whisper_flutter_new v1.0.1):
  /// - Android: getApplicationSupportDirectory()
  /// - iOS/macOS: getLibraryDirectory()
  Future<String> _getModelPath(WhisperModelSize modelSize) async {
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
    if (await file.exists()) {
      return file.length();
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
    if (await file.exists()) {
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
    if (!isAvailable || _isDownloading) return null;

    modelSize ??= _currentModelSize;
    _currentModelSize = modelSize;
    _isDownloading = true;

    try {
      final modelPath = await _getModelPath(modelSize);
      final modelFile = File(modelPath);

      // Check if already downloaded
      if (await modelFile.exists()) {
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
          if (await modelFile.exists()) {
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
