import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/components/page_pattern_painter.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

/// The coordinate space used by ordinary (non-image) sketch pages.
const Size kSketchA4Size = Size(794, 1123);

/// Renders sketches consistently for the editor, saved previews, and sync.
class SketchRenderer {
  SketchRenderer._();

  static const double defaultPreviewMaxDimension = 1200;
  static const int maxRasterDimension = 8192;

  static bool _isValidSize(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  static Size boundedSize(
    Size source, {
    double maxDimension = defaultPreviewMaxDimension,
  }) {
    if (!_isValidSize(source)) return kSketchA4Size;
    final longest = source.longestSide;
    if (longest <= maxDimension) return source;
    final scale = maxDimension / longest;
    return Size(source.width * scale, source.height * scale);
  }

  /// Converts a requested logical output size to safe integer raster pixels.
  /// Oversized canvases use one uniform scale so their aspect ratio and stroke
  /// coordinate mapping cannot be distorted by independent axis clamping.
  static Size boundedPixelSize(
    Size requested, {
    int maxDimension = maxRasterDimension,
  }) {
    final safeRequested = _isValidSize(requested) ? requested : kSketchA4Size;
    final safeMaxDimension = maxDimension > 0
        ? maxDimension
        : maxRasterDimension;
    final scale = safeRequested.longestSide > safeMaxDimension
        ? safeMaxDimension / safeRequested.longestSide
        : 1.0;
    final scaledWidth = (safeRequested.width * scale).round();
    final scaledHeight = (safeRequested.height * scale).round();
    return Size(
      (scaledWidth < 1 ? 1 : scaledWidth).toDouble(),
      (scaledHeight < 1 ? 1 : scaledHeight).toDouble(),
    );
  }

  static Future<Uint8List> renderPng({
    required List<SketchStroke> strokes,
    required Size sourceCanvasSize,
    required Color backgroundColor,
    required PagePattern pagePattern,
    required bool isImageBased,
    ui.Image? backgroundImage,
    Size? outputSize,
  }) async {
    final safeSource = _isValidSize(sourceCanvasSize)
        ? sourceCanvasSize
        : kSketchA4Size;
    final requestedOutput = outputSize ?? boundedSize(safeSource);
    final actualOutput = boundedPixelSize(requestedOutput);
    final pixelWidth = actualOutput.width.toInt();
    final pixelHeight = actualOutput.height.toInt();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(
      actualOutput.width / safeSource.width,
      actualOutput.height / safeSource.height,
    );

    if (isImageBased) {
      canvas.drawColor(Colors.transparent, BlendMode.clear);
    } else {
      canvas.drawColor(backgroundColor, BlendMode.src);
    }

    if (backgroundImage != null) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & safeSource,
        image: backgroundImage,
        fit: isImageBased ? BoxFit.fill : BoxFit.contain,
      );
    }

    if (!isImageBased && pagePattern != PagePattern.blank) {
      final patternPainter = PagePatternPainter(
        pattern: pagePattern,
        lineColor: isDark(backgroundColor)
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.18),
      );
      patternPainter.paint(canvas, safeSource);
    }

    SketchPainter(strokes: strokes).paint(canvas, safeSource);

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(pixelWidth, pixelHeight);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Failed to encode sketch image');
        return bytes.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}
