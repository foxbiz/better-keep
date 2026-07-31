import 'dart:typed_data';

import 'package:path/path.dart' as path;

import 'file_system_base.dart';

/// Restricts account-owned files to a child of the platform application roots.
///
/// Live uses the platform file system directly for backward compatibility.
/// Emulator mode uses this wrapper so sign-out and cache cleanup cannot touch
/// Live attachments or downloaded note content.
class ScopedFileSystem implements FileSystem {
  ScopedFileSystem(this._delegate, {required this.directoryName})
    : assert(directoryName.isNotEmpty);

  final FileSystem _delegate;
  final String directoryName;

  @override
  Future<String> get cacheDir async =>
      path.join(await _delegate.cacheDir, directoryName);

  @override
  Future<String> get documentDir async =>
      path.join(await _delegate.documentDir, directoryName);

  @override
  Future<void> writeBytes(
    String filePath,
    Uint8List data, {
    bool append = false,
  }) => _delegate.writeBytes(filePath, data, append: append);

  @override
  Future<void> writeString(
    String filePath,
    String data, {
    bool append = false,
  }) => _delegate.writeString(filePath, data, append: append);

  @override
  Future<Uint8List> readBytes(String filePath) => _delegate.readBytes(filePath);

  @override
  Future<String> readString(String filePath) => _delegate.readString(filePath);

  @override
  Future<bool> delete(String filePath) => _delegate.delete(filePath);

  @override
  Future<bool> exists(String filePath) => _delegate.exists(filePath);

  @override
  Future<bool> isDirectory(String filePath) => _delegate.isDirectory(filePath);

  @override
  Future<bool> isFile(String filePath) => _delegate.isFile(filePath);

  @override
  Future<List<String>> list([String directory = '/']) async {
    final target = directory == '/' ? await documentDir : directory;
    return _delegate.list(target);
  }

  @override
  Future<String> copy(String sourcePath, String targetPath) =>
      _delegate.copy(sourcePath, targetPath);

  @override
  Future<int?> length(String filePath) => _delegate.length(filePath);

  @override
  Future<void> createDirectory(String directory) =>
      _delegate.createDirectory(directory);

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) =>
      _delegate.saveToGallery(imageBytes, fileName);

  @override
  String get backendType => _delegate.backendType;

  @override
  bool get opfsSupported => _delegate.opfsSupported;

  @override
  Future<List<Map<String, dynamic>>> listRecursive([
    String directory = '/',
  ]) async {
    final target = directory == '/' ? await documentDir : directory;
    return _delegate.listRecursive(target);
  }

  @override
  Future<Map<String, dynamic>> testOpfs() => _delegate.testOpfs();
}
