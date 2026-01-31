import 'dart:convert';

import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/widgets.dart';

/// Global singleton cache for base64 image data decoded as MemoryImage.
/// Prevents redundant base64 decoding across editor instances.
class QuillImageCache {
  QuillImageCache._();
  static final QuillImageCache instance = QuillImageCache._();

  final Map<String, MemoryImage> _cache = {};
  static const int _maxCacheSize = 50;

  /// Get a cached MemoryImage for a base64 data URL, or null if not cached.
  MemoryImage? get(String dataUrl) => _cache[dataUrl];

  /// Store a MemoryImage for a base64 data URL with FIFO eviction.
  void put(String dataUrl, MemoryImage image) {
    if (_cache.length >= _maxCacheSize && !_cache.containsKey(dataUrl)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[dataUrl] = image;
  }

  /// Check if a data URL is cached.
  bool containsKey(String dataUrl) => _cache.containsKey(dataUrl);

  /// Clear the entire cache.
  void clear() => _cache.clear();
}

/// Builds an ImageProvider for Quill editor images.
///
/// Handles:
/// - Network images (http://, https://) → NetworkImage
/// - Base64 data URLs (data:image/...) → MemoryImage (cached)
/// - File paths → returns null (fallback to default behavior)
ImageProvider? buildQuillImageProvider(BuildContext context, String imageUrl) {
  // Network images
  if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
    return NetworkImage(imageUrl);
  }

  // Base64 data URLs
  if (imageUrl.startsWith('data:image/')) {
    final cache = QuillImageCache.instance;

    // Check cache first
    if (cache.containsKey(imageUrl)) {
      return cache.get(imageUrl);
    }

    // Decode and cache
    try {
      final regex = RegExp(r'^data:image/[^;]+;base64,(.+)$');
      final match = regex.firstMatch(imageUrl);
      if (match != null) {
        final base64Data = match.group(1)!;
        final bytes = base64Decode(base64Data);
        final image = MemoryImage(bytes);
        cache.put(imageUrl, image);
        return image;
      }
    } catch (e) {
      AppLogger.error('[QuillImageUtils] Failed to decode data URL', e);
    }
  }

  // Fallback: return null for file paths (handled by default behavior)
  return null;
}

/// Builds an error widget for failed Quill editor images.
Widget buildQuillImageErrorWidget(
  BuildContext context,
  Object error,
  StackTrace? stackTrace,
) {
  return Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: const Color(0xFF9E9E9E).withAlpha(50), // Colors.grey
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          IconData(
            0xe0a8,
            fontFamily: 'MaterialIcons',
          ), // broken_image_outlined
          size: 16,
          color: Color(0xFF9E9E9E),
        ),
        const SizedBox(width: 4),
        Text(
          context.l10n.imageFailedToLoad,
          style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
      ],
    ),
  );
}
