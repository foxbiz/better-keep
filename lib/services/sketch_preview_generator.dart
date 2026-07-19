import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/utils/image_compressor.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

/// Generates local preview assets from the synced sketch source data.
class SketchPreviewGenerator {
  SketchPreviewGenerator._();

  static const int _maxPreviewBytes = 500 * 1024;

  /// Regenerates a sketch preview without changing its remote representation.
  ///
  /// Image-based sketches use the decoded background's intrinsic dimensions as
  /// the source coordinate space. Set [loadBackground] to false only when the
  /// remote background is permanently unavailable and a best-effort fallback
  /// is preferable to dropping the user's strokes.
  static Future<bool> generatePreview(
    SketchData sketch, {
    ui.Image? backgroundImage,
    bool loadBackground = true,
    bool reuseExistingPreview = true,
    bool updateCache = true,
    Future<Uint8List> Function(String path)? readBytes,
    Future<void> Function(String path, Uint8List bytes)? writeBytes,
  }) async {
    if (sketch.strokes.isEmpty) {
      AppLogger.log('Cannot generate preview: no strokes');
      return false;
    }

    ui.Image? ownedBackground;
    try {
      final isImageBased =
          sketch.backgroundImage != null && sketch.backgroundImage!.isNotEmpty;

      if (backgroundImage == null && isImageBased && loadBackground) {
        final backgroundPath = sketch.backgroundImage!;
        if (backgroundPath.startsWith('http')) {
          throw StateError('Sketch background has not been downloaded');
        }
        final bytes = await (readBytes ?? readEncryptedBytes)(backgroundPath);
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          ownedBackground = frame.image;
          backgroundImage = ownedBackground;
        } finally {
          codec.dispose();
        }
      }

      final Size sourceSize;
      if (backgroundImage != null) {
        sourceSize = Size(
          backgroundImage.width.toDouble(),
          backgroundImage.height.toDouble(),
        );
        sketch.aspectRatio = sourceSize.width / sourceSize.height;
      } else if (isImageBased &&
          sketch.aspectRatio.isFinite &&
          sketch.aspectRatio > 0) {
        sourceSize = Size(
          kSketchA4Size.width,
          kSketchA4Size.width / sketch.aspectRatio,
        );
      } else {
        sourceSize = kSketchA4Size;
        sketch.aspectRatio = sourceSize.width / sourceSize.height;
      }

      final pngBytes = await SketchRenderer.renderPng(
        strokes: sketch.strokes,
        sourceCanvasSize: sourceSize,
        backgroundColor: isImageBased && backgroundImage == null
            ? Colors.white
            : sketch.backgroundColor,
        pagePattern: sketch.pagePattern,
        isImageBased: isImageBased && backgroundImage != null,
        backgroundImage: backgroundImage,
      );
      final compressedBytes = await _compressPreview(pngBytes);
      final blurredThumbnail = await ThumbnailGenerator.generateFromBytes(
        compressedBytes,
      );

      final fs = await fileSystem();
      final existingPath = sketch.previewImage;
      final previewPath =
          reuseExistingPreview &&
              existingPath != null &&
              existingPath.isNotEmpty &&
              !existingPath.startsWith('http')
          ? existingPath
          : path.join(await fs.documentDir, '${Uuid().v4()}.jpg');

      await (writeBytes ?? writeEncryptedBytes)(previewPath, compressedBytes);
      if (updateCache) {
        UniversalImageCache.instance.put(
          previewPath,
          previewPath,
          compressedBytes,
        );
      }

      sketch.previewImage = previewPath;
      sketch.blurredThumbnail = blurredThumbnail;
      AppLogger.log('Generated sketch preview: $previewPath');
      return true;
    } catch (e) {
      AppLogger.error('Error generating sketch preview', e);
      return false;
    } finally {
      ownedBackground?.dispose();
    }
  }

  static Future<Uint8List> _compressPreview(Uint8List pngBytes) async {
    var compressed = await ImageCompressor.compressWithList(
      pngBytes,
      quality: 85,
      format: CompressFormat.jpeg,
    );
    if (compressed.length <= _maxPreviewBytes) return compressed;

    compressed = await ImageCompressor.compressWithList(
      pngBytes,
      quality: 70,
      format: CompressFormat.jpeg,
    );
    if (compressed.length <= _maxPreviewBytes) return compressed;

    return ImageCompressor.compressWithList(
      pngBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
      format: CompressFormat.jpeg,
    );
  }
}
