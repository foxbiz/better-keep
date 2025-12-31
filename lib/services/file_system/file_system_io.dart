import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'file_system_base.dart';

class IoFileSystem implements FileSystem {
  const IoFileSystem();

  @override
  Future<String> get cacheDir async {
    final dir = await getApplicationCacheDirectory();
    return dir.path;
  }

  @override
  Future<String> get documentDir async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  @override
  Future<void> writeBytes(
    String path,
    Uint8List data, {
    bool append = false,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      data,
      flush: true,
      mode: append ? FileMode.append : FileMode.write,
    );
  }

  @override
  Future<void> writeString(
    String path,
    String data, {
    bool append = false,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      data,
      mode: append ? FileMode.append : FileMode.write,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final file = File(path);
    if (!await file.exists()) throw "$path is not a file";
    return file.readAsBytes();
  }

  @override
  Future<String> readString(String path) async {
    final file = File(path);
    if (!await file.exists()) throw "$path is not a file";
    return file.readAsString();
  }

  @override
  Future<bool> delete(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exists(String path) async {
    final file = File(path);
    return file.exists();
  }

  @override
  Future<bool> isDirectory(String path) async {
    final file = File(path);
    final stats = await file.stat();
    return stats.type == FileSystemEntityType.directory;
  }

  @override
  Future<bool> isFile(String path) async {
    final file = File(path);
    final stats = await file.stat();
    return stats.type == FileSystemEntityType.file;
  }

  @override
  Future<List<String>> list([String directory = '/']) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return const [];
    final entries = await dir.list().toList();
    return entries.map((e) => e.path).toList();
  }

  @override
  Future<String> copy(String sourcePath, String targetPath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('Source file not found at $sourcePath');
    }
    await File(targetPath).parent.create(recursive: true);
    final copied = await sourceFile.copy(targetPath);
    return copied.path;
  }

  @override
  Future<int?> length(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.length();
  }

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/$fileName';
      final file = File(tempPath);
      await file.writeAsBytes(imageBytes);

      // Use Gal to save to gallery
      await Gal.putImage(tempPath);

      // Clean up temp file
      await file.delete();
      return true;
    } catch (e) {
      return false;
    }
  }

  // Web-specific methods - not supported on IO platforms
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
}

Future<FileSystem> createFileSystem() async => const IoFileSystem();
