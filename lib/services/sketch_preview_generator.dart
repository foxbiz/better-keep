import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:better_keep/utils/image_compressor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as path;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:uuid/uuid.dart';

/// Service to generate sketch preview images from stroke data.
/// Used after syncing to regenerate previews on device.
class SketchPreviewGenerator {
  SketchPreviewGenerator._();

  /// Maximum preview image size in bytes (500KB)
  static const int _maxPreviewBytes = 500 * 1024;

  /// Generates a preview image and thumbnail for a sketch from its strokes.
  /// Updates the sketch's previewImage, blurredThumbnail, and saves the files.
  /// Returns true if successful.
  static Future<bool> generatePreview(SketchData sketch) async {
    if (sketch.strokes.isEmpty) {
      AppLogger.log('Cannot generate preview: no strokes');
      return false;
    }

    try {
      // Calculate canvas size from aspect ratio
      const double baseWidth = 800.0;
      final double height = baseWidth / sketch.aspectRatio;
      final Size canvasSize = Size(baseWidth, height);

      // Create a picture recorder
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // Draw background color
      canvas.drawColor(sketch.backgroundColor, BlendMode.src);

      // Draw strokes
      _paintStrokes(canvas, canvasSize, sketch.strokes);

      // Convert to image
      final picture = recorder.endRecording();
      final img = await picture.toImage(
        canvasSize.width.toInt(),
        canvasSize.height.toInt(),
      );
      final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes == null) {
        throw 'Failed to encode sketch image';
      }

      // Compress the preview image
      final compressedBytes = await _compressPreview(
        pngBytes.buffer.asUint8List(),
      );

      // Save preview image - create a new local path
      // Only reuse existing path if it's a valid local file path (not HTTP URL)
      final fs = await fileSystem();
      final docDir = await fs.documentDir;
      final existingPath = sketch.previewImage;
      final String previewPath;
      if (existingPath != null &&
          existingPath.isNotEmpty &&
          !existingPath.startsWith('http')) {
        previewPath = existingPath;
      } else {
        previewPath = path.join(docDir, '${Uuid().v4()}.jpg');
      }

      await writeEncryptedBytes(previewPath, compressedBytes);
      sketch.previewImage = previewPath;

      // Generate thumbnail
      final thumbnail = await ThumbnailGenerator.generateFromBytes(
        compressedBytes,
      );
      sketch.blurredThumbnail = thumbnail;

      AppLogger.log('Generated sketch preview: $previewPath');
      return true;
    } catch (e) {
      AppLogger.error('Error generating sketch preview', e);
      return false;
    }
  }

  /// Paint strokes onto canvas (simplified version of SketchPainter)
  static void _paintStrokes(
    Canvas canvas,
    Size size,
    List<SketchStroke> strokes,
  ) {
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());

    for (final stroke in strokes) {
      final points = SketchStroke.parsePoints(stroke.points);
      if (points.isEmpty) continue;

      // Use tool-specific stroke options with high smoothing for buttery smooth strokes
      final StrokeOptions options;
      switch (stroke.tool) {
        case SketchTool.pencil:
          options = StrokeOptions(
            size: stroke.size * 0.9,
            thinning: 0.55,
            smoothing: 0.7,
            streamline: 0.6,
            isComplete: true,
          );
          break;
        case SketchTool.brush:
          options = StrokeOptions(
            size: stroke.size,
            thinning: 0.65,
            smoothing: 0.8,
            streamline: 0.75,
            start: StrokeEndOptions.start(
              taperEnabled: true,
              customTaper: stroke.size * 2.5,
            ),
            end: StrokeEndOptions.end(
              taperEnabled: true,
              customTaper: stroke.size * 2.5,
            ),
            isComplete: true,
          );
          break;
        case SketchTool.highlighter:
          // Highlighter uses stroke-based rendering, skip outline approach
          _paintHighlighterPreview(canvas, stroke, points);
          continue;
        case SketchTool.eraser:
          options = StrokeOptions(
            size: stroke.size,
            thinning: 0.4,
            smoothing: 0.75,
            streamline: 0.7,
            isComplete: true,
          );
          break;
        default:
          options = StrokeOptions(
            size: stroke.size,
            thinning: 0.4,
            smoothing: 0.85,
            streamline: 0.75,
            isComplete: true,
          );
      }

      final outlinePoints = getStroke(points, options: options);

      if (outlinePoints.isEmpty) continue;

      // Use quadratic Bezier curves for silky smooth preview strokes
      final strokePath = Path();
      strokePath.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);

      for (int i = 1; i < outlinePoints.length - 1; i++) {
        final p0 = outlinePoints[i];
        final p1 = outlinePoints[i + 1];
        final midX = (p0.dx + p1.dx) / 2;
        final midY = (p0.dy + p1.dy) / 2;
        strokePath.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
      }

      if (outlinePoints.length > 1) {
        final last = outlinePoints.last;
        strokePath.lineTo(last.dx, last.dy);
      }
      strokePath.close();

      final paint = Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;

      if (stroke.tool == SketchTool.eraser) {
        paint.color = Colors.transparent;
        paint.blendMode = BlendMode.clear;
      } else if (stroke.tool == SketchTool.pencil) {
        paint.color = stroke.color.withValues(alpha: 0.75);
        paint.blendMode = BlendMode.srcOver;
      } else {
        paint.color = stroke.color;
        paint.blendMode = BlendMode.srcOver;
      }

      canvas.drawPath(strokePath, paint);
    }

    canvas.restore();
  }

  /// Paint highlighter stroke for preview
  static void _paintHighlighterPreview(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    if (points.length < 2) return;

    final highlighterSize = stroke.size * 2.5;
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighterSize
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.multiply;

    final path = Path();
    path.moveTo(points[0].x, points[0].y);
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

  /// Compress preview image to be under 500KB
  static Future<Uint8List> _compressPreview(Uint8List pngBytes) async {
    // Try quality 85 first
    var compressed = await ImageCompressor.compressWithList(
      pngBytes,
      quality: 85,
      format: CompressFormat.jpeg,
    );

    if (compressed.length <= _maxPreviewBytes) {
      return compressed;
    }

    // Try quality 70
    compressed = await ImageCompressor.compressWithList(
      pngBytes,
      quality: 70,
      format: CompressFormat.jpeg,
    );

    if (compressed.length <= _maxPreviewBytes) {
      return compressed;
    }

    // Final try: quality 50, smaller size
    return ImageCompressor.compressWithList(
      pngBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
      format: CompressFormat.jpeg,
    );
  }
}
