import 'dart:math' as math;

import 'package:better_keep/pages/email_login_page.dart';
import 'package:better_keep/services/apple_auth.dart';
import 'package:better_keep/services/auth_error_messages.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with TickerProviderStateMixin {
  bool _isLoading = false;
  String _statusMessage = "";
  String _version = '';

  late final AnimationController _logoController;
  late final AnimationController _contentController;
  late final AnimationController _pulseController;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoRotation;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _buttonOpacity;
  late final Animation<Offset> _buttonSlide;
  late final Animation<double> _pulseAnimation;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    _loadVersion();

    // Logo animation controller
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    // Content fade-in controller
    _contentController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    // Subtle pulse animation for logo
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    // Logo scale animation with bounce
    _logoScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.15,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.15,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
    ]).animate(_logoController);

    // Logo rotation animation
    _logoRotation = Tween<double>(begin: -0.1, end: 0.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    // Title fade and slide
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _contentController,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          ),
        );

    // Button fade and slide
    _buttonOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentController,
        curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
      ),
    );

    _buttonSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _contentController,
            curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
          ),
        );

    // Pulse animation
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Start animations
    _logoController.forward().then((_) {
      if (!mounted) return;
      _contentController.forward();
      if (_disableAnimations == true) {
        _pulseController.value = _pulseController.upperBound;
      } else {
        _pulseController.repeat(reverse: true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;

    _disableAnimations = disableAnimations;
    if (disableAnimations) {
      _logoController.stop();
      _logoController.value = _logoController.upperBound;
      _contentController.stop();
      _contentController.value = _contentController.upperBound;
      _pulseController.stop();
      _pulseController.value = _pulseController.upperBound;
    } else if (_logoController.isCompleted &&
        _contentController.isCompleted &&
        !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    }
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = packageInfo.version);
    }
  }

  @override
  void dispose() {
    _logoController.dispose();
    _contentController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handleSignIn(String provider) async {
    setState(() {
      _isLoading = true;
      _statusMessage = context.l10n.startingSignIn;
    });
    try {
      dynamic credential;

      switch (provider) {
        case 'google':
          credential = await AuthService.signInWithGoogle(
            onStatusChange: (status) {
              if (!mounted) {
                return;
              }

              AppLogger.log("[AUTH] Google sign-in status: $status");
              setState(() => _statusMessage = status);
            },
          );
          break;
        case 'apple':
          credential = await AuthService.signInWithApple(
            onStatusChange: (status) {
              if (mounted) setState(() => _statusMessage = status);
            },
          );
          break;
        case 'facebook':
          credential = await AuthService.signInWithFacebook(
            onStatusChange: (status) {
              if (mounted) setState(() => _statusMessage = status);
            },
          );
          break;
        case 'github':
          credential = await AuthService.signInWithGitHub(
            onStatusChange: (status) {
              if (mounted) setState(() => _statusMessage = status);
            },
          );
          break;
        case 'twitter':
          credential = await AuthService.signInWithTwitter(
            onStatusChange: (status) {
              if (mounted) setState(() => _statusMessage = status);
            },
          );
          break;
      }

      if (credential == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.signInCancelledMessage)),
          );
        }
      }
    } catch (e) {
      final errorMessage = resolveSignInErrorMessage(
        provider: provider,
        error: e,
      );
      String? actionText;
      VoidCallback? onAction;
      if (kIsWeb && isInsecureSignInError(e)) {
        actionText = 'Open HTTPS';
        onAction = () {
          launchUrl(
            Uri.parse('https://betterkeep.app'),
            webOnlyWindowName: '_self',
          );
        };
      }

      // Use global key because this widget might be unmounted if auth state changed
      AppState.scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
          action: actionText != null && onAction != null
              ? SnackBarAction(
                  label: actionText,
                  textColor: Colors.white,
                  onPressed: onAction,
                )
              : null,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    colorScheme.surface,
                    colorScheme.surface,
                    Colors.deepPurple.shade900.withValues(alpha: 0.3),
                  ]
                : [
                    colorScheme.surface,
                    colorScheme.primaryContainer.withValues(alpha: 0.3),
                    colorScheme.secondaryContainer.withValues(alpha: 0.5),
                  ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(left: 32, right: 32, top: 32),
              child: Column(
                children: [
                  _isLoading ? _buildLoadingState() : _buildLoginContent(),
                  if (_version.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'v$_version',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Animated logo during loading
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Transform.scale(scale: _pulseAnimation.value, child: child);
          },
          child: _buildLogo(size: 100),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              minHeight: 6,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
        ),
        const SizedBox(height: 24),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            _statusMessage,
            key: ValueKey(_statusMessage),
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 32),
        TextButton.icon(
          onPressed: () {
            AuthService.cancelPendingOAuth();
            setState(() {
              _isLoading = false;
              _statusMessage = '';
            });
          },
          icon: const Icon(Icons.close),
          label: Text(context.l10n.cancelSignIn),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginContent() {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Animated Logo
        AnimatedBuilder(
          animation: Listenable.merge([_logoController, _pulseController]),
          builder: (context, child) {
            return Transform.scale(
              scale:
                  _logoScale.value *
                  (_logoController.isCompleted ? _pulseAnimation.value : 1.0),
              child: Transform.rotate(
                angle: _logoRotation.value * math.pi,
                child: child,
              ),
            );
          },
          child: _buildLogo(size: 140),
        ),
        const SizedBox(height: 48),

        // Animated Title
        SlideTransition(
          position: _titleSlide,
          child: FadeTransition(
            opacity: _titleOpacity,
            child: Column(
              children: [
                Text(
                  context.l10n.appTitle,
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.yourNoteSecuredAndSynced,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 64),

        // Sign in options
        SlideTransition(
          position: _buttonSlide,
          child: FadeTransition(
            opacity: _buttonOpacity,
            child: _buildSignInOptions(),
          ),
        ),

        const SizedBox(height: 48),

        // Feature icons row at bottom (smaller)
        SlideTransition(
          position: _buttonSlide,
          child: FadeTransition(
            opacity: _buttonOpacity,
            child: _buildFeatureIcons(),
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureIcons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildFeatureIcon(
          icon: Icons.lock_outline,
          title: context.l10n.endToEndEncryptionFeature,
          description: context.l10n.endToEndEncryptionDescription,
          gradient: [Colors.green.shade400, Colors.teal.shade600],
        ),
        const SizedBox(width: 20),
        _buildFeatureIcon(
          icon: Icons.sync_outlined,
          title: context.l10n.seamlessSync,
          description: context.l10n.seamlessSyncDescription,
          gradient: [Colors.blue.shade400, Colors.indigo.shade600],
        ),
        const SizedBox(width: 20),
        _buildFeatureIcon(
          icon: Icons.palette_outlined,
          title: context.l10n.richFormatting,
          description: context.l10n.richFormattingDescription,
          gradient: [Colors.purple.shade400, Colors.deepPurple.shade600],
        ),
      ],
    );
  }

  Widget _buildFeatureIcon({
    required IconData icon,
    required String title,
    required String description,
    required List<Color> gradient,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => _showFeatureDialog(icon, title, description, gradient),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHigh.withValues(alpha: 0.6)
              : colorScheme.primaryContainer.withValues(alpha: 0.4),
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: isDark
              ? colorScheme.primary.withValues(alpha: 0.8)
              : colorScheme.primary,
        ),
      ),
    );
  }

  void _showFeatureDialog(
    IconData icon,
    String title,
    String description,
    List<Color> gradient,
  ) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(
            opacity: animation,
            child: _buildFeatureDialogContent(
              icon,
              title,
              description,
              gradient,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFeatureDialogContent(
    IconData icon,
    String title,
    String description,
    List<Color> gradient,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E2E) : Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: gradient[0].withValues(alpha: 0.3),
                    blurRadius: 40,
                    spreadRadius: 5,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icon with gradient background
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: gradient[0].withValues(alpha: 0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Icon(icon, size: 36, color: Colors.white),
                  ),
                  const SizedBox(height: 24),
                  // Title
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  // Description
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.7)
                          : Colors.black54,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  // Close button
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: gradient[0].withValues(alpha: 0.15),
                    ),
                    child: Text(
                      context.l10n.gotIt,
                      style: TextStyle(
                        color: gradient[1],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignInOptions() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate adaptive sizes based on available width
        // 5 buttons + 4 gaps, with some padding
        final availableWidth = constraints.maxWidth;
        final isCompact = availableWidth < 360;
        final buttonSpacing = isCompact ? 8.0 : 16.0;

        return Column(
          children: [
            // Primary Google sign-in button
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Semantics(
                button: true,
                label: context.l10n.signInWithGoogle,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _handleSignIn('google'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isDark
                              ? [
                                  Colors.deepPurple.shade700,
                                  Colors.deepPurple.shade900,
                                ]
                              : [
                                  colorScheme.primary,
                                  colorScheme.primary.withValues(alpha: 0.85),
                                ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.deepPurple.withValues(alpha: 0.4),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Icon(
                              CustomIcons.google,
                              size: 24,
                              color: Colors.white,
                              semanticLabel: 'Google',
                            ),
                          ),
                          const SizedBox(width: 16),
                          Flexible(
                            child: Text(
                              context.l10n.continueWithGoogle,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ), // ConstrainedBox (Google)
            if (supportsAppleAuth(
              isWeb: kIsWeb,
              platform: defaultTargetPlatform,
            )) ...[
              const SizedBox(height: 12),
              // Apple Sign-In button (equally prominent per App Store guideline 4.8)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Semantics(
                  button: true,
                  label: context.l10n.signInWithApple,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _handleSignIn('apple'),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white : Colors.black,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Transform.scale(
                                key: const ValueKey(
                                  'appleSignInIconOpticalScale',
                                ),
                                scale: 1.4,
                                child: Icon(
                                  Icons.apple,
                                  size: 24,
                                  color: isDark ? Colors.black : Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Flexible(
                              child: Text(
                                context.l10n.continueWithApple,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.black : Colors.white,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ), // ConstrainedBox (Apple)
            ],
            const SizedBox(height: 20),
            // Divider with "or"
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 1,
                    color: colorScheme.onSurface.withValues(alpha: 0.15),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    context.l10n.or,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 1,
                    color: colorScheme.onSurface.withValues(alpha: 0.15),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Secondary sign-in buttons row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSocialButton(
                  icon: CustomIcons.facebook,
                  color: const Color(0xFF1877F2),
                  tooltip: context.l10n.signInWithFacebook,
                  onTap: () => _handleSignIn('facebook'),
                  compact: isCompact,
                ),
                SizedBox(width: buttonSpacing),
                _buildSocialButton(
                  icon: CustomIcons.github,
                  color: isDark ? Colors.white : Colors.black87,
                  tooltip: context.l10n.signInWithGithub,
                  onTap: () => _handleSignIn('github'),
                  compact: isCompact,
                ),
                SizedBox(width: buttonSpacing),
                // TODO: Re-enable Twitter login when API issues are resolved
                // _buildSocialButton(
                //   icon: CustomIcons.xTwitter,
                //   color: isDark ? Colors.white : Colors.black87,
                //   tooltip: 'Sign in with X (Twitter)',
                //   onTap: () => _handleSignIn('twitter'),
                //   compact: isCompact,
                // ),
                // SizedBox(width: buttonSpacing),
                _buildSocialButton(
                  icon: Icons.email_outlined,
                  color: colorScheme.primary,
                  tooltip: context.l10n.signInWithEmail,
                  onTap: _navigateToEmailLogin,
                  compact: isCompact,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              context.l10n.chooseSignInMethod,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSocialButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
    bool compact = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = compact ? 10.0 : 16.0;
    final iconSize = compact ? 22.0 : 28.0;
    final borderRadius = compact ? 12.0 : 16.0;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(borderRadius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.grey.shade200,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: iconSize, color: color),
          ),
        ),
      ),
    );
  }

  void _navigateToEmailLogin() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const EmailLoginPage()));
  }

  Widget _buildLogo({required double size}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: isDark ? 0.4 : 0.25),
            blurRadius: 30,
            spreadRadius: 5,
          ),
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: isDark ? 0.2 : 0.1),
            blurRadius: 60,
            spreadRadius: 20,
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/better_keep-512.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          semanticLabel: 'Better Keep app logo',
        ),
      ),
    );
  }
}
