import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/services/audio_playback_source_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';

class NoteAudioPlayer extends StatefulWidget {
  final NoteRecording recording;
  final bool noteLocked;
  final bool noteSessionUnlocked;
  final PasswordProtectedAudioDecoder? passwordProtectedDecoder;
  final VoidCallback onDelete;
  final void Function(NoteRecording)? onUpdate;
  final AudioPlaybackResolve? sourceResolver;

  const NoteAudioPlayer({
    super.key,
    required this.recording,
    this.noteLocked = false,
    this.noteSessionUnlocked = false,
    this.passwordProtectedDecoder,
    required this.onDelete,
    this.onUpdate,
    this.sourceResolver,
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
  AudioPlaybackSourceLease? _sourceLease;
  Future<bool>? _sourceInitialization;
  Future<void> _sourceQueue = Future<void>.value();
  int _sourceGeneration = 0;
  bool _sourceLoading = true;
  bool _sourceReady = false;
  bool _sourceFailed = false;
  bool _playPending = false;
  bool _disposed = false;

  /// Start playing the audio
  void play() {
    unawaited(_playWhenReady());
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
    _sourceInitialization = _scheduleSourceInitialization();
  }

  @override
  void didUpdateWidget(NoteAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording.src != widget.recording.src ||
        oldWidget.noteLocked != widget.noteLocked ||
        oldWidget.noteSessionUnlocked != widget.noteSessionUnlocked) {
      _sourceInitialization = _scheduleSourceInitialization();
    }
  }

  Future<bool> _scheduleSourceInitialization() {
    final generation = ++_sourceGeneration;
    final source = widget.recording.src;
    final protectedSource = widget.noteLocked;
    _setSourceStatus(loading: true, ready: false, failed: false);
    final completer = Completer<bool>();

    _sourceQueue = _sourceQueue.catchError((Object _, StackTrace _) {}).then((
      _,
    ) async {
      if (!_isCurrent(generation)) {
        completer.complete(false);
        return;
      }

      AudioPlaybackSourceLease? nextLease;
      var sourceSubmitted = false;
      try {
        await _releaseCurrentSource();
        final resolver = widget.sourceResolver ?? _resolveSource;
        nextLease = await resolver(source, protectedSource: protectedSource);
        if (!_isCurrent(generation)) {
          await nextLease.release();
          completer.complete(false);
          return;
        }

        sourceSubmitted = true;
        await _audioPlayer.setSource(_toPlayerSource(nextLease));
        if (!_isCurrent(generation)) {
          await _stopPlayerSafely();
          await nextLease.release();
          completer.complete(false);
          return;
        }

        _sourceLease = nextLease;
        nextLease = null;
        await _loadDuration(generation);
        if (!_isCurrent(generation)) {
          await _releaseCurrentSource();
          completer.complete(false);
          return;
        }

        _setSourceStatus(loading: false, ready: true, failed: false);
        completer.complete(true);
      } catch (error, stackTrace) {
        await nextLease?.release();
        final hadCurrentLease = _sourceLease != null;
        await _releaseCurrentSource();
        if (sourceSubmitted && !hadCurrentLease) {
          await _stopPlayerSafely();
        }
        if (_isCurrent(generation)) {
          _setSourceStatus(loading: false, ready: false, failed: true);
          final code = error is AudioPlaybackSourceException
              ? error.code.name
              : 'playerSource';
          AppLogger.error(
            'Failed to prepare audio playback ($code)',
            error,
            stackTrace,
          );
        }
        if (!completer.isCompleted) completer.complete(false);
      }
    });

    return completer.future;
  }

  Future<AudioPlaybackSourceLease> _resolveSource(
    String source, {
    required bool protectedSource,
  }) async {
    final service = await AudioPlaybackSourceService.platform();
    return service.resolve(
      source,
      protectedSource: protectedSource,
      passwordProtectedDecoder: widget.noteSessionUnlocked
          ? widget.passwordProtectedDecoder
          : null,
    );
  }

  Source _toPlayerSource(AudioPlaybackSourceLease lease) {
    return switch (lease.kind) {
      AudioPlaybackSourceKind.url => UrlSource(
        lease.location!,
        mimeType: lease.mimeType,
      ),
      AudioPlaybackSourceKind.deviceFile => DeviceFileSource(
        lease.location!,
        mimeType: lease.mimeType,
      ),
      AudioPlaybackSourceKind.bytes => BytesSource(
        lease.bytes!,
        mimeType: lease.mimeType,
      ),
    };
  }

  Future<void> _loadDuration(int generation) async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (!_isCurrent(generation)) return;

    var duration = await _audioPlayer.getDuration();
    if ((duration == null || duration == Duration.zero) &&
        _isCurrent(generation)) {
      await _audioPlayer.resume();
      await Future.delayed(const Duration(milliseconds: 50));
      if (!_isCurrent(generation)) return;
      await _audioPlayer.pause();
      await _audioPlayer.seek(Duration.zero);
      duration = await _audioPlayer.getDuration();
    }

    if (!_isCurrent(generation)) return;
    if (duration != null && duration != Duration.zero) {
      _updateDuration(duration);
    } else if (widget.recording.length > 0) {
      _updateDuration(Duration(seconds: widget.recording.length));
    }
  }

  Future<void> _playWhenReady() async {
    if (_playPending) return;
    _playPending = true;
    try {
      var initialization = _sourceInitialization;
      if (!_sourceReady && !_sourceLoading) {
        initialization = _scheduleSourceInitialization();
        _sourceInitialization = initialization;
      }
      if (initialization != null && !await initialization) return;
      if (_disposed || !_sourceReady) return;
      await _audioPlayer.resume();
    } catch (error, stackTrace) {
      _setSourceStatus(loading: false, ready: false, failed: true);
      AppLogger.error('Failed to start audio playback', error, stackTrace);
    } finally {
      _playPending = false;
    }
  }

  Future<void> _pause() async {
    if (!_sourceReady) return;
    try {
      await _audioPlayer.pause();
    } catch (error, stackTrace) {
      AppLogger.error('Failed to pause audio playback', error, stackTrace);
    }
  }

  Future<void> _releaseCurrentSource() async {
    final lease = _sourceLease;
    _sourceLease = null;
    if (lease == null) return;
    await _stopPlayerSafely();
    await lease.release();
  }

  Future<void> _stopPlayerSafely() async {
    try {
      await _audioPlayer.stop();
    } catch (_) {
      // A source may have failed before the native player was prepared.
    }
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _sourceGeneration;

  void _setSourceStatus({
    required bool loading,
    required bool ready,
    required bool failed,
  }) {
    void update() {
      _sourceLoading = loading;
      _sourceReady = ready;
      _sourceFailed = failed;
    }

    if (mounted) {
      setState(update);
    } else {
      update();
    }
  }

  void _updateDuration(Duration value) {
    if (mounted) {
      setState(() => _duration = value);
    } else {
      _duration = value;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sourceGeneration++;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _sourceQueue = _sourceQueue.catchError((Object _, StackTrace _) {}).then((
      _,
    ) async {
      try {
        await _audioPlayer.dispose();
      } catch (_) {
        // The native player may never have received a valid source.
      } finally {
        await _sourceLease?.release();
        _sourceLease = null;
      }
    });
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
        title: Text(context.l10n.audioRecording),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: context.l10n.title,
                  hintText: context.l10n.enterRecordingTitle,
                  border: const OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              if (widget.recording.transcript != null &&
                  widget.recording.transcript!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  context.l10n.transcript,
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
                '${context.l10n.duration}: ${_formatDuration(_duration)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final newTitle = titleController.text.trim();
              if (widget.onUpdate != null) {
                widget.onUpdate!(
                  NoteRecording(
                    src: widget.recording.src,
                    length: widget.recording.length,
                    title: newTitle.isNotEmpty ? newTitle : null,
                    transcript: widget.recording.transcript,
                  ),
                );
              }
              Navigator.of(context).pop();
            },
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteRecording),
        content: Text(context.l10n.deleteRecordingConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDelete();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(context.l10n.delete),
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
                          icon: _sourceLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _sourceFailed
                                      ? Icons.refresh_rounded
                                      : _isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 28,
                                ),
                          tooltip: _sourceFailed ? context.l10n.retry : null,
                          onPressed: _sourceLoading
                              ? null
                              : () {
                                  if (_isPlaying) {
                                    unawaited(_pause());
                                  } else {
                                    play();
                                  }
                                },
                          disabledColor: colorScheme.onSurface.withValues(
                            alpha: 0.38,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Title
                      Expanded(
                        child: Text(
                          hasTitle ? title : context.l10n.audioRecording,
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
