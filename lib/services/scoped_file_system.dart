import 'dart:typed_data';

import 'package:path/path.dart' as path;

import 'file_system_base.dart';

/// Restricts account-owned files to a child of the platform application roots.
///
/// Emulator storage is nested below its environment root. After sign-out,
/// both environments also place each new library in its own generation.
class ScopedFileSystem implements FileSystem {
  ScopedFileSystem(this._delegate, {required this.directoryName})
    : _resolve = null,
      assert(directoryName.isNotEmpty);

  ScopedFileSystem.resolving(this._delegate, this._resolve)
    : directoryName = '';
  final Future<String> Function()? _resolve;
  Future<String>? _resolvedName;
  Future<String> _root(String base) async {
    final resolve = _resolve;
    if (resolve == null) return path.join(base, directoryName);
    // Both roots on this handle belong to the same account, even if sign-out
    // happens between obtaining the document directory and the cache directory.
    final pending = _resolvedName ??= resolve();
    try {
      return path.join(base, await pending);
    } catch (_) {
      if (identical(_resolvedName, pending)) _resolvedName = null;
      rethrow;
    }
  }

  final FileSystem _delegate;
  final String directoryName;

  @override
  Future<String> get cacheDir async => _root(await _delegate.cacheDir);

  @override
  Future<String> get documentDir async => _root(await _delegate.documentDir);

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
  Future<void> deleteTrees(List<String> paths) => _delegate.deleteTrees(paths);

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
