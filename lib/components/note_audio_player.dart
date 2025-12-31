import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:better_keep/models/attachments/recording_attachment.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:flutter/material.dart';

class NoteAudioPlayer extends StatefulWidget {
  final RecordingAttachment recording;
  final VoidCallback onDelete;
  final void Function(RecordingAttachment)? onUpdate;

  const NoteAudioPlayer({
    super.key,
    required this.recording,
    required this.onDelete,
    this.onUpdate,
  });

  @override
  State<NoteAudioPlayer> createState() => NoteAudioPlayerState();
}

class NoteAudioPlayerState extends State<NoteAudioPlayer> {
  late AudioPlayer _audioPlayer;
  final List<StreamSubscription> _subscriptions = [];
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  /// Start playing the audio
  void play() {
    _audioPlayer.resume();
  }

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _subscriptions.add(
      _audioPlayer.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state == PlayerState.playing;
          });
        }
      }),
    );
    _subscriptions.add(
      _audioPlayer.onDurationChanged.listen((newDuration) {
        if (mounted) {
          setState(() {
            _duration = newDuration;
          });
        }
      }),
    );
    _subscriptions.add(
      _audioPlayer.onPositionChanged.listen((newPosition) {
        if (mounted) {
          setState(() {
            _position = newPosition;
          });
        }
      }),
    );
    _subscriptions.add(
      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _position = Duration.zero;
          });
          _audioPlayer.seek(Duration.zero);
        }
      }),
    );
    _initAudioSource();
  }

  Future<void> _initAudioSource() async {
    try {
      Source source;
      // Fix path for iOS where container ID changes between app launches
      final fixedPath = await FileUtils.fixPath(widget.recording.path);

      // Check if file exists and has content
      final file = File(fixedPath);
      if (!await file.exists()) {
        return;
      }
      final fileSize = await file.length();
      if (fileSize == 0) {
        return;
      }
      source = DeviceFileSource(fixedPath);

      await _audioPlayer.setSource(source);

      // Wait a bit for the source to be fully loaded
      await Future.delayed(const Duration(milliseconds: 100));

      // Try to get duration, if it fails try playing briefly
      Duration? duration = await _audioPlayer.getDuration();

      if (duration == null || duration == Duration.zero) {
        // Play and immediately pause to force duration loading
        await _audioPlayer.resume();
        await Future.delayed(const Duration(milliseconds: 50));
        await _audioPlayer.pause();
        await _audioPlayer.seek(Duration.zero);
        duration = await _audioPlayer.getDuration();
      }

      if (duration != null && duration != Duration.zero && mounted) {
        setState(() {
          _duration = duration!;
        });
      } else if (widget.recording.length > 0 && mounted) {
        // Fall back to stored length if audio player can't determine duration
        setState(() {
          _duration = Duration(seconds: widget.recording.length);
        });
      }
    } catch (_) {
      // Handle error gracefully - audio may not be playable
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  void _showEditDialog() {
    final titleController = TextEditingController(
      text: widget.recording.title ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Audio Recording'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Enter a title for this recording',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              if (widget.recording.transcript != null &&
                  widget.recording.transcript!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Transcript',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      widget.recording.transcript!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Duration: ${_formatDuration(_duration)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final newTitle = titleController.text.trim();
              if (widget.onUpdate != null) {
                widget.onUpdate!(
                  RecordingAttachment(
                    length: widget.recording.length,
                    title: newTitle.isNotEmpty ? newTitle : null,
                    transcript: widget.recording.transcript,
                  ),
                );
              }
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Recording'),
        content: const Text(
          'Are you sure you want to delete this audio recording?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDelete();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.recording.title;
    final hasTitle = title != null && title.isNotEmpty;

    // Calculate progress percentage
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final colorScheme = Theme.of(context).colorScheme;
    final progressColor = colorScheme.primary.withValues(alpha: 0.2);
    final backgroundColor = Theme.of(context).cardColor;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: GestureDetector(
          onTap: _showEditDialog,
          onHorizontalDragStart: _onSeekStart,
          onHorizontalDragUpdate: _onSeekUpdate,
          onHorizontalDragEnd: _onSeekEnd,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // Progress background
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progress,
                    child: Container(
                      decoration: BoxDecoration(color: progressColor),
                    ),
                  ),
                ),
                // Content
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      // Play/Pause button
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 28,
                          ),
                          onPressed: () {
                            if (_isPlaying) {
                              _audioPlayer.pause();
                            } else {
                              _audioPlayer.resume();
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Title
                      Expanded(
                        child: Text(
                          hasTitle ? title : 'Audio Recording',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Delete button
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: colorScheme.error,
                          ),
                          onPressed: _confirmDelete,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Seek gesture handling
  double? _seekStartX;

  void _onSeekStart(DragStartDetails details) {
    _seekStartX = details.localPosition.dx;
  }

  void _onSeekUpdate(DragUpdateDetails details) {
    if (_seekStartX == null || _duration.inMilliseconds == 0) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final width = renderBox.size.width;
    final x = details.localPosition.dx.clamp(0.0, width);
    final progress = x / width;
    final position = Duration(
      milliseconds: (progress * _duration.inMilliseconds).round(),
    );
    _audioPlayer.seek(position);
  }

  void _onSeekEnd(DragEndDetails details) {
    _seekStartX = null;
  }
}
