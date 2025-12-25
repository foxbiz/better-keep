import 'dart:typed_data';

import 'file_system_base.dart';

/// Stub implementation used when no file system backend is available.
class FileSystemStub implements FileSystem {
  const FileSystemStub();

  static Future<FileSystem> instance({String? indexedDbName}) async {
    throw UnsupportedError('FileSystem is not available on this platform.');
  }

  @override
  Future<String> get cacheDir => throw UnimplementedError("Not implemented");

  @override
  Future<String> get documentDir => throw UnimplementedError("Not implemented");

  @override
  Future<void> writeBytes(String path, Uint8List data, {bool append = false}) =>
      _unsupported();

  @override
  Future<void> writeString(String path, String data, {bool append = false}) =>
      _unsupported();

  @override
  Future<Uint8List> readBytes(String path) => _unsupported();

  @override
  Future<String> readString(String path) => _unsupported();

  @override
  Future<bool> delete(String path) => _unsupported();

  @override
  Future<bool> exists(String path) => _unsupported();

  @override
  Future<List<String>> list([String directory = '/']) => _unsupported();

  @override
  Future<String> copy(String sourcePath, String targetPath) => _unsupported();

  @override
  Future<int?> length(String path) => _unsupported();

  @override
  Future<void> createDirectory(String path) => _unsupported();

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) =>
      _unsupported();

  // Web-specific methods - not supported on stub
  @override
  String get backendType =>
      throw UnsupportedError('backendType is only available on web');

  @override
  bool get opfsSupported =>
      throw UnsupportedError('opfsSupported is only available on web');

  @override
  Future<List<Map<String, dynamic>>> listRecursive([String directory = '/']) =>
      throw UnsupportedError('listRecursive is only available on web');

  @override
  Future<Map<String, dynamic>> testOpfs() =>
      throw UnsupportedError('testOpfs is only available on web');

  Never _unsupported() {
    throw UnsupportedError('FileSystem is not available on this platform.');
  }
}

/// Fallback factory for unsupported platforms.
Future<FileSystem> createFileSystem() => FileSystemStub.instance();
