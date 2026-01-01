import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Platform-aware image compression utility.
///
/// Uses `flutter_image_compress` on supported platforms (iOS, Android, macOS, Web)
/// and falls back to Dart's image codec on unsupported platforms (Windows, Linux).
class ImageCompressor {
  /// Returns true if the native flutter_image_compress is supported on this platform.
  static bool get _isNativeSupported {
    if (kIsWeb) return true;
    return Platform.isIOS || Platform.isAndroid || Platform.isMacOS;
  }

  /// Compresses an image to the specified quality and dimensions.
  ///
  /// [imageBytes] - The original image bytes
  /// [quality] - JPEG quality (1-100)
  /// [minWidth] - Target width (image will be resized proportionally)
  /// [minHeight] - Target height (image will be resized proportionally)
  /// [format] - Output format (only affects native implementation)
  static Future<Uint8List> compressWithList(
    Uint8List imageBytes, {
    int quality = 90,
    int minWidth = 1920,
    int minHeight = 1920,
    CompressFormat format = CompressFormat.jpeg,
  }) async {
    if (_isNativeSupported) {
      return await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
        format: format,
      );
    } else {
      return await _compressWithDartCodec(
        imageBytes,
        quality: quality,
        targetWidth: minWidth,
        targetHeight: minHeight,
      );
    }
  }

  /// Fallback compression using Dart's image codec (works on all platforms).
  static Future<Uint8List> _compressWithDartCodec(
    Uint8List imageBytes, {
    required int quality,
    required int targetWidth,
    required int targetHeight,
  }) async {
    try {
      // Decode the image
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // Calculate new dimensions while maintaining aspect ratio
      int newWidth = image.width;
      int newHeight = image.height;

      if (image.width > targetWidth || image.height > targetHeight) {
        final aspectRatio = image.width / image.height;
        if (aspectRatio > 1) {
          // Landscape
          newWidth = targetWidth;
          newHeight = (targetWidth / aspectRatio).round();
        } else {
          // Portrait or square
          newHeight = targetHeight;
          newWidth = (targetHeight * aspectRatio).round();
        }
      }

      // If resizing is needed, create a resized image
      ui.Image finalImage;
      if (newWidth != image.width || newHeight != image.height) {
        // Use picture recorder to resize
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          ui.Rect.fromLTWH(0, 0, newWidth.toDouble(), newHeight.toDouble()),
          paint,
        );
        final picture = recorder.endRecording();
        finalImage = await picture.toImage(newWidth, newHeight);
        picture.dispose();
      } else {
        finalImage = image;
      }

      // Encode as PNG (Dart's built-in codec doesn't support JPEG quality settings,
      // but PNG provides reasonable compression for most use cases)
      final byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (finalImage != image) {
        finalImage.dispose();
      }
      image.dispose();
      codec.dispose();

      if (byteData == null) {
        return imageBytes; // Return original if encoding fails
      }

      return byteData.buffer.asUint8List();
    } catch (e) {
      // If anything fails, return the original bytes
      return imageBytes;
    }
  }
}
