import 'dart:math' as math;

import 'package:better_keep/services/auth_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:flutter/material.dart';

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
      _contentController.forward();
      _pulseController.repeat(reverse: true);
    });
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

  Future<void> _handleSignIn() async {
    setState(() {
      _isLoading = true;
      _statusMessage = "Starting sign in...";
    });
    try {
      final credential = await AuthService.signInWithGoogle(
        onStatusChange: (status) {
          if (mounted) {
            setState(() {
              _statusMessage = status;
            });
          }
        },
      );
      if (credential == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("Sign in cancelled")));
        }
      }
    } catch (e) {
      // Extract user-friendly message from exception
      String errorMessage = 'Sign in failed';
      final errorStr = e.toString();

      if (errorStr.contains('network')) {
        errorMessage = 'Network error. Please check your internet connection.';
      } else if (errorStr.contains('cancelled') ||
          errorStr.contains('canceled')) {
        errorMessage = 'Sign in was cancelled.';
      } else if (errorStr.contains('permission-denied')) {
        errorMessage = 'Permission denied. Please contact support.';
      } else if (errorStr.contains('unavailable')) {
        errorMessage =
            'Service temporarily unavailable. Please try again later.';
      } else if (e is Exception) {
        // Extract message from Exception
        final msg = errorStr.replaceFirst('Exception: ', '');
        if (msg.length < 100) {
          errorMessage = msg;
        }
      }

      // Use global key because this widget might be unmounted if auth state changed
      AppState.scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
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
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: _isLoading
                        ? _buildLoadingState()
                        : _buildLoginContent(),
                  ),
                ),
              ),
              if (_version.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
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
                  "Better Keep",
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Your notes, secured and synced",
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

        // Animated Sign In Button
        SlideTransition(
          position: _buttonSlide,
          child: FadeTransition(
            opacity: _buttonOpacity,
            child: _buildGoogleSignInButton(),
          ),
        ),

        const SizedBox(height: 48),

        // Features list with staggered animation
        SlideTransition(
          position: _buttonSlide,
          child: FadeTransition(
            opacity: _buttonOpacity,
            child: _buildFeaturesList(),
          ),
        ),
      ],
    );
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

  Widget _buildGoogleSignInButton() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      button: true,
      label: 'Sign in with Google',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _handleSignIn,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [Colors.deepPurple.shade700, Colors.deepPurple.shade900]
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CustomIcons.google1,
                  size: 24,
                  color: Colors.white,
                  semanticLabel: 'Google',
                ),
                const SizedBox(width: 16),
                const Text(
                  "Continue with Google",
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeaturesList() {
    final colorScheme = Theme.of(context).colorScheme;

    final features = [
      (Icons.lock_outline, "End-to-end encrypted"),
      (Icons.sync_outlined, "Sync across devices"),
      (Icons.palette_outlined, "Rich note formatting"),
    ];

    return Column(
      children: [
        ...features.map((feature) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  feature.$1,
                  size: 18,
                  color: colorScheme.primary.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 12),
                Text(
                  feature.$2,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
