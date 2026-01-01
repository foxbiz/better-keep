import 'package:better_keep/models/sketch.dart';
import 'package:flutter/material.dart';

/// A CustomPainter that draws page patterns (lines, grids, dots) for sketches.
/// These patterns are rendered dynamically and scale perfectly at any zoom level.
/// The pattern is NOT saved as part of the sketch image - only the pagePattern
/// field is saved as metadata.
class PagePatternPainter extends CustomPainter {
  final PagePattern pattern;
  final Color lineColor;
  final double lineSpacing;
  final double strokeWidth;

  PagePatternPainter({
    required this.pattern,
    Color? lineColor,
    this.lineSpacing = 24.0,
    this.strokeWidth = 0.5,
  }) : lineColor = lineColor ?? Colors.grey.withValues(alpha: 0.3);

  @override
  void paint(Canvas canvas, Size size) {
    switch (pattern) {
      case PagePattern.blank:
        return;
      case PagePattern.singleLine:
        _drawSingleLines(canvas, size);
      case PagePattern.doubleLine:
        _drawDoubleLines(canvas, size);
      case PagePattern.grid:
        _drawGrid(canvas, size);
      case PagePattern.dotGrid:
        _drawDotGrid(canvas, size);
    }
  }

  void _drawSingleLines(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = strokeWidth;

    // Start from top with some margin
    for (double y = lineSpacing; y < size.height; y += lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _drawDoubleLines(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = strokeWidth;

    // Secondary line is even more subtle
    final thinPaint = Paint()
      ..color = lineColor.withValues(alpha: lineColor.a * 0.5)
      ..strokeWidth = strokeWidth * 0.5;

    // Double line pattern: main line followed by secondary guide line
    double y = lineSpacing;
    bool isThick = true;
    final thinSpacing = lineSpacing * 0.4;

    while (y < size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        isThick ? paint : thinPaint,
      );
      y += isThick ? thinSpacing : lineSpacing - thinSpacing;
      isThick = !isThick;
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = strokeWidth;

    // Vertical lines
    for (double x = 0; x <= size.width; x += lineSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    // Horizontal lines
    for (double y = 0; y <= size.height; y += lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _drawDotGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.fill;

    // Make dots larger for better visibility
    final dotRadius = strokeWidth * 2.5;

    for (double x = lineSpacing; x < size.width; x += lineSpacing) {
      for (double y = lineSpacing; y < size.height; y += lineSpacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PagePatternPainter oldDelegate) {
    return pattern != oldDelegate.pattern ||
        lineColor != oldDelegate.lineColor ||
        lineSpacing != oldDelegate.lineSpacing ||
        strokeWidth != oldDelegate.strokeWidth;
  }
}

/// A widget that displays a page pattern background.
/// Wraps CustomPaint with a RepaintBoundary for performance.
class PagePatternBackground extends StatelessWidget {
  final PagePattern pattern;
  final Color? lineColor;
  final double lineSpacing;
  final double strokeWidth;
  final Size size;

  const PagePatternBackground({
    super.key,
    required this.pattern,
    required this.size,
    this.lineColor,
    this.lineSpacing = 24.0,
    this.strokeWidth = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    if (pattern == PagePattern.blank) {
      return const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: CustomPaint(
        size: size,
        painter: PagePatternPainter(
          pattern: pattern,
          lineColor: lineColor,
          lineSpacing: lineSpacing,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}
