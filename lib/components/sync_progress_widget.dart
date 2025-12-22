import 'dart:async';
import 'dart:ui';

import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
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
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _show() {
    if (!_shouldShow) {
      setState(() => _shouldShow = true);
      _animationController.forward();
    }
  }

  void _hide() {
    _animationController.reverse().then((_) {
      if (mounted) {
        setState(() => _shouldShow = false);
      }
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_dismissed) {
        _hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Check if sync progress is disabled in settings
    if (!AppState.showSyncProgress) {
      return const SizedBox.shrink();
    }

    final syncService = NoteSyncService();
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 32 + bottomPadding,
      child: ValueListenableBuilder<bool>(
        valueListenable: syncService.isSyncing,
        builder: (context, isSyncing, child) {
          // Reset dismissed state and show widget when a new sync starts
          if (isSyncing) {
            if (_dismissed) _dismissed = false;
            _hideTimer?.cancel();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _show();
            });
          } else if (_shouldShow && !_dismissed) {
            // Sync finished, schedule hide after delay
            _scheduleHide();
          }

          return ValueListenableBuilder<Set<int>>(
            valueListenable: syncService.syncFailed,
            builder: (context, failedSet, child) {
              // Keep visible if there are failed syncs
              if (failedSet.isNotEmpty && !_dismissed) {
                _hideTimer?.cancel();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _show();
                });
              }

              return ValueListenableBuilder<(int, int)>(
                valueListenable: syncService.syncProgress,
                builder: (context, progress, child) {
                  final (syncedCount, totalCount) = progress;

                  return ValueListenableBuilder<String>(
                    valueListenable: syncService.statusMessage,
                    builder: (context, statusMessage, child) {
                      // Check if there's meaningful content to show
                      final hasContent =
                          totalCount > 0 ||
                          statusMessage.isNotEmpty ||
                          (failedSet.isNotEmpty && !isSyncing);

                      // Don't render if not showing or no content
                      if (!_shouldShow || !hasContent) {
                        return const SizedBox.shrink();
                      }

                      return SlideTransition(
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
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                child: _SyncProgressCard(
                                  syncedCount: syncedCount,
                                  totalCount: totalCount,
                                  statusMessage: statusMessage,
                                  isSyncing: isSyncing,
                                  failedCount: failedSet.length,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _SyncProgressCard extends StatefulWidget {
  final int syncedCount;
  final int totalCount;
  final String statusMessage;
  final bool isSyncing;
  final int failedCount;

  const _SyncProgressCard({
    required this.syncedCount,
    required this.totalCount,
    required this.statusMessage,
    required this.isSyncing,
    required this.failedCount,
  });

  @override
  State<_SyncProgressCard> createState() => _SyncProgressCardState();
}

class _SyncProgressCardState extends State<_SyncProgressCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    if (widget.isSyncing) {
      _rotationController.repeat();
    }
  }

  @override
  void didUpdateWidget(_SyncProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSyncing && !_rotationController.isAnimating) {
      _rotationController.repeat();
    } else if (!widget.isSyncing && _rotationController.isAnimating) {
      _rotationController.stop();
      _rotationController.reset();
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  int get syncedCount => widget.syncedCount;
  int get totalCount => widget.totalCount;
  String get statusMessage => widget.statusMessage;
  bool get isSyncing => widget.isSyncing;
  int get failedCount => widget.failedCount;

  /// Determines the message type based on current state
  _MessageType get _messageType {
    if (hasFailed) return _MessageType.error;
    if (statusMessage.contains('Complete')) return _MessageType.success;
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

    final statusText = _buildStatusText();

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
                  child: isSyncing
                      ? RotationTransition(
                          key: const ValueKey('syncing'),
                          turns: _rotationController,
                          child: Icon(Icons.sync, size: 16, color: accentColor),
                        )
                      : hasFailed
                      ? Icon(
                          Icons.error_outline,
                          key: const ValueKey('failed'),
                          size: 16,
                          color: accentColor,
                        )
                      : messageType == _MessageType.success
                      ? Icon(
                          Icons.check_circle_outline,
                          key: const ValueKey('success'),
                          size: 16,
                          color: accentColor,
                        )
                      : Icon(
                          Icons.sync,
                          key: const ValueKey('default'),
                          size: 16,
                          color: accentColor,
                        ),
                ),
                const SizedBox(width: 10),
                // Animated text switcher
                AnimatedSwitcher(
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
                                onTap: () => NoteSyncService().refresh(),
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

  String _buildStatusText() {
    if (hasFailed && statusMessage.isEmpty) {
      return "$failedCount failed";
    }
    if (hasProgress) {
      return "$syncedCount/$totalCount";
    }
    if (statusMessage.isNotEmpty) {
      return statusMessage;
    }
    // This case shouldn't be reached since widget won't show without content
    return "";
  }

  bool get hasFailed => failedCount > 0 && !isSyncing;
  bool get hasProgress => totalCount > 0;
}

enum _MessageType { info, success, error }
