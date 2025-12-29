import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Utility for generating tiny blurred thumbnails for locked note previews.
///
/// Thumbnails are:
/// - Very small (16-24px width) to ensure no detail is visible
/// - Highly compressed JPEG (quality 15-20%)
/// - Under 1KB when base64 encoded
/// - Safe to display even when note is locked (too low-res to reveal content)
class ThumbnailGenerator {
  /// Maximum size for thumbnail in bytes (before base64 encoding).
  /// Base64 adds ~33% overhead, so ~750 bytes raw = ~1KB encoded.
  static const int _maxThumbnailBytes = 750;

  /// Target width for thumbnails (very small for privacy).
  static const int _thumbnailWidth = 24;

  /// Generates a tiny, blurred thumbnail from image bytes.
  ///
  /// Returns a base64-encoded JPEG string under 1KB, or null if generation fails.
  static Future<String?> generateFromBytes(Uint8List imageBytes) async {
    if (imageBytes.isEmpty) return null;

    try {
      // Start with very aggressive compression
      int quality = 20;
      int width = _thumbnailWidth;

      Uint8List thumbnail = await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: width,
        minHeight: width,
        format: CompressFormat.jpeg,
      );

      if (thumbnail.isEmpty) return null;

      // If still too large, reduce quality further
      while (thumbnail.length > _maxThumbnailBytes && quality > 5) {
        quality -= 5;
        final result = await FlutterImageCompress.compressWithList(
          imageBytes,
          quality: quality,
          minWidth: width,
          minHeight: width,
          format: CompressFormat.jpeg,
        );
        if (result.isEmpty) break;
        thumbnail = result;
      }

      // If still too large, reduce dimensions
      while (thumbnail.length > _maxThumbnailBytes && width > 8) {
        width = (width * 0.7).toInt();
        final result = await FlutterImageCompress.compressWithList(
          imageBytes,
          quality: quality,
          minWidth: width,
          minHeight: width,
          format: CompressFormat.jpeg,
        );
        if (result.isEmpty) break;
        thumbnail = result;
      }

      if (thumbnail.isEmpty) return null;

      // Convert to base64
      return base64Encode(thumbnail);
    } catch (e) {
      // Thumbnail generation is non-critical, fail silently
      return null;
    }
  }

  /// Decodes a base64 thumbnail string to bytes for display.
  static Uint8List? decodeFromBase64(String? base64Thumbnail) {
    if (base64Thumbnail == null || base64Thumbnail.isEmpty) return null;

    try {
      return base64Decode(base64Thumbnail);
    } catch (e) {
      return null;
    }
  }
}
