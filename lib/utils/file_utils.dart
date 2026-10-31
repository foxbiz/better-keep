import 'dart:io';

import 'package:better_keep/services/file_system.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class FileUtils {
  static Future<String> fixPath(String pathName) async {
    // Only iOS has the container ID issue
    if (kIsWeb || !Platform.isIOS) {
      return pathName;
    }

    final fs = await fileSystem();

    return rebaseIosPath(
      pathName,
      documentDir: await fs.documentDir,
      cacheDir: await fs.cacheDir,
    );
  }

  /// Rebase the container while retaining an existing environment subdirectory.
  /// The supplied roots may already include the emulator's directory.
  @visibleForTesting
  static String rebaseIosPath(
    String source, {
    required String documentDir,
    required String cacheDir,
  }) {
    const documentMarkers = ['/Library/Application Support/', '/Documents/'];
    const cacheMarker = '/Library/Caches/';
    for (final marker in [cacheMarker, ...documentMarkers]) {
      final index = source.indexOf(marker);
      if (index < 0) continue;
      final root = marker == cacheMarker ? cacheDir : documentDir;
      var relative = source.substring(index + marker.length);
      final rootMarkers = marker == cacheMarker
          ? [cacheMarker]
          : documentMarkers;
      for (final rootMarker in rootMarkers) {
        final rootIndex = root.indexOf(rootMarker);
        if (rootIndex < 0) continue;
        final scope = root.substring(rootIndex + rootMarker.length);
        if (scope.isNotEmpty) {
          if (relative == scope) {
            relative = '';
          } else if (relative.startsWith('$scope/')) {
            relative = relative.substring(scope.length + 1);
          }
        }
        break;
      }
      return path.posix.join(root, relative);
    }
    return source;
  }
}
