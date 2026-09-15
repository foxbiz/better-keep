import 'package:better_keep/utils/manual_sync_refresh.dart';
import 'dart:async';
import 'dart:ui';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/sync_presentation.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/progress_localizations.dart';
import 'package:flutter/material.dart';

/// A floating widget that shows sync progress at the bottom of the screen.
/// Shows synced count / total count and current status message.
class SyncProgressWidget extends StatefulWidget {
  const SyncProgressWidget({super.key});

  @override
  State<SyncProgressWidget> createState() => _SyncProgressWidgetState();
}

class _SyncProgressWidgetState extends State<SyncProgressWidget>
    with SingleTickerProviderStateMixin {
  late SyncProgress _progress;
  bool _dismissed = false;
  bool _shouldShow = false;
  Timer? _hideTimer;
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
    SyncPresentation.instance.addListener(_onProgressChanged);
  }

  @override
  void dispose() {
    SyncPresentation.instance.removeListener(_onProgressChanged);
    _hideTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

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
        (!_progress.isActive || SyncPresentation.instance.isManualRefresh);
    _hideTimer?.cancel();
    setState(() {
      _progress = next;
      if (starting) _dismissed = false;
      if (!_dismissed) _shouldShow = true;
    });
    if (!_dismissed) _animationController.forward();
    if (!next.isActive) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () async {
      await _animationController.reverse();
      if (mounted && !_progress.isActive) {
        setState(() => _shouldShow = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!AppState.showSyncProgress || !_shouldShow) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 32 + MediaQuery.of(context).padding.bottom,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            child: Dismissible(
              key: const ValueKey('sync_progress'),
              direction: DismissDirection.down,
              onDismissed: (_) {
                _hideTimer?.cancel();
                _dismissed = true;
                setState(() => _shouldShow = false);
              },
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  NoteSyncService().syncProgress,
                  NoteSyncService().isSyncing,
                ]),
                builder: (context, _) {
                  final counts = NoteSyncService().syncProgress.value;
                  final showCounts =
                      _progress.phase == SyncPhase.syncing &&
                      NoteSyncService().isSyncing.value;
                  return _SyncProgressCard(
                    syncedCount: showCounts ? counts.$1 : 0,
                    totalCount: showCounts ? counts.$2 : 0,
                    syncStatus: _progress,
                    isSyncing: _progress.isActive,
                    failedCount: _progress.failedCount,
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

class _SyncProgressCard extends StatefulWidget {
  final int syncedCount;
  final int totalCount;
  final SyncProgress syncStatus;
  final bool isSyncing;
  final int failedCount;

  const _SyncProgressCard({
    required this.syncedCount,
    required this.totalCount,
    required this.syncStatus,
    required this.isSyncing,
    required this.failedCount,
  });

  @override
  State<_SyncProgressCard> createState() => _SyncProgressCardState();
}

class _SyncProgressCardState extends State<_SyncProgressCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;

    _disableAnimations = disableAnimations;
    _syncRotationAnimation();
  }

  @override
  void didUpdateWidget(_SyncProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRotationAnimation();
  }

  void _syncRotationAnimation() {
    final shouldAnimate = widget.isSyncing;
    if (!shouldAnimate) {
      _rotationController.stop();
      _rotationController.reset();
    } else if (_disableAnimations == true) {
      _rotationController.stop();
      _rotationController.value = _rotationController.upperBound;
    } else if (!_rotationController.isAnimating) {
      _rotationController.repeat();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  int get syncedCount => widget.syncedCount;
  int get totalCount => widget.totalCount;
  SyncProgress get syncStatus => widget.syncStatus;
  bool get isSyncing => widget.isSyncing;
  int get failedCount => widget.failedCount;

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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated icon switcher
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  child: _buildStateIcon(accentColor, messageType),
                ),
                const SizedBox(width: 10),
                // Animated text switcher
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Text(
                      statusText,
                      key: ValueKey(statusText),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: accentColor,
                      ),
                    ),
                  ),
                ),
                // Animated refresh button (fades in/out)
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: hasFailed
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 6),
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => refreshSyncFromUser(context),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.refresh,
                                    size: 16,
                                    color: accentColor,
                                  ),
                                ),
                              ),
                            ),
                          ],
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
    if (hasProgress) {
      return "$syncedCount/$totalCount";
    }
    if (!syncStatus.isEmpty) {
      return syncStatus.localized(context.l10n);
    }
    // This case shouldn't be reached since widget won't show without content
    return "";
  }

  /// Builds the icon for the current sync state with a unique key.
  /// Uses a single conditional to ensure only one icon is built per state.
  Widget _buildStateIcon(Color accentColor, _MessageType messageType) {
    // Determine the current state key - only one can be active at a time
    final String stateKey;
    final Widget icon;

    if (isSyncing) {
      stateKey = 'syncing';
      icon = RotationTransition(
        turns: _rotationController,
        child: Icon(Icons.sync, size: 16, color: accentColor),
      );
    } else if (hasFailed) {
      stateKey = 'failed';
      icon = Icon(Icons.error_outline, size: 16, color: accentColor);
    } else if (messageType == _MessageType.success) {
      stateKey = 'success';
      icon = Icon(Icons.check_circle_outline, size: 16, color: accentColor);
    } else {
      stateKey = 'default';
      icon = Icon(Icons.sync, size: 16, color: accentColor);
    }

    return KeyedSubtree(key: ValueKey(stateKey), child: icon);
  }

  bool get hasFailed => failedCount > 0 && !isSyncing;
  bool get hasProgress => totalCount > 0;
}

enum _MessageType { info, success, error }

/// The same immediate activity indicator for desktop and web refresh actions.
class SyncRefreshButton extends StatelessWidget {
  const SyncRefreshButton({super.key, required this.onRefresh});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SyncProgress>(
    valueListenable: SyncPresentation.instance,
    builder: (context, progress, _) => IconButton(
      onPressed: progress.isActive ? null : onRefresh,
      tooltip: progress.isActive
          ? progress.localized(context.l10n)
          : context.l10n.refresh,
      icon: progress.isActive
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: progress.localized(context.l10n),
              ),
            )
          : const Icon(Icons.refresh),
    ),
  );
}
