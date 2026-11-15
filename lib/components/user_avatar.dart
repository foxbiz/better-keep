import 'dart:math' as math;

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:flutter/material.dart';

class _AvatarCache {
  static MemoryImage? _cachedImage;
  static bool _isLoading = false;
  static bool _useDefaultIcon = false;
  static int _generation = 0;
  static String? _ownerUid;

  /// Notifier that fires when the avatar cache state changes (loaded or invalidated)
  static final ValueNotifier<int> cacheVersion = ValueNotifier(0);

  /// Check if we should retry loading (e.g., if we previously had no URL but now we do)
  static bool _shouldRetryLoad() {
    if (!_useDefaultIcon || !FirebaseBackend.isConfigured) return false;
    if (_cachedImage != null || _isLoading) return false;

    // Check if a photo URL is now available
    final user = AuthService.currentUser;
    final cached = AuthService.cachedProfile;
    final localPath = AuthService.localPhotoPath;
    final photoURL = localPath?.isNotEmpty == true
        ? localPath
        : (user?.photoURL ?? cached?['photoURL'] ?? '');

    return photoURL?.isNotEmpty == true;
  }

  static Future<void> loadAvatar() async {
    final uid = FirebaseBackend.isConfigured
        ? AuthService.currentUser?.uid
        : null;
    if (_ownerUid != uid) {
      invalidate(notify: false);
      _ownerUid = uid;
    }
    if (_shouldRetryLoad()) _useDefaultIcon = false;
    if (_cachedImage != null || _useDefaultIcon || _isLoading) return;

    final generation = _generation;
    final sessionCurrent = AuthService.captureSessionIdentity();
    bool current() =>
        generation == _generation &&
        sessionCurrent() &&
        (FirebaseBackend.isConfigured ? AuthService.currentUser?.uid : null) ==
            uid;
    _isLoading = true;
    try {
      // The auth service owns the bounded download and persistent cache. Do not
      // start a second HTTP request while account startup is fetching the photo.
      await AuthService.ensureProfileImageCached();
      if (!current()) return;
      final path = FirebaseBackend.isConfigured
          ? AuthService.localPhotoPath
          : null;
      final fs = path == null ? null : await fileSystem();
      final bytes = path != null && await fs!.exists(path)
          ? await fs.readBytes(path)
          : null;
      if (!current()) return;
      _cachedImage = bytes == null ? null : MemoryImage(bytes);
      _useDefaultIcon = bytes == null;
    } catch (_) {
      if (current()) _useDefaultIcon = true;
    } finally {
      if (current()) {
        _isLoading = false;
        cacheVersion.value++;
      }
    }
  }

  static void invalidate({bool notify = true}) {
    _generation++;
    _cachedImage = null;
    _isLoading = false;
    _useDefaultIcon = false;
    // Loading may start during widget construction; notify only after its await.
    if (notify) cacheVersion.value++;
  }
}

class UserAvatar extends StatefulWidget {
  final double size;
  final String? heroTag;
  final bool showPendingBadge;
  final bool showProBorder;
  const UserAvatar({
    super.key,
    this.size = 50,
    this.heroTag,
    this.showPendingBadge = false,
    this.showProBorder = false,
  });

  /// Invalidate the cached avatar image (call when user changes profile photo)
  static void invalidateCache() {
    _AvatarCache.invalidate();
  }

  /// Pre-load the avatar image. Call this early in app lifecycle.
  static Future<void> preloadAvatar() {
    return _AvatarCache.loadAvatar();
  }

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> with TickerProviderStateMixin {
  AnimationController? _animationController;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    _initAnimationIfNeeded();
    // Listen to avatar cache changes to rebuild when avatar loads
    _AvatarCache.cacheVersion.addListener(_onCacheChange);
    // Ensure avatar is loading (triggers load if not already loaded/loading)
    _AvatarCache.loadAvatar();
    // Listen to subscription changes to update the pro border
    if (widget.showProBorder) {
      PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);
    }
  }

  void _onCacheChange() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onSubscriptionChange() {
    if (mounted) {
      _initAnimationIfNeeded();
      _syncBorderAnimation();
      setState(() {});
    }
  }

  void _initAnimationIfNeeded() {
    final isPro = widget.showProBorder && PlanService.instance.isPaid;
    if (isPro && _animationController == null) {
      _animationController = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 3),
      );
    } else if (!isPro && _animationController != null) {
      _animationController?.dispose();
      _animationController = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;

    _disableAnimations = disableAnimations;
    _syncBorderAnimation();
  }

  void _syncBorderAnimation() {
    final controller = _animationController;
    if (controller == null) return;

    if (_disableAnimations == true) {
      controller.stop();
      controller.value = controller.upperBound;
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void didUpdateWidget(UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showProBorder != oldWidget.showProBorder) {
      if (oldWidget.showProBorder) {
        PlanService.instance.statusNotifier.removeListener(
          _onSubscriptionChange,
        );
      }
      if (widget.showProBorder) {
        PlanService.instance.statusNotifier.addListener(_onSubscriptionChange);
      }
    }
    _initAnimationIfNeeded();
    _syncBorderAnimation();
  }

  @override
  void dispose() {
    _AvatarCache.cacheVersion.removeListener(_onCacheChange);
    PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    _animationController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cachedImage = _AvatarCache._cachedImage;
    final useDefaultIcon = _AvatarCache._useDefaultIcon;
    final isLoading = cachedImage == null && !useDefaultIcon;
    final colorScheme = Theme.of(context).colorScheme;

    final avatar = CircleAvatar(
      backgroundColor: isLoading ? Colors.grey : colorScheme.primaryContainer,
      radius: widget.size,
      backgroundImage: cachedImage,
      child: isLoading
          ? SizedBox(
              width: widget.size,
              height: widget.size,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : useDefaultIcon
          ? Icon(
              Icons.person,
              size: widget.size,
              color: colorScheme.onPrimaryContainer,
            )
          : null,
    );

    // Wrap with badge if needed
    Widget result = avatar;

    // Add animated premium border for pro users
    final isPro = widget.showProBorder && PlanService.instance.isPaid;
    if (isPro && _animationController != null) {
      result = AnimatedBuilder(
        animation: _animationController!,
        builder: (context, child) {
          return CustomPaint(
            painter: _AnimatedGradientBorderPainter(
              progress: _animationController!.value,
              strokeWidth: 3,
            ),
            child: Padding(padding: const EdgeInsets.all(4), child: child),
          );
        },
        child: avatar,
      );
    }

    if (widget.showPendingBadge) {
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          result,
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: widget.size * 0.4,
              height: widget.size * 0.4,
              decoration: BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.priority_high,
                size: widget.size * 0.25,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    if (widget.heroTag != null) {
      return Hero(tag: widget.heroTag!, child: result);
    }

    return result;
  }
}

/// Custom painter for animated gradient border
class _AnimatedGradientBorderPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;

  _AnimatedGradientBorderPainter({
    required this.progress,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - (strokeWidth / 2);

    // Rotate the gradient based on animation progress
    final rotationAngle = progress * 2 * math.pi;

    final gradient = SweepGradient(
      transform: GradientRotation(rotationAngle),
      colors: const [
        Color(0xFFFFD700), // Gold
        Color(0xFFFF8C00), // Dark Orange
        Color(0xFFFF1493), // Deep Pink
        Color(0xFFDA70D6), // Orchid
        Color(0xFF9370DB), // Medium Purple
        Color(0xFF00CED1), // Dark Turquoise
        Color(0xFF00FA9A), // Medium Spring Green
        Color(0xFFFFD700), // Gold (loop back)
      ],
      stops: const [0.0, 0.14, 0.28, 0.42, 0.57, 0.71, 0.85, 1.0],
    );

    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromCircle(center: center, radius: radius),
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_AnimatedGradientBorderPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
