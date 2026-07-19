import 'package:better_keep/models/sketch.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

typedef SketchStrokeOutlineCacheKey = (String, double, SketchTool);

/// Bounded outline cache shared by sketch painters.
///
/// The full structural key is retained so Dart's map equality check can
/// disambiguate integer hash collisions.
@visibleForTesting
final class SketchStrokeOutlineCache {
  final int maxEntries;
  final Map<SketchStrokeOutlineCacheKey, List<Offset>> _entries = {};

  SketchStrokeOutlineCache({this.maxEntries = 500})
    : assert(maxEntries > 0, 'maxEntries must be positive');

  int get length => _entries.length;

  List<Offset> getOrCreate(
    SketchStroke stroke,
    List<Offset> Function() create,
  ) {
    final key = (stroke.points, stroke.size, stroke.tool);
    final cached = _entries[key];
    if (cached != null) return cached;

    final outline = create();
    if (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = outline;
    return outline;
  }
}

class SketchPainter extends CustomPainter {
  final List<SketchStroke> strokes;

  static final SketchStrokeOutlineCache _strokeCache =
      SketchStrokeOutlineCache();

  SketchPainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
    canvas.restore();
  }

  void _paintStroke(Canvas canvas, SketchStroke stroke) {
    final points = SketchStroke.parsePoints(stroke.points);
    if (points.isEmpty) return;

    switch (stroke.tool) {
      case SketchTool.eraser:
        _paintEraserStroke(canvas, stroke, points);
        break;
      case SketchTool.pencil:
        _paintPencilStroke(canvas, stroke, points);
        break;
      case SketchTool.brush:
        _paintBrushStroke(canvas, stroke, points);
        break;
      case SketchTool.highlighter:
        _paintHighlighterStroke(canvas, stroke, points);
        break;
      case SketchTool.pen:
        _paintPenStroke(canvas, stroke, points);
        break;
    }
  }

  /// Standard pen stroke - solid, consistent width with buttery smooth Bezier curves
  void _paintPenStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final outlinePoints = _strokeCache.getOrCreate(
      stroke,
      () => getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.4,
          smoothing: 0.85, // High smoothing for buttery smooth strokes
          streamline: 0.75, // Higher streamline for natural flow
          isComplete: true,
        ),
      ),
    );

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Pencil stroke - graphite texture with slight opacity and noise
  void _paintPencilStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final outlinePoints = _strokeCache.getOrCreate(
      stroke,
      () => getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size * 0.9, // Slightly thinner than pen
          thinning: 0.55,
          smoothing: 0.7, // Higher smoothing for smoother pencil strokes
          streamline: 0.6, // Better streamline for natural pencil feel
          isComplete: true,
        ),
      ),
    );

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    // Main pencil stroke with reduced opacity for graphite look
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.75)
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Brush stroke - variable width based on velocity, tapered ends with buttery smooth Bezier curves
  void _paintBrushStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final outlinePoints = _strokeCache.getOrCreate(
      stroke,
      () => getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.65, // Refined thinning for natural brush effect
          smoothing: 0.8, // High smoothing for buttery smooth brush strokes
          streamline: 0.75, // Better streamline for fluid brush movement
          start: StrokeEndOptions.start(
            taperEnabled: true,
            customTaper: stroke.size * 2.5,
          ),
          end: StrokeEndOptions.end(
            taperEnabled: true,
            customTaper: stroke.size * 2.5,
          ),
          isComplete: true,
        ),
      ),
    );

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth brush strokes
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Highlighter stroke - transparent, wide stroke like a real highlighter
  void _paintHighlighterStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    if (points.length < 2) return;

    // Highlighter uses a wider, flat stroke
    final highlighterSize = stroke.size * 2.5;

    // Draw the main highlight path with transparency
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighterSize
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.multiply;

    final path = Path();
    path.moveTo(points[0].x, points[0].y);

    // Use quadratic bezier for smoother curves
    for (int i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final midX = (p0.x + p1.x) / 2;
      final midY = (p0.y + p1.y) / 2;
      path.quadraticBezierTo(p0.x, p0.y, midX, midY);
    }
    path.lineTo(points.last.x, points.last.y);

    canvas.drawPath(path, paint);
  }

  /// Eraser stroke - clears underlying content with smooth Bezier curves
  void _paintEraserStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final outlinePoints = _strokeCache.getOrCreate(
      stroke,
      () => getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.4,
          smoothing: 0.75, // Smooth erasing for clean edges
          streamline: 0.7,
          isComplete: true,
        ),
      ),
    );

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for smooth eraser edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.clear
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SketchPainter oldDelegate) {
    // Only repaint if strokes have changed
    if (strokes.length != oldDelegate.strokes.length) return true;
    for (int i = 0; i < strokes.length; i++) {
      if (strokes[i].points != oldDelegate.strokes[i].points ||
          strokes[i].color != oldDelegate.strokes[i].color ||
          strokes[i].size != oldDelegate.strokes[i].size ||
          strokes[i].tool != oldDelegate.strokes[i].tool) {
        return true;
      }
    }
    return false;
  }
}
