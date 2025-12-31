import 'dart:convert';
import 'dart:typed_data';
import 'package:better_keep/utils/file_utils.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/services/sync/note_sync_service.dart';
import 'package:flutter/material.dart';

/// Global in-memory cache for image bytes to support smooth Hero animations.
/// When an image is loaded, it's cached here so the destination Hero widget
/// can display it immediately without async loading.
class UniversalImageCache {
  UniversalImageCache._();
  static final UniversalImageCache instance = UniversalImageCache._();

  final Map<String, Uint8List> _cache = {};
  final Map<String, String> _pathToFixedPath = {};
  static const int _maxCacheSize = 50;

  Uint8List? getBytes(String path) {
    // Try direct path first
    if (_cache.containsKey(path)) return _cache[path];
    // Try resolved path
    final fixedPath = _pathToFixedPath[path];
    if (fixedPath != null) return _cache[fixedPath];
    return null;
  }

  void put(String originalPath, String fixedPath, Uint8List bytes) {
    if (_cache.length >= _maxCacheSize && !_cache.containsKey(fixedPath)) {
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
      _pathToFixedPath.removeWhere((_, v) => v == oldestKey);
    }
    _cache[fixedPath] = bytes;
    _pathToFixedPath[originalPath] = fixedPath;
  }
}

class UniversalImage extends StatefulWidget {
  final String path;
  final BoxFit? fit;
  final Widget Function(BuildContext, Widget, ImageChunkEvent?)? loadingBuilder;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const UniversalImage({
    super.key,
    required this.path,
    this.fit,
    this.loadingBuilder,
    this.errorBuilder,
  });

  @override
  State<UniversalImage> createState() => _UniversalImageState();
}

class _UniversalImageState extends State<UniversalImage> {
  String? _fixedPath;
  Uint8List? _imageBytes;
  Object? _error;
  bool _isLoading = true;

  // Track the path we're currently loading to handle race conditions
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _initImage();
  }

  @override
  void didUpdateWidget(UniversalImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _initImage();
    }
  }

  void _initImage() {
    final path = widget.path;

    // Handle data URIs and network URLs immediately (synchronous)
    if (path.startsWith('data:image') || path.startsWith('http')) {
      _fixedPath = path;
      _isLoading = false;
      _error = null;
      return;
    }

    // Check cache synchronously - critical for Hero animations
    final cachedBytes = UniversalImageCache.instance.getBytes(path);
    if (cachedBytes != null) {
      _imageBytes = cachedBytes;
      _isLoading = false;
      _error = null;
      return;
    }

    // Need to load async - but keep the old image visible to prevent blinking
    // Only set _isLoading = true if we don't have any image to show
    if (_imageBytes == null && _fixedPath == null) {
      _isLoading = true;
    }
    _error = null;
    _loadingPath = path;
    _loadImage();
  }

  Future<void> _loadImage() async {
    final path = widget.path;
    final loadingPath = _loadingPath;

    try {
      final fixedPath = await FileUtils.fixPath(path);

      // Check if the path changed while we were loading
      if (_loadingPath != loadingPath || !mounted) return;

      // Double-check cache after async gap
      final cachedBytes = UniversalImageCache.instance.getBytes(fixedPath);
      if (cachedBytes != null) {
        if (mounted && _loadingPath == loadingPath) {
          setState(() {
            _fixedPath = fixedPath;
            _imageBytes = cachedBytes;
            _isLoading = false;
          });
        }
        return;
      }

      final fs = await fileSystem();

      // Check again if path changed
      if (_loadingPath != loadingPath || !mounted) return;

      var exists = await fs.exists(fixedPath);

      // If file doesn't exist, try to re-download from remote
      if (!exists) {
        final redownloadedPath = await NoteSyncService().redownloadFile(path);
        if (redownloadedPath != null) {
          // Check path didn't change during redownload
          if (_loadingPath != loadingPath || !mounted) return;
          exists = await fs.exists(fixedPath);
        }
      }

      if (!exists) {
        throw StateError('Image not found at $fixedPath');
      }

      // Check again if path changed
      if (_loadingPath != loadingPath || !mounted) return;

      final bytes = await readEncryptedBytes(fixedPath);

      // Cache for future Hero animations
      UniversalImageCache.instance.put(path, fixedPath, bytes);

      // Final check before setting state
      if (mounted && _loadingPath == loadingPath) {
        setState(() {
          _fixedPath = fixedPath;
          _imageBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      // Only show error if this is still the current loading operation
      if (mounted && _loadingPath == loadingPath) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show loading state
    if (_isLoading) {
      return widget.loadingBuilder?.call(
            context,
            const SizedBox.shrink(),
            null,
          ) ??
          const SizedBox.shrink();
    }

    // Show error state
    if (_error != null) {
      return widget.errorBuilder?.call(context, _error!, null) ??
          const Center(child: Icon(Icons.broken_image));
    }

    final path = _fixedPath;

    // Handle data URI
    if (path != null && path.startsWith('data:image')) {
      try {
        final base64String = path.split(',').last;
        return Image.memory(
          base64Decode(base64String),
          fit: widget.fit,
          errorBuilder: widget.errorBuilder,
          gaplessPlayback: true,
        );
      } catch (e) {
        return widget.errorBuilder?.call(context, e, null) ??
            const Center(child: Icon(Icons.broken_image));
      }
    }

    // Handle network URL
    if (path != null && path.startsWith('http')) {
      return Image.network(
        path,
        fit: widget.fit,
        loadingBuilder: widget.loadingBuilder,
        errorBuilder: widget.errorBuilder,
        gaplessPlayback: true,
      );
    }

    // Handle file bytes
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
        gaplessPlayback: true,
      );
    }

    return const SizedBox.shrink();
  }
}
