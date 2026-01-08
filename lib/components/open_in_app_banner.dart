import 'package:better_keep/services/app_install_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// A banner that prompts users to open the native app when detected
/// This is shown on web when the user has the native app installed
class OpenInAppBanner extends StatefulWidget {
  const OpenInAppBanner({super.key});

  @override
  State<OpenInAppBanner> createState() => _OpenInAppBannerState();
}

class _OpenInAppBannerState extends State<OpenInAppBanner>
    with SingleTickerProviderStateMixin {
  OpenAppBannerInfo? _bannerInfo;
  bool _isLoading = true;
  bool _isDismissed = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );

    if (kIsWeb) {
      _checkShouldShow();
    } else {
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _checkShouldShow() async {
    final info = await AppInstallService.instance.shouldShowOpenAppBanner();

    if (mounted) {
      setState(() {
        _bannerInfo = info;
        _isLoading = false;
      });

      if (info != null && info.show) {
        _animationController.forward();
      }
    }
  }

  void _onOpenApp() {
    // Try to open the native app using deep link
    AppInstallService.instance.tryOpenNativeApp();
  }

  void _onDismiss() {
    AppInstallService.instance.markOpenAppBannerDismissed();
    _animationController.reverse().then((_) {
      if (mounted) {
        setState(() {
          _isDismissed = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Don't show on non-web platforms
    if (!kIsWeb) {
      return const SizedBox.shrink();
    }

    // Still loading or already dismissed
    if (_isLoading || _isDismissed) {
      return const SizedBox.shrink();
    }

    // No banner info or shouldn't show
    if (_bannerInfo == null || !_bannerInfo!.show) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isAndroid = _bannerInfo!.platform == 'android';

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
              .animate(
                CurvedAnimation(
                  parent: _animationController,
                  curve: Curves.easeOut,
                ),
              ),
          child: FadeTransition(opacity: _fadeAnimation, child: child),
        );
      },
      child: Material(
        elevation: 4,
        color: theme.colorScheme.primaryContainer,
        child: SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // App icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.note_alt_rounded,
                    color: theme.colorScheme.onPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Better Keep',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        isAndroid
                            ? 'Open in the app for the best experience'
                            : 'Use the app for a better experience',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer
                              .withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                // Open button
                FilledButton(
                  onPressed: _onOpenApp,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  child: const Text('Open'),
                ),
                // Close button
                IconButton(
                  icon: Icon(
                    Icons.close,
                    color: theme.colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                  onPressed: _onDismiss,
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
