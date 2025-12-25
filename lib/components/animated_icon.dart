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

  @override
  void initState() {
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..forward();

    if (widget.repeat) {
      _controller.addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _controller.reverse();
        } else if (status == AnimationStatus.dismissed) {
          _controller.forward();
        }
      });
    }

    _animation = Tween<double>(begin: 0.0, end: 1.0)
        .chain(CurveTween(curve: widget.curve ?? Curves.linear))
        .animate(_controller);
    super.initState();
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus);

    _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
    _controller.forward();
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
      if (_controller.status == AnimationStatus.dismissed ||
          _controller.status == AnimationStatus.completed) {
        _controller.forward(from: 0.0);
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
    if (!widget.repeat) {
      return;
    }

    if (status == AnimationStatus.completed) {
      _controller.reverse();
    } else if (status == AnimationStatus.dismissed) {
      _controller.forward();
    }
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
