import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Centralized recorder options so recording formats and speech timeouts stay
/// consistent across the app and can be validated without invoking plugins.
abstract final class AudioRecorderOptions {
  static RecordConfig recordConfig({required bool useWhisperFormat}) {
    if (!useWhisperFormat) {
      return const RecordConfig();
    }

    return const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    );
  }

  static SpeechListenOptions speechListenOptions() {
    return SpeechListenOptions(
      partialResults: true,
      cancelOnError: false,
      listenMode: ListenMode.dictation,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
    );
  }
}
