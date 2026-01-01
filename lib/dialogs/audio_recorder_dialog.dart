import 'dart:async';
import 'dart:math' as math;
import 'package:better_keep/services/file_system.dart';
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

  // Live transcription
  final SpeechToText _speechToText = SpeechToText();
  bool _speechAvailable = false;
  String _liveTranscription = '';
  String _finalTranscription = '';
  bool _speechError = false;

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
    _initSpeechToText();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amplitudeSub?.cancel();
    _speechRestartTimer?.cancel();
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
    final status = await Permission.microphone.request();
    if (!mounted) return;
    setState(() {
      _permissionDenied = status != PermissionStatus.granted;
    });
  }

  Future<void> _initSpeechToText() async {
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

  void _onSpeechError(SpeechRecognitionError error) {
    // Don't show error for temporary issues - speech will restart
    if (error.permanent && mounted) {
      setState(() {
        _speechError = true;
      });
    }
  }

  void _onSpeechStatus(String status) {
    // If speech stops but we're still recording, try to restart it
    if (status == 'notListening' && _isRecording && _enableTranscription) {
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
        final audioPath = path.join(
          audioDir,
          'audio',
          'recording_${DateTime.now().millisecondsSinceEpoch}.m4a',
        );

        // Ensure the audio directory exists before recording
        // The native Android MediaCodecEncoder requires the directory to exist
        await fs.createDirectory(path.dirname(audioPath));

        // Reset transcription state
        _liveTranscription = '';
        _finalTranscription = '';
        _speechError = false;
        _transcriptionController.clear();

        // Start audio file recording FIRST (most important)
        await _audioRecorder.start(const RecordConfig(), path: audioPath);

        // Start amplitude monitoring for waveform
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

        // Start live transcription in parallel (non-blocking, can fail)
        if (_enableTranscription && _speechAvailable) {
          // Small delay to let audio recorder settle
          await Future.delayed(const Duration(milliseconds: 200));
          _startSpeechRecognition();
        }
      }
    } catch (e) {
      // Recording failed - user should be notified
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to start recording')));
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
              // When result is final, append to final transcription
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
        listenFor: const Duration(seconds: 30), // Max listen time
        pauseFor: const Duration(seconds: 3), // Pause detection
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false, // Don't stop on error
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      // Don't affect recording - just note that transcription failed
      if (mounted) {
        setState(() {
          _speechError = true;
        });
      }
    }
  }

  Future<void> _stopRecording() async {
    // Stop UI updates first
    _timer?.cancel();
    _speechRestartTimer?.cancel();
    _amplitudeSub?.cancel();

    // Stop speech recognition
    try {
      await _speechToText.stop();
    } catch (_) {
      // Ignore speech stop errors - doesn't affect recording
    }

    setState(() {
      _isRecording = false;
      _amplitudeDb = -120;
    });

    try {
      final recordedPath = await _audioRecorder.stop();
      if (mounted && recordedPath != null) {
        String finalPath = recordedPath;

        // On web, the record package returns a blob URL.
        // We need to fetch the blob data and save it to OPFS.
        if (kIsWeb && recordedPath.startsWith('blob:')) {
          try {
            // Fetch the blob data from the URL
            final response = await http.get(Uri.parse(recordedPath));
            if (response.statusCode == 200) {
              final Uint8List audioBytes = response.bodyBytes;

              // Generate a path in OPFS
              final fs = await fileSystem();
              final opfsPath = path.join(
                await fs.documentDir,
                '${Uuid().v4()}.m4a',
              );

              // Save to OPFS
              await fs.writeBytes(opfsPath, audioBytes);
              finalPath = opfsPath;
            }
          } catch (e) {
            // If blob fetching fails, keep the blob URL as fallback
            debugPrint('Failed to save audio to OPFS: $e');
          }
        }

        // Combine final transcription with any remaining live transcription
        String fullTranscription = _finalTranscription;
        if (_liveTranscription.isNotEmpty) {
          if (fullTranscription.isNotEmpty) {
            fullTranscription += ' ';
          }
          fullTranscription += _liveTranscription;
        }

        setState(() {
          _path = finalPath;
          _transcriptionController.text = fullTranscription.trim();
        });

        // Auto-fill title from transcription
        _updateTitleFromTranscription();
      }
    } catch (_) {
      // Recording stop failed - file may still be saved
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
    // Show live transcription during recording
    String display = _finalTranscription;
    if (_liveTranscription.isNotEmpty) {
      if (display.isNotEmpty) {
        display += ' ';
      }
      display += _liveTranscription;
    }
    return display;
  }

  @override
  Widget build(BuildContext context) {
    final textColor =
        Theme.of(context).textTheme.bodyLarge?.color ??
        Theme.of(context).hintColor;

    return AlertDialog(
      title: const Text('Record Audio'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_permissionDenied)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    const Text(
                      'Microphone permission is required to record audio.',
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
                          child: const Text('Retry'),
                        ),
                        OutlinedButton(
                          onPressed: openAppSettings,
                          child: const Text('Open Settings'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
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
              onPressed: _permissionDenied
                  ? null
                  : (_isRecording ? _stopRecording : _startRecording),
              child: Text(_isRecording ? 'Stop recording' : 'Start recording'),
            ),
            const SizedBox(height: 16),

            // During recording: show live transcription
            if (_isRecording) ...[
              // Show live transcription during recording
              if (_enableTranscription) ...[
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
                            _speechAvailable && !_speechError
                                ? Icons.mic
                                : Icons.mic_off,
                            size: 14,
                            color: _speechAvailable && !_speechError
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _speechError
                                ? 'Transcription unavailable'
                                : 'Live transcription',
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
                                  ? 'Recording will continue without transcription'
                                  : 'Listening...')
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
            // Before recording: show options
            else if (_path == null) ...[
              Text(
                _permissionDenied
                    ? 'Allow microphone access to start recording.'
                    : 'Tap start to begin recording.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_speechAvailable) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _enableTranscription,
                  onChanged: (value) {
                    setState(() => _enableTranscription = value ?? true);
                  },
                  title: const Text('Live transcription'),
                  subtitle: const Text('Transcribe while recording'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ],
            ],

            // After recording: show transcription result
            if (!_isRecording && _path != null) ...[
              const SizedBox(height: 16),

              // Transcription result (editable)
              if (_transcriptionController.text.isNotEmpty) ...[
                TextField(
                  controller: _transcriptionController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Transcription',
                    border: OutlineInputBorder(),
                    hintText: 'Edit transcription if needed',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _addTranscriptionToNote,
                  onChanged: (value) {
                    setState(() => _addTranscriptionToNote = value ?? true);
                  },
                  title: const Text('Add transcription to note'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
                const SizedBox(height: 8),
              ] else if (_enableTranscription && _speechAvailable) ...[
                // No transcription captured
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
                          'No speech detected during recording.',
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
                  labelText: 'Title (optional)',
                  hintText: 'Enter a title for this recording',
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
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: (_path != null && !_isRecording)
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
          child: const Text('Okay'),
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

    // Convert dB to linear amplitude (0.0 to 1.0)
    // amplitudeDb typically ranges from -120 (silence) to 0 (max)
    final linear = math.pow(10, amplitudeDb / 20.0).toDouble();
    final normAmp = linear.clamp(0.0, 1.0);

    // Calculate the vertical displacement based on amplitude
    final maxDisplacement = size.height / 2 - 4;
    final displacement = normAmp * maxDisplacement;

    // Draw the main horizontal line with rounded ends
    final linePaint = Paint()
      ..color = color.withAlpha(80)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), linePaint);

    // Draw center waveform indicator that reacts to voice
    final wavePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Draw multiple vertical lines representing waveform
    final segmentCount = 15;
    final segmentWidth = size.width / (segmentCount + 1);

    for (int i = 1; i <= segmentCount; i++) {
      final x = i * segmentWidth;
      // Create a wave pattern - center segments are taller
      final distanceFromCenter = (i - (segmentCount + 1) / 2).abs();
      final centerFactor = 1 - (distanceFromCenter / (segmentCount / 2));
      final segmentHeight =
          displacement * centerFactor * 0.8 +
          (normAmp > 0.05 ? 2 : 0); // Minimum visible height when there's sound

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
