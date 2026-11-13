import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'package:better_keep/services/monetization/plan_service.dart';

import 'dart:async';
import 'dart:ui';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A floating widget that shows sync progress at the bottom of the screen.
/// Displays the current phase and progress for a known download total.
class SyncProgressWidget extends StatefulWidget {
  const SyncProgressWidget({
    super.key,
    this.bottom = 32,
    this.showActivity = true,
    this.visible = true,
  });

  final bool showActivity;
  final bool visible;

  /// Distance above the bottom safe area, including any floating controls.
  final double bottom;

  @override
  State<SyncProgressWidget> createState() => _SyncProgressWidgetState();
}

class _SyncProgressWidgetState extends State<SyncProgressWidget>
    with SingleTickerProviderStateMixin {
  late SyncProgress _progress;
  bool _dismissed = false;
  bool _shouldShow = false;
  Timer? _hideTimer;
  late final _cardSettings = Listenable.merge([
    PlanService.instance.entitlementsNotifier,
    FirebaseSyncPreference.instance,
    NoteSyncBatch.active,
  ]);

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
        );
    _progress = SyncPresentation.instance.value;
    _shouldShow = !_progress.isEmpty;
    if (_shouldShow) _animationController.value = 1;
    if (_shouldShow && !_progress.isActive) _scheduleHide();
    AppState.showSyncProgressNotifier.addListener(_visibilityChanged);
    SyncPresentation.instance.addListener(_onProgressChanged);
  }

  @override
  void dispose() {
    AppState.showSyncProgressNotifier.removeListener(_visibilityChanged);
    SyncPresentation.instance.removeListener(_onProgressChanged);
    _hideTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _retry() => refreshSyncFromUser(context);

  void _visibilityChanged() => setState(() {});

  void _onProgressChanged() {
    final next = SyncPresentation.instance.value;
    if (next.isEmpty) {
      _hideTimer?.cancel();
      _animationController.reset();
      setState(() {
        _progress = next;
        _dismissed = false;
        _shouldShow = false;
      });
      return;
    }
    final starting =
        next.isActive &&
        (!_progress.isActive || next.phase == SyncPhase.checkingConnection);
    _hideTimer?.cancel();
    setState(() {
      if (starting || (next.isFailure && next.phase != _progress.phase)) {
        _dismissed = false;
      }
      _progress = next;
      if (!_dismissed) _shouldShow = true;
    });
    if (!_dismissed) _animationController.forward();
    if (!next.isActive) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_progress.isFailure) return;
    _hideTimer = Timer(const Duration(seconds: 3), () async {
      await _animationController.reverse();
      if (mounted && !_progress.isActive) {
        setState(() => _shouldShow = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible ||
        !AppState.showSyncProgress ||
        !_shouldShow ||
        (!widget.showActivity && _progress.isActive)) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 16,
      right: 16,
      bottom: widget.bottom + MediaQuery.paddingOf(context).bottom,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            // A swipe already in flight belongs to the previous message.
            key: ValueKey(_progress.isFailure ? _progress.phase : null),
            child: Dismissible(
              key: const ValueKey('sync_progress'),
              direction: DismissDirection.down,
              onDismissed: (_) {
                _hideTimer?.cancel();
                _dismissed = true;
                setState(() => _shouldShow = false);
              },
              child: ListenableBuilder(
                listenable: _cardSettings,
                builder: (context, _) {
                  return _SyncProgressCard(
                    syncStatus: _progress,
                    isSyncing: _progress.isActive,
                    failedCount: _progress.failedCount,
                    onRetry: NoteSyncBatch.active.value ? null : _retry,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the heavy notes grid for the duration of a bulk note transfer.
class BulkSyncProgress extends StatelessWidget {
  const BulkSyncProgress({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      NoteSyncBatch.progress,
      AppState.showSyncProgressNotifier,
    ]),
    builder: (context, _) => SyncContentProgress(
      progress: SyncProgress(
        SyncPhase.syncing,
        notes: NoteSyncBatch.progress.value,
      ),
    ),
  );
}

/// Centered progress for an empty library, including the initial bulk restore.
class SyncContentProgress extends StatelessWidget {
  const SyncContentProgress({super.key, required this.progress});

  final SyncProgress progress;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Semantics(
        label: AppState.showSyncProgress
            ? null
            : progress.localized(context.l10n),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActivityIcon(
              download: progress.notes?.stage == NoteTransferStage.downloading,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
            ),
            if (AppState.showSyncProgress) ...[
              const SizedBox(height: 12),
              Text(
                progress.localized(context.l10n),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (progress.notes?.stage == NoteTransferStage.checking ||
                  progress.phase == SyncPhase.fetchingUpdates ||
                  progress.phase == SyncPhase.checkingForUpdates)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    context.l10n.syncCheckingLibraryHint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (progress.notes case final transfer?
                  when transfer.stage == NoteTransferStage.downloading &&
                      transfer.fraction != null)
                _DownloadProgress(transfer),
            ],
          ],
        ),
      ),
    ),
  );
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress(this.transfer);
  static final _percentFormats = <String, NumberFormat>{};
  final NoteTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final percent = (100 * transfer.done ~/ transfer.total!).clamp(0, 100);
    final percentage = _percentFormats
        .putIfAbsent(locale, () => NumberFormat.percentPattern(locale))
        .format(percent / 100);
    final total = context.l10n.syncTotalNotes(transfer.total!);
    return SizedBox(
      width: 192,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: transfer.fraction,
              semanticsLabel: total,
              semanticsValue: percentage,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                children: [
                  Text(total, style: Theme.of(context).textTheme.labelSmall),
                  Text(
                    percentage,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncProgressCard extends StatelessWidget {
  final SyncProgress syncStatus;
  final bool isSyncing;
  final int failedCount;
  final VoidCallback? onRetry;

  const _SyncProgressCard({
    required this.syncStatus,
    required this.isSyncing,
    required this.failedCount,
    required this.onRetry,
  });

  /// Determines the message type based on current state
  _MessageType get _messageType {
    if (hasFailed || syncStatus.isFailure) return _MessageType.error;
    if (syncStatus.isSuccess) return _MessageType.success;
    return _MessageType.info;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final messageType = _messageType;
    final (accentColor, backgroundColor, borderColor) = switch (messageType) {
      _MessageType.error => (
        colorScheme.error,
        colorScheme.errorContainer.withValues(alpha: 0.3),
        colorScheme.error.withValues(alpha: 0.4),
      ),
      _MessageType.success => (
        Colors.green,
        Colors.green.withValues(alpha: 0.1),
        Colors.green.withValues(alpha: 0.3),
      ),
      _MessageType.info => (
        colorScheme.primary,
        colorScheme.primaryContainer.withValues(alpha: 0.3),
        colorScheme.primary.withValues(alpha: 0.2),
      ),
    };

    final statusText = _buildStatusText(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Card(
          elevation: 4,
          color: backgroundColor,
          shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: syncStatus.isFailure ? 4 : 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStateIcon(accentColor, messageType),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: accentColor,
                        ),
                      ),
                      if (syncStatus.notes case final transfer?
                          when transfer.stage ==
                                  NoteTransferStage.downloading &&
                              transfer.fraction != null)
                        _DownloadProgress(transfer),
                    ],
                  ),
                ),
                // Animated refresh button (fades in/out)
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: syncStatus.isFailure
                      ? IconButton(
                          tooltip: context.l10n.retry,
                          icon: const Icon(Icons.refresh, size: 18),
                          color: accentColor,
                          constraints: const BoxConstraints.tightFor(
                            width: 48,
                            height: 48,
                          ),
                          onPressed: onRetry,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _buildStatusText(BuildContext context) {
    if (hasFailed && syncStatus.isEmpty) {
      return context.l10n.syncFailedCount(failedCount);
    }
    if (!syncStatus.isEmpty) {
      return syncStatus.localized(
        context.l10n,
        providerSelectionRequired:
            FirebaseSyncPreference.instance.allTransfersPaused,
        cloudUploadsRequirePro:
            !PlanService.instance.entitlements.realtimeCloudSync,
      );
    }
    // This case shouldn't be reached since widget won't show without content
    return "";
  }

  Widget _buildStateIcon(Color color, _MessageType type) {
    if (isSyncing) {
      final download = syncStatus.notes?.stage == NoteTransferStage.downloading;
      return _ActivityIcon(download: download, size: 16, color: color);
    }
    return Icon(
      switch (type) {
        _MessageType.error => Icons.error_outline,
        _MessageType.success => Icons.check_circle_outline,
        _MessageType.info => Icons.sync,
      },
      size: 16,
      color: color,
    );
  }

  bool get hasFailed => failedCount > 0 && !isSyncing;
}

class _ActivityIcon extends StatefulWidget {
  const _ActivityIcon({
    required this.download,
    required this.size,
    required this.color,
  });

  final bool download;
  final double size;
  final Color color;

  @override
  State<_ActivityIcon> createState() => _ActivityIconState();
}

class _ActivityIconState extends State<_ActivityIcon>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(_ActivityIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.download != widget.download) {
      _motion.value = 0;
      _updateMotion();
    }
  }

  void _updateMotion() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _motion.value = 0;
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.download) {
      return RotationTransition(
        turns: _motion,
        child: Icon(Icons.sync, size: widget.size, color: widget.color),
      );
    }
    return CustomPaint(
      key: const ValueKey('download_activity'),
      size: Size.square(widget.size),
      painter: _DownloadPainter(_motion, widget.color),
    );
  }
}

// The arrow collapses into a parcel, lands in the tray, then draws in again.
class _DownloadPainter extends CustomPainter {
  _DownloadPainter(this.motion, this.color) : super(repaint: motion);
  final Animation<double> motion;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = motion.value;
    double phase(double start, double end) =>
        Interval(start, end, curve: Curves.easeInOut).transform(t);
    final drop = phase(.12, .54);
    final draw = phase(.66, .96);
    final arrow = 1 - drop + draw;
    final tip = 14 + 4 * (drop - phase(.55, .66));
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final impact = phase(.40, .55) - phase(.55, .82);
    canvas.drawPath(
      Path()
        ..moveTo(3, 15)
        ..lineTo(3, 17)
        ..quadraticBezierTo(3, 19, 5, 19)
        ..quadraticBezierTo(12, 19 + 3 * impact, 19, 19)
        ..quadraticBezierTo(21, 19, 21, 17)
        ..lineTo(21, 15),
      stroke,
    );
    // Fade the parcel into the tray before drawing the next arrow.
    stroke.color = color.withValues(
      alpha: color.a * (1 - phase(.50, .56) + draw),
    );
    canvas.drawLine(Offset(12, tip - 11 * arrow), Offset(12, tip), stroke);
    canvas.drawPath(
      Path()
        ..moveTo(12 - 4.5 * arrow, tip - 4.5 * arrow)
        ..lineTo(12, tip)
        ..lineTo(12 + 4.5 * arrow, tip - 4.5 * arrow),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DownloadPainter old) =>
      old.color != color || old.motion != motion;
}

enum _MessageType { info, success, error }

/// The same immediate activity indicator for desktop and web refresh actions.
class SyncRefreshButton extends StatelessWidget {
  const SyncRefreshButton({super.key, required this.onRefresh});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      SyncPresentation.instance,
      NoteSyncBatch.active,
      AppState.showSyncProgressNotifier,
    ]),
    builder: (context, _) {
      final progress = SyncPresentation.instance.value;
      return IconButton(
        onPressed: progress.isActive || NoteSyncBatch.active.value
            ? null
            : onRefresh,
        tooltip: progress.isActive
            ? progress.localized(context.l10n)
            : context.l10n.refresh,
        icon:
            progress.isActive &&
                !AppState.showSyncProgress &&
                !NoteSyncBatch.active.value
            ? SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: progress.localized(context.l10n),
                ),
              )
            : const Icon(Icons.refresh),
      );
    },
  );
}
