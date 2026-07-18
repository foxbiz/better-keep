import 'package:flutter/material.dart';

class AnimatedMenuIcon extends StatefulWidget {
  final AnimatedIconData icon;
  final Duration duration;
  final String? label;
  final Curve? curve;
  final bool repeat;
  const AnimatedMenuIcon({
    super.key,
    this.label,
    this.curve,
    required this.icon,
    this.repeat = false,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<AnimatedMenuIcon> createState() => _AnimatedMenuIconState();
}

class _AnimatedMenuIconState extends State<AnimatedMenuIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _animation = Tween<double>(begin: 0.0, end: 1.0)
        .chain(CurveTween(curve: widget.curve ?? Curves.linear))
        .animate(_controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;

    _disableAnimations = disableAnimations;
    _applyMotionPreference();
  }

  @override
  void didUpdateWidget(covariant AnimatedMenuIcon oldWidget) {
    super.didUpdateWidget(oldWidget);

    final durationChanged = widget.duration != oldWidget.duration;
    if (durationChanged) {
      _controller.duration = widget.duration;
    }
    if (widget.curve != oldWidget.curve) {
      _animation = Tween<double>(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: widget.curve ?? Curves.linear))
          .animate(_controller);
    }

    final iconChanged = widget.icon != oldWidget.icon;
    final repeatChanged = widget.repeat != oldWidget.repeat;
    if (_disableAnimations == true) {
      _showFinalFrame();
    } else if (repeatChanged) {
      if (widget.repeat) {
        _controller.repeat(reverse: true);
      } else {
        _showFinalFrame();
      }
    } else if (iconChanged) {
      if (widget.repeat) {
        _controller.repeat(reverse: true);
      } else {
        _controller.forward(from: 0.0);
      }
    } else if (widget.repeat && durationChanged) {
      _controller.repeat(reverse: true);
    }
  }

  void _applyMotionPreference() {
    if (_disableAnimations == true) {
      _showFinalFrame();
    } else if (widget.repeat) {
      _controller.repeat(reverse: true);
    } else if (_controller.value == _controller.lowerBound) {
      _controller.forward();
    }
  }

  void _showFinalFrame() {
    _controller.stop();
    _controller.value = _controller.upperBound;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedIcon(
      progress: _animation,
      icon: widget.icon,
      semanticLabel: widget.label,
    );
  }
}

class IconTransitionAnimation extends StatefulWidget {
  final IconData fromIcon;
  final IconData toIcon;
  final Duration duration;
  final Curve curve;
  final bool repeat;
  final double? size;
  final Color? color;

  const IconTransitionAnimation({
    super.key,
    required this.fromIcon,
    required this.toIcon,
    this.duration = const Duration(milliseconds: 400),
    this.curve = Curves.easeInOut,
    this.repeat = false,
    this.size,
    this.color,
  });

  @override
  State<IconTransitionAnimation> createState() =>
      _IconTransitionAnimationState();
}

class _IconTransitionAnimationState extends State<IconTransitionAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  bool? _disableAnimations;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus);

    _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;

    _disableAnimations = disableAnimations;
    _applyMotionPreference();
  }

  @override
  void didUpdateWidget(covariant IconTransitionAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }

    if (widget.curve != oldWidget.curve) {
      _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
    }

    if (widget.fromIcon != oldWidget.fromIcon ||
        widget.toIcon != oldWidget.toIcon) {
      if (_disableAnimations == true) {
        _showFinalFrame();
      } else {
        _controller.forward(from: 0.0);
      }
    } else if (widget.repeat != oldWidget.repeat) {
      if (widget.repeat) {
        _applyMotionPreference();
      } else {
        _showFinalFrame();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (!widget.repeat || _disableAnimations == true) {
      return;
    }

    if (status == AnimationStatus.completed) {
      _controller.reverse();
    } else if (status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  void _applyMotionPreference() {
    if (_disableAnimations == true) {
      _showFinalFrame();
    } else if (widget.repeat) {
      _controller.forward(from: 0.0);
    } else if (_controller.value == _controller.lowerBound) {
      _controller.forward();
    }
  }

  void _showFinalFrame() {
    _controller.stop();
    _controller.value = _controller.upperBound;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final progress = _animation.value;
        final firstOpacity = 1 - progress;
        final secondOpacity = progress;
        final firstScale = 1 - 0.3 * progress;
        final secondScale = 0.7 + 0.3 * progress;

        return Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: firstScale,
              child: Opacity(
                opacity: firstOpacity,
                child: Icon(
                  widget.fromIcon,
                  size: widget.size,
                  color: widget.color,
                ),
              ),
            ),
            Transform.scale(
              scale: secondScale,
              child: Opacity(
                opacity: secondOpacity,
                child: Icon(
                  widget.toIcon,
                  size: widget.size,
                  color: widget.color,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
