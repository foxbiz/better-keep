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

    // On iOS, the container ID changes on every run/update.
    // We need to strip the old container path and replace it with the current one.

    // Check if it's a path in the Caches directory
    if (pathName.contains('/Library/Caches/')) {
      final cacheDir = await fs.cacheDir;
      // Try to find the part after 'Caches/'
      final parts = pathName.split('/Library/Caches/');
      if (parts.length > 1) {
        final relativePath = parts[1];
        return path.join(cacheDir, relativePath);
      }
      return path.join(cacheDir, path.basename(pathName));
    }

    // Check if it's a path in the Documents directory
    if (pathName.contains('/Documents/')) {
      final docDir = await fs.documentDir;
      final parts = pathName.split('/Documents/');
      if (parts.length > 1) {
        final relativePath = parts[1];
        return path.join(docDir, relativePath);
      }
    }

    return pathName;
  }
}
