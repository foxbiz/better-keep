import 'dart:io';
import 'dart:math' as math;
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class _AvatarCache {
  static Uint8List? _cachedBytes;
  static MemoryImage? _cachedImage;
  static bool _isLoading = false;
  static bool _useDefaultIcon = false;

  /// Notifier that fires when the avatar cache state changes (loaded or invalidated)
  static final ValueNotifier<int> cacheVersion = ValueNotifier(0);

  /// Check if we should retry loading (e.g., if we previously had no URL but now we do)
  static bool _shouldRetryLoad() {
    if (!_useDefaultIcon) return false;
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
    // If we previously set useDefaultIcon but now have a URL, retry
    if (_shouldRetryLoad()) {
      _useDefaultIcon = false;
    }

    if (_cachedImage != null || _useDefaultIcon || _isLoading) {
      return;
    }

    _isLoading = true;
    try {
      final fs = await fileSystem();
      final user = AuthService.currentUser;
      final cached = AuthService.cachedProfile;

      String photoURL = AuthService.localPhotoPath ?? '';

      if (photoURL.isEmpty || !(await fs.exists(photoURL))) {
        photoURL = user?.photoURL ?? cached?['photoURL'] ?? '';
      }

      if (photoURL.isEmpty) {
        // Use default icon instead of PNG
        _useDefaultIcon = true;
      } else if (photoURL.startsWith('http')) {
        try {
          final httpClient = HttpClient();
          final request = await httpClient.getUrl(Uri.parse(photoURL));
          final response = await request.close();
          _cachedBytes = await consolidateHttpClientResponseBytes(response);
        } catch (e) {
          // Fallback to default icon
          _useDefaultIcon = true;
        }
      } else {
        _cachedBytes = await fs.readBytes(photoURL);
      }

      // Create single MemoryImage instance to share across all widgets
      if (_cachedBytes != null) {
        _cachedImage = MemoryImage(_cachedBytes!);
      }
    } catch (e) {
      // Fallback to default icon on error
      _useDefaultIcon = true;
    }

    _isLoading = false;
    // Notify listeners that the cache has been updated
    cacheVersion.value++;
  }

  static void invalidate() {
    _cachedBytes = null;
    _cachedImage = null;
    _isLoading = false;
    _useDefaultIcon = false;
    // Notify listeners that the cache has been invalidated
    cacheVersion.value++;
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
      final isPro = widget.showProBorder && PlanService.instance.isPaid;
      // Dispose animation controller if no longer pro
      if (!isPro && _animationController != null) {
        _animationController?.dispose();
        _animationController = null;
      }
      // Create animation controller if now pro
      _initAnimationIfNeeded();
      setState(() {});
    }
  }

  void _initAnimationIfNeeded() {
    final isPro = widget.showProBorder && PlanService.instance.isPaid;
    if (isPro && _animationController == null) {
      _animationController = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 3),
      )..repeat();
    }
  }

  @override
  void didUpdateWidget(UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _initAnimationIfNeeded();
  }

  @override
  void dispose() {
    _AvatarCache.cacheVersion.removeListener(_onCacheChange);
    if (widget.showProBorder) {
      PlanService.instance.statusNotifier.removeListener(_onSubscriptionChange);
    }
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
