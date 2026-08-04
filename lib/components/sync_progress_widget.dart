import 'dart:async';
import 'dart:ui';

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
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
    final e2eeService = E2EEService.instance;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 32 + bottomPadding,
      // First, listen for E2EE background verification
      child: ValueListenableBuilder<bool>(
        valueListenable: e2eeService.isVerifyingInBackground,
        builder: (context, isVerifyingE2EE, child) {
          // Show E2EE verification status when verifying in background
          if (isVerifyingE2EE && !_dismissed) {
            _hideTimer?.cancel();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _show();
            });
          }

          return ValueListenableBuilder<bool>(
            valueListenable: syncService.isSyncing,
            builder: (context, isSyncing, child) {
              // Reset dismissed state and show widget when a new sync starts
              if (isSyncing) {
                if (_dismissed) _dismissed = false;
                _hideTimer?.cancel();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _show();
                });
              } else if (_shouldShow && !_dismissed && !isVerifyingE2EE) {
                // Sync finished and not verifying E2EE, schedule hide after delay
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

                      return ValueListenableBuilder<SyncProgress>(
                        valueListenable: syncService.syncStatus,
                        builder: (context, syncStatus, child) {
                          return ValueListenableBuilder<ProtectionProgress?>(
                            valueListenable:
                                e2eeService.backgroundVerificationProgress,
                            builder: (context, protectionProgress, child) {
                              // Check if there's meaningful content to show
                              final hasContent =
                                  totalCount > 0 ||
                                  !syncStatus.isEmpty ||
                                  protectionProgress != null ||
                                  (failedSet.isNotEmpty && !isSyncing) ||
                                  isVerifyingE2EE;

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
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        curve: Curves.easeInOut,
                                        child: _SyncProgressCard(
                                          syncedCount: syncedCount,
                                          totalCount: totalCount,
                                          syncStatus: syncStatus,
                                          protectionProgress:
                                              protectionProgress,
                                          isSyncing: isSyncing,
                                          failedCount:
                                              syncStatus.failedCount > 0
                                              ? syncStatus.failedCount
                                              : failedSet.length,
                                          isVerifyingE2EE: isVerifyingE2EE,
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
  final SyncProgress syncStatus;
  final ProtectionProgress? protectionProgress;
  final bool isSyncing;
  final int failedCount;
  final bool isVerifyingE2EE;

  const _SyncProgressCard({
    required this.syncedCount,
    required this.totalCount,
    required this.syncStatus,
    required this.protectionProgress,
    required this.isSyncing,
    required this.failedCount,
    this.isVerifyingE2EE = false,
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
    final shouldAnimate = widget.isSyncing || widget.isVerifyingE2EE;
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
  ProtectionProgress? get protectionProgress => widget.protectionProgress;
  bool get isSyncing => widget.isSyncing;
  int get failedCount => widget.failedCount;
  bool get isVerifyingE2EE => widget.isVerifyingE2EE;

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

  String _buildStatusText(BuildContext context) {
    if (isVerifyingE2EE && protectionProgress != null) {
      return protectionProgress!.localized(context.l10n);
    }
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
