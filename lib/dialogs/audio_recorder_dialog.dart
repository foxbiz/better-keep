import 'dart:async';
import 'dart:math' as math;
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/whisper/whisper_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

/// Result returned from the audio recorder dialog
class AudioRecordingResult {
  final String path;
  final String? title;
  final String? transcription;
  final int length;

  AudioRecordingResult({
    required this.path,
    this.title,
    this.transcription,
    this.length = 0,
  });
}

class AudioRecorderDialog extends StatefulWidget {
  const AudioRecorderDialog({super.key});

  @override
  State<AudioRecorderDialog> createState() => _AudioRecorderDialogState();
}

class _AudioRecorderDialogState extends State<AudioRecorderDialog>
    with WidgetsBindingObserver {
  // Audio recording
  late final AudioRecorder _audioRecorder;

  // Live transcription (Web fallback)
  final SpeechToText _speechToText = SpeechToText();
  bool _speechAvailable = false;
  String _liveTranscription = '';
  String _finalTranscription = '';
  bool _speechError = false;

  // Whisper transcription (for native platforms)
  final WhisperService _whisperService = WhisperService.instance;
  bool _whisperAvailable = false;
  bool _whisperModelReady = false;
  bool _isTranscribing = false;
  bool _isDownloadingModel = false; // Separate flag for model download
  double _downloadProgress = 0.0; // Download progress 0.0 to 1.0
  bool _useWhisper = false;
  bool _isPolishing =
      false; // Show "polishing" indicator during Whisper after live preview
  double _transcriptionProgress = 0.0; // Estimated progress 0.0 to 1.0
  Timer? _progressTimer; // Timer for simulating progress
  bool _isCancelled = false; // Flag to cancel background work on dispose

  // Controllers
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _transcriptionController =
      TextEditingController();

  // State
  bool _isRecording = false;
  bool _permissionDenied = false;
  bool _addTranscriptionToNote = true;
  bool _enableTranscription = true;

  String? _path;
  Timer? _timer;
  Timer? _speechRestartTimer;
  int _recordDuration = 0;
  StreamSubscription<Amplitude>? _amplitudeSub;
  double _amplitudeDb = -120;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioRecorder = AudioRecorder();
    _initRecorder();
    _initTranscription();
  }

  @override
  void dispose() {
    _isCancelled = true; // Signal background tasks to stop
    WidgetsBinding.instance.removeObserver(this);
    _amplitudeSub?.cancel();
    _speechRestartTimer?.cancel();
    _progressTimer?.cancel();
    _timer?.cancel();
    _audioRecorder.dispose();
    _speechToText.stop();
    _titleController.dispose();
    _transcriptionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _permissionDenied) {
      _initRecorder();
    }
  }

  Future<void> _initRecorder() async {
    // permission_handler doesn't support macOS/Linux, use record package's API instead
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (isDesktop) {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!mounted) return;
      setState(() {
        _permissionDenied = !hasPermission;
      });
    } else {
      final status = await Permission.microphone.request();
      if (!mounted) return;
      setState(() {
        _permissionDenied = status != PermissionStatus.granted;
      });
    }
  }

  Future<void> _initSpeechToText() async {
    // Skip speech-to-text on macOS/Linux - plugin crashes due to TCC permission issues
    // Skip on Android - microphone conflict with audio recording causes beeps/failures
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.android)) {
      _speechAvailable = false;
      return;
    }
    try {
      _speechAvailable = await _speechToText.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
        debugLogging: kDebugMode,
      );
    } catch (e) {
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  /// Initialize transcription - prefer Whisper on native, fallback to speech_to_text
  Future<void> _initTranscription() async {
    // On Web, transcription is disabled for privacy
    if (kIsWeb) {
      _whisperAvailable = false;
      _speechAvailable = false;
      _enableTranscription = false;
      if (mounted) setState(() {});
      return;
    }

    // Check if Whisper is available on this platform
    _whisperAvailable = _whisperService.isAvailable;
    if (_whisperAvailable) {
      _whisperModelReady = await _whisperService.isModelDownloaded();
      _useWhisper = _whisperModelReady;
    }

    // Initialize speech_to_text as fallback for live transcription
    await _initSpeechToText();

    if (mounted) setState(() {});
  }

  void _onSpeechError(SpeechRecognitionError error) {
    if (error.permanent && mounted) {
      setState(() {
        _speechError = true;
      });
    }
  }

  void _onSpeechStatus(String status) {
    final hybridMode = _whisperModelReady && _speechAvailable;
    if (status == 'notListening' &&
        _isRecording &&
        _enableTranscription &&
        _speechAvailable &&
        (hybridMode || !_useWhisper)) {
      _scheduleRestartSpeech();
    }
  }

  void _scheduleRestartSpeech() {
    _speechRestartTimer?.cancel();
    _speechRestartTimer = Timer(const Duration(milliseconds: 300), () {
      if (_isRecording && mounted && _speechAvailable) {
        _startSpeechRecognition();
      }
    });
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final fs = await fileSystem();
        final audioDir = await fs.documentDir;

        // Use WAV format when Whisper will be used for transcription
        // WAV is required for Whisper but may have playback issues on some devices
        // On Android, we still use WAV since Whisper is the only transcription option
        final useWavFormat = _whisperModelReady && _enableTranscription;
        final extension = useWavFormat ? 'wav' : 'm4a';
        final audioPath = path.join(
          audioDir,
          'audio',
          'recording_${DateTime.now().millisecondsSinceEpoch}.$extension',
        );

        await fs.createDirectory(path.dirname(audioPath));

        // Reset transcription state
        _liveTranscription = '';
        _finalTranscription = '';
        _speechError = false;
        _transcriptionController.clear();

        // Configure recording format based on transcription method
        RecordConfig config;
        if (useWavFormat) {
          // Whisper requires 16kHz WAV
          config = const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          );
        } else {
          config = const RecordConfig();
        }

        await _audioRecorder.start(config, path: audioPath);

        // Start amplitude monitoring
        _amplitudeSub?.cancel();
        _amplitudeSub = _audioRecorder
            .onAmplitudeChanged(const Duration(milliseconds: 80))
            .listen((amp) {
              if (mounted) {
                setState(() {
                  _amplitudeDb = amp.current;
                });
              }
            });

        setState(() {
          _isRecording = true;
          _path = audioPath;
          _recordDuration = 0;
        });

        _startTimer();

        // Start live transcription - hybrid mode (Whisper + speech) or speech-only
        final hybridMode = _whisperModelReady && _speechAvailable;
        if (_enableTranscription &&
            (hybridMode || !_useWhisper) &&
            _speechAvailable) {
          await Future.delayed(const Duration(milliseconds: 200));
          _startSpeechRecognition();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.failedToStartRecording)),
        );
      }
    }
  }

  Future<void> _startSpeechRecognition() async {
    if (!_speechAvailable || !_isRecording) return;

    try {
      await _speechToText.listen(
        onResult: (result) {
          if (mounted && _isRecording) {
            setState(() {
              _liveTranscription = result.recognizedWords;
              if (result.finalResult && result.recognizedWords.isNotEmpty) {
                if (_finalTranscription.isNotEmpty) {
                  _finalTranscription += ' ';
                }
                _finalTranscription += result.recognizedWords;
                _liveTranscription = '';
              }
            });
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _speechError = true;
        });
      }
    }
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _speechRestartTimer?.cancel();
    _amplitudeSub?.cancel();

    // Stop speech recognition if active (hybrid or speech-only)
    final hybridMode = _whisperModelReady && _speechAvailable;
    if (hybridMode || !_useWhisper) {
      try {
        await _speechToText.stop();
      } catch (e) {
        debugPrint('Failed to stop speech recognition: $e');
      }
    }

    setState(() {
      _isRecording = false;
      _amplitudeDb = -120;
    });

    try {
      final recordedPath = await _audioRecorder.stop();
      if (mounted && recordedPath != null) {
        String finalPath = recordedPath;

        // On web, fetch blob and save to OPFS
        if (kIsWeb && recordedPath.startsWith('blob:')) {
          try {
            final response = await http.get(Uri.parse(recordedPath));
            if (response.statusCode == 200) {
              final Uint8List audioBytes = response.bodyBytes;
              final fs = await fileSystem();
              final opfsPath = path.join(
                await fs.documentDir,
                '${Uuid().v4()}.m4a',
              );
              await fs.writeBytes(opfsPath, audioBytes);
              finalPath = opfsPath;
            }
          } catch (e) {
            debugPrint('Failed to save audio to OPFS: $e');
          }
        }

        setState(() {
          _path = finalPath;
        });

        // Combine live transcription parts
        String liveResult = _finalTranscription;
        if (_liveTranscription.isNotEmpty) {
          if (liveResult.isNotEmpty) liveResult += ' ';
          liveResult += _liveTranscription;
        }

        // In hybrid mode: show live preview immediately, then run Whisper
        if (hybridMode && _enableTranscription) {
          // Show live transcription as immediate preview
          _transcriptionController.text = liveResult.trim();
          // Run Whisper for high-quality final result
          await _transcribeWithWhisper(finalPath, showPolishing: true);
        } else if (_useWhisper && _enableTranscription && _whisperModelReady) {
          // Whisper-only mode (no live preview available)
          await _transcribeWithWhisper(finalPath);
        } else {
          // speech_to_text only
          _transcriptionController.text = liveResult.trim();
        }

        _updateTitleFromTranscription();
      }
    } catch (e) {
      debugPrint('Failed to stop recording: $e');
    }
  }

  Future<void> _transcribeWithWhisper(
    String audioPath, {
    bool showPolishing = false,
  }) async {
    // Early exit if dialog was closed
    if (_isCancelled) return;

    setState(() {
      _isTranscribing = true;
      _isPolishing = showPolishing;
      _transcriptionProgress = 0.0;
    });

    // Start estimated progress based on audio duration
    // Whisper tiny model ~= 5-10 seconds per minute of audio
    final estimatedSeconds = (_recordDuration * 0.15).clamp(3.0, 60.0);
    _startProgressTimer(estimatedSeconds);

    try {
      final transcription = await _whisperService.transcribe(audioPath);
      _progressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _isPolishing = false;
          _transcriptionProgress = 1.0;
          if (transcription != null && transcription.isNotEmpty) {
            _transcriptionController.text = transcription;
          } else if (showPolishing) {
            // Whisper returned empty in hybrid mode - clear preview
            _transcriptionController.clear();
          }
        });
      }
    } catch (e) {
      debugPrint('Whisper transcription failed: $e');
      _progressTimer?.cancel();
      if (mounted) {
        setState(() {
          _isTranscribing = false;
          _isPolishing = false;
          _transcriptionProgress = 0.0;
          // Clear the live preview if Whisper fails (per user preference)
          if (showPolishing) {
            _transcriptionController.clear();
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.transcriptionFailed),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Start a timer that simulates progress based on estimated transcription time
  void _startProgressTimer(double estimatedSeconds) {
    _progressTimer?.cancel();
    const updateInterval = Duration(milliseconds: 100);
    final totalUpdates = (estimatedSeconds * 10)
        .toInt(); // 10 updates per second
    var currentUpdate = 0;

    _progressTimer = Timer.periodic(updateInterval, (timer) {
      currentUpdate++;
      if (mounted && _isTranscribing) {
        setState(() {
          // Cap at 95% so it doesn't look stuck at 100%
          _transcriptionProgress = ((currentUpdate / totalUpdates) * 0.95)
              .clamp(0.0, 0.95);
        });
      }
      if (currentUpdate >= totalUpdates) {
        timer.cancel();
      }
    });
  }

  Future<void> _initializeWhisperModel() async {
    setState(() {
      _isDownloadingModel = true;
      _downloadProgress = 0.0;
    });

    // Download the model - this will also initialize it
    final modelPath = await _whisperService.downloadModel(
      onProgress: (received, total) {
        if (mounted && total > 0) {
          setState(() {
            _downloadProgress = received / total;
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _isDownloadingModel = false;
        _whisperModelReady = modelPath != null;
        if (modelPath != null) {
          _useWhisper = true;
        }
      });

      if (modelPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.modelDownloadComplete)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.modelDownloadFailed)),
        );
      }
    }
  }

  void _updateTitleFromTranscription() {
    final text = _transcriptionController.text;
    if (text.isEmpty) return;

    final words = text.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isNotEmpty && _titleController.text.isEmpty) {
      final titleWords = words.take(5).join(' ');
      _titleController.text = titleWords + (words.length > 5 ? '...' : '');
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (mounted) {
        setState(() => _recordDuration++);
      }
    });
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds / 60).floor();
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String get _displayTranscription {
    String display = _finalTranscription;
    if (_liveTranscription.isNotEmpty) {
      if (display.isNotEmpty) {
        display += ' ';
      }
      display += _liveTranscription;
    }
    return display;
  }

  bool get _transcriptionAvailable =>
      (_useWhisper && _whisperModelReady) || _speechAvailable;

  @override
  Widget build(BuildContext context) {
    final textColor =
        Theme.of(context).textTheme.bodyLarge?.color ??
        Theme.of(context).hintColor;
    final l10n = context.l10n;

    return AlertDialog(
      title: Text(l10n.recordAudio),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_permissionDenied)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Text(
                      l10n.microphonePermissionRequired,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton(
                          onPressed: () {
                            setState(() => _permissionDenied = false);
                            _initRecorder();
                          },
                          child: Text(l10n.retry),
                        ),
                        OutlinedButton(
                          onPressed: openAppSettings,
                          child: Text(l10n.openSettings),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(l10n.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            Text(
              _formatDuration(_recordDuration),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 20),
            if (_isRecording)
              _AudioWaveformLine(amplitudeDb: _amplitudeDb, color: textColor)
            else
              Icon(Icons.mic, size: 48, color: textColor),
            const SizedBox(height: 8),
            FilledButton(
              onPressed:
                  _permissionDenied || _isTranscribing || _isDownloadingModel
                  ? null
                  : (_isRecording ? _stopRecording : _startRecording),
              child: Text(
                _isRecording ? l10n.stopRecording : l10n.startRecording,
              ),
            ),
            const SizedBox(height: 16),

            // During recording: show live transcription (hybrid or speech-only)
            // Requires _speechAvailable to actually show live transcription UI
            if (_isRecording &&
                _speechAvailable &&
                ((_whisperModelReady && _useWhisper) || !_useWhisper)) ...[
              if (_enableTranscription && _speechAvailable) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            !_speechError ? Icons.mic : Icons.mic_off,
                            size: 14,
                            color: !_speechError
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _speechError
                                ? l10n.transcriptionUnavailable
                                : l10n.liveTranscription,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _displayTranscription.isEmpty
                            ? (_speechError
                                  ? l10n.recordingContinuesWithoutTranscription
                                  : l10n.listening)
                            : _displayTranscription,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontStyle: _displayTranscription.isEmpty
                              ? FontStyle.italic
                              : FontStyle.normal,
                          color: _displayTranscription.isEmpty
                              ? Theme.of(context).colorScheme.outline
                              : null,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ]
            // During recording with Whisper-only (no speech_to_text available)
            else if (_isRecording && _useWhisper && !_speechAvailable) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.whisperTranscriptionActive,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ]
            // Before recording: show options
            else if (_path == null) ...[
              Text(
                _permissionDenied ? l10n.allowMicAccess : l10n.tapStartToRecord,
                style: Theme.of(context).textTheme.bodySmall,
              ),

              // Web: Transcription disabled for privacy
              if (kIsWeb) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(context).colorScheme.outline,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.transcriptionDisabledWebPrivacy,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ]
              // Native: Whisper options
              else if (_whisperAvailable) ...[
                const SizedBox(height: 12),

                if (!_whisperModelReady) ...[
                  // Model download prompt
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.download_outlined,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.whisperModelRequired,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.whisperModelDescription,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_isDownloadingModel)
                          Column(
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: LinearProgressIndicator(
                                  value: _downloadProgress > 0
                                      ? _downloadProgress
                                      : null,
                                  minHeight: 6,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${(_downloadProgress * 100).toInt()}%',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                              ),
                            ],
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonal(
                                onPressed: _initializeWhisperModel,
                                child: Text(l10n.downloadModel),
                              ),
                              if (_speechAvailable)
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _useWhisper = false;
                                      _enableTranscription = true;
                                    });
                                  },
                                  child: Text(l10n.useFallback),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Model ready - show transcription toggle
                  CheckboxListTile(
                    value: _enableTranscription,
                    onChanged: (value) {
                      setState(() => _enableTranscription = value ?? true);
                    },
                    title: Text(l10n.liveTranscription),
                    subtitle: Text(l10n.whisperTranscriptionActive),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ],
              ]
              // Fallback to speech_to_text
              else if (_speechAvailable) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _enableTranscription,
                  onChanged: (value) {
                    setState(() => _enableTranscription = value ?? true);
                  },
                  title: Text(l10n.liveTranscription),
                  subtitle: Text(l10n.transcribeWhileRecording),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ],
            ],

            // After recording: show transcription result or transcribing indicator
            if (!_isRecording && _path != null) ...[
              const SizedBox(height: 16),

              // Transcribing with Whisper
              if (_isTranscribing) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: LinearProgressIndicator(
                          value: _transcriptionProgress > 0
                              ? _transcriptionProgress
                              : null, // Indeterminate if 0
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isPolishing
                            ? l10n.polishingTranscription
                            : l10n.transcribingAudio,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (_transcriptionProgress > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${(_transcriptionProgress * 100).toInt()}%',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ] else ...[
                // Transcription result (editable)
                if (_transcriptionController.text.isNotEmpty) ...[
                  TextField(
                    controller: _transcriptionController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: l10n.transcription,
                      border: const OutlineInputBorder(),
                      hintText: l10n.editTranscriptionHint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _addTranscriptionToNote,
                    onChanged: (value) {
                      setState(() => _addTranscriptionToNote = value ?? true);
                    },
                    title: Text(l10n.addTranscriptionToNote),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                  const SizedBox(height: 8),
                ] else if (_enableTranscription && _transcriptionAvailable) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Theme.of(context).colorScheme.outline,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.noSpeechDetected,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.outline,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Title input
                TextField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: l10n.titleOptional,
                    hintText: l10n.enterTitleForRecording,
                    border: const OutlineInputBorder(),
                    suffixIcon: _titleController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(() => _titleController.clear());
                            },
                          )
                        : null,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            Navigator.of(context).pop();
            final fs = await fileSystem();
            if (_path != null && await fs.exists(_path!)) {
              await fs.delete(_path!);
            }
          },
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: (_path != null && !_isRecording && !_isTranscribing)
              ? () {
                  final title = _titleController.text.trim();
                  String? transcription;
                  if (_addTranscriptionToNote &&
                      _transcriptionController.text.isNotEmpty) {
                    transcription = _transcriptionController.text.trim();
                  }
                  Navigator.of(context).pop(
                    AudioRecordingResult(
                      path: _path!,
                      title: title.isNotEmpty ? title : null,
                      transcription: transcription,
                      length: _recordDuration,
                    ),
                  );
                }
              : null,
          child: Text(l10n.okay),
        ),
      ],
    );
  }
}

/// A horizontal line that reacts to audio amplitude
class _AudioWaveformLine extends StatelessWidget {
  const _AudioWaveformLine({required this.amplitudeDb, required this.color});

  final double amplitudeDb;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: CustomPaint(
        painter: _AudioWaveformLinePainter(
          amplitudeDb: amplitudeDb,
          color: color,
        ),
      ),
    );
  }
}

class _AudioWaveformLinePainter extends CustomPainter {
  _AudioWaveformLinePainter({required this.amplitudeDb, required this.color});

  final double amplitudeDb;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;

    final linear = math.pow(10, amplitudeDb / 20.0).toDouble();
    final normAmp = linear.clamp(0.0, 1.0);

    final maxDisplacement = size.height / 2 - 4;
    final displacement = normAmp * maxDisplacement;

    final linePaint = Paint()
      ..color = color.withAlpha(80)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), linePaint);

    final wavePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final segmentCount = 15;
    final segmentWidth = size.width / (segmentCount + 1);

    for (int i = 1; i <= segmentCount; i++) {
      final x = i * segmentWidth;
      final distanceFromCenter = (i - (segmentCount + 1) / 2).abs();
      final centerFactor = 1 - (distanceFromCenter / (segmentCount / 2));
      final segmentHeight =
          displacement * centerFactor * 0.8 + (normAmp > 0.05 ? 2 : 0);

      canvas.drawLine(
        Offset(x, midY - segmentHeight),
        Offset(x, midY + segmentHeight),
        wavePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformLinePainter oldDelegate) {
    return oldDelegate.amplitudeDb != amplitudeDb || oldDelegate.color != color;
  }
}
