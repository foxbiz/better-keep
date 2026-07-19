import 'dart:convert';
import 'dart:typed_data';
import 'package:better_keep/utils/file_utils.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/material.dart';

typedef PasswordProtectedImageDecoder =
    Future<Uint8List> Function(Uint8List protectedBytes);

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

  /// Invalidate a cached image so it will be reloaded from disk.
  /// Call this when an image file is updated.
  void invalidate(String path) {
    if (path.isEmpty) return;
    _cache.remove(path);
    // Also remove from path mapping
    final fixedPath = _pathToFixedPath.remove(path);
    if (fixedPath != null) {
      _cache.remove(fixedPath);
    }
    // Check if path was a fixed path that other original paths point to
    _pathToFixedPath.removeWhere((_, v) => v == path);
  }

  /// Clear all cached images.
  void clear() {
    _cache.clear();
    _pathToFixedPath.clear();
  }
}

class UniversalImage extends StatefulWidget {
  final String path;
  final BoxFit? fit;
  final Widget Function(BuildContext, Widget, ImageChunkEvent?)? loadingBuilder;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;
  final PasswordProtectedImageDecoder? passwordProtectedDecoder;

  const UniversalImage({
    super.key,
    required this.path,
    this.fit,
    this.loadingBuilder,
    this.errorBuilder,
    this.passwordProtectedDecoder,
  });

  @visibleForTesting
  static Future<Uint8List> prepareImageBytes(
    Uint8List storedBytes, {
    PasswordProtectedImageDecoder? passwordProtectedDecoder,
  }) async {
    if (!isBytesPasswordEncrypted(storedBytes)) return storedBytes;
    if (passwordProtectedDecoder == null) {
      throw StateError('Image file is still password-protected');
    }
    final plaintext = await passwordProtectedDecoder(storedBytes);
    if (plaintext.isEmpty || isBytesPasswordEncrypted(plaintext)) {
      throw StateError('Password-protected image failed verification');
    }
    return plaintext;
  }

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
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initImage();
  }

  @override
  void didUpdateWidget(UniversalImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final authorizationChanged =
        (oldWidget.passwordProtectedDecoder == null) !=
        (widget.passwordProtectedDecoder == null);
    if (oldWidget.path != widget.path || authorizationChanged) {
      if (authorizationChanged) {
        // Never retain authenticated bytes after the session ends, or reuse a
        // previous load failure after a session begins.
        _fixedPath = null;
        _imageBytes = null;
      }
      _initImage();
    }
  }

  void _initImage() {
    final path = widget.path;
    final loadGeneration = ++_loadGeneration;

    // Handle data URIs and network URLs immediately (synchronous)
    if (path.startsWith('data:image') || path.startsWith('http')) {
      _fixedPath = path;
      _isLoading = false;
      _error = null;
      return;
    }

    // Check cache synchronously - critical for Hero animations
    // Authenticated plaintext is intentionally scoped to this widget rather
    // than the global path cache. A locked card must never recover full image
    // bytes merely by knowing the canonical attachment path.
    if (widget.passwordProtectedDecoder == null) {
      final cachedBytes = UniversalImageCache.instance.getBytes(path);
      if (cachedBytes != null && !isBytesPasswordEncrypted(cachedBytes)) {
        _imageBytes = cachedBytes;
        _isLoading = false;
        _error = null;
        return;
      }
    }

    // Need to load async - but keep the old image visible to prevent blinking
    // Only set _isLoading = true if we don't have any image to show
    if (_imageBytes == null && _fixedPath == null) {
      _isLoading = true;
    }
    _error = null;
    _loadingPath = path;
    _loadImage(loadGeneration);
  }

  Future<void> _loadImage(int loadGeneration) async {
    final path = widget.path;
    final loadingPath = _loadingPath;

    try {
      final fixedPath = await FileUtils.fixPath(path);

      // Check if the path changed while we were loading
      if (_loadGeneration != loadGeneration ||
          _loadingPath != loadingPath ||
          !mounted) {
        return;
      }

      // Double-check cache after async gap
      final cachedBytes = widget.passwordProtectedDecoder == null
          ? UniversalImageCache.instance.getBytes(fixedPath)
          : null;
      if (cachedBytes != null && !isBytesPasswordEncrypted(cachedBytes)) {
        if (mounted &&
            _loadGeneration == loadGeneration &&
            _loadingPath == loadingPath) {
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
      if (_loadGeneration != loadGeneration ||
          _loadingPath != loadingPath ||
          !mounted) {
        return;
      }

      var exists = await fs.exists(fixedPath);

      // If file doesn't exist, try to re-download from remote
      if (!exists) {
        final redownloadedPath = await NoteSyncService().redownloadFile(path);
        if (redownloadedPath != null) {
          // Check path didn't change during redownload
          if (_loadGeneration != loadGeneration ||
              _loadingPath != loadingPath ||
              !mounted) {
            return;
          }
          exists = await fs.exists(fixedPath);
        }
      }

      if (!exists) {
        throw StateError('Image not found at $fixedPath');
      }

      // Check again if path changed
      if (_loadGeneration != loadGeneration ||
          _loadingPath != loadingPath ||
          !mounted) {
        return;
      }

      final storedBytes = await readEncryptedBytes(fixedPath);
      final bytes = await UniversalImage.prepareImageBytes(
        storedBytes,
        passwordProtectedDecoder: widget.passwordProtectedDecoder,
      );

      // Public images can use the global Hero cache. Authenticated plaintext
      // stays only in this widget's state for the duration of the session.
      if (widget.passwordProtectedDecoder == null) {
        UniversalImageCache.instance.put(path, fixedPath, bytes);
      }

      // Final check before setting state
      if (mounted &&
          _loadGeneration == loadGeneration &&
          _loadingPath == loadingPath) {
        setState(() {
          _fixedPath = fixedPath;
          _imageBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      // Only show error if this is still the current loading operation
      if (mounted &&
          _loadGeneration == loadGeneration &&
          _loadingPath == loadingPath) {
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
