import 'dart:typed_data';

/// Common interface for file system operations across platforms.
abstract class FileSystem {
  Future<String> get cacheDir;
  Future<String> get documentDir;
  Future<void> writeBytes(String path, Uint8List data, {bool append = false});
  Future<void> writeString(String path, String data, {bool append = false});
  Future<Uint8List> readBytes(String path);
  Future<String> readString(String path);
  Future<bool> delete(String path);
  Future<bool> exists(String path);
  Future<List<String>> list([String directory = '/']);
  Future<String> copy(String sourcePath, String targetPath);
  Future<int?> length(String path);

  /// Create a directory at the given path recursively
  Future<void> createDirectory(String path);

  /// Save image to device gallery (mobile) or download (web)
  /// Returns true if successful
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName);

  // Web-specific debug methods (throws on non-web platforms)
  /// Get the backend type (e.g., 'OPFS', 'IndexedDB'). Web only.
  String get backendType;

  /// Check if OPFS is supported. Web only.
  bool get opfsSupported;

  /// List all files recursively with metadata. Web only.
  Future<List<Map<String, dynamic>>> listRecursive([String directory = '/']);

  /// Test OPFS functionality. Web only.
  Future<Map<String, dynamic>> testOpfs();

  /// Check if path is directory
  Future<bool> isDirectory(String path);

  /// Check if path is file
  Future<bool> isFile(String path);
}
