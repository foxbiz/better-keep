import 'package:better_keep/dialogs/audio_recorder_options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  group('AudioRecorderOptions', () {
    test('uses 16 kHz mono WAV for Whisper-compatible recordings', () {
      final config = AudioRecorderOptions.recordConfig(useWhisperFormat: true);

      expect(config.encoder, AudioEncoder.wav);
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1);
    });

    test('uses the record package defaults for regular recordings', () {
      final config = AudioRecorderOptions.recordConfig(useWhisperFormat: false);

      expect(config.encoder, AudioEncoder.aacLc);
    });

    test('uses dictation mode and the expected speech timeouts', () {
      final options = AudioRecorderOptions.speechListenOptions();

      expect(options.partialResults, isTrue);
      expect(options.cancelOnError, isFalse);
      expect(options.listenMode, ListenMode.dictation);
      expect(options.listenFor, const Duration(seconds: 30));
      expect(options.pauseFor, const Duration(seconds: 3));
    });
  });
}
