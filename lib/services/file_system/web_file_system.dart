// ignore_for_file: uri_does_not_exist, avoid_web_libraries_in_flutter, dead_code, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:indexed_db' as idb;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'file_system_base.dart';

class WebFileSystem implements FileSystem {
  WebFileSystem._(this._backend);

  static WebFileSystem? _cached;
  static bool _initializing = false;
  final _FileSystemBackend _backend;

  static Future<WebFileSystem> instance() async {
    if (!kIsWeb) {
      throw UnsupportedError(
        'OPFS/IndexedDB file system is only available on web.',
      );
    }
    if (_cached != null) return _cached!;

    // Prevent concurrent initialization
    if (_initializing) {
      // Wait for initialization to complete
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (_cached != null) return _cached!;
    }

    _initializing = true;
    try {
      final backend = await _selectBackend().timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('File system initialization timed out'),
      );
      final fs = WebFileSystem._(backend);
      _cached = fs;
      return fs;
    } finally {
      _initializing = false;
    }
  }

  /// Resets the cached instance, forcing reinitialization on next access.
  /// Use this when the file system is in a corrupted state.
  static void reset() {
    _cached = null;
    _initializing = false;
  }

  @override
  Future<String> get cacheDir => Future.value('/cache');

  @override
  Future<String> get documentDir => Future.value('/documents');

  @override
  Future<void> writeBytes(String path, Uint8List data, {bool append = false}) =>
      _backend.writeBytes(path, data, append: append);

  @override
  Future<void> writeString(String path, String data, {bool append = false}) =>
      _backend.writeString(path, data, append: append);

  @override
  Future<Uint8List> readBytes(String path) => _backend.readBytes(path);

  @override
  Future<String> readString(String path) => _backend.readString(path);

  @override
  Future<bool> delete(String path) => _backend.delete(path);

  @override
  Future<bool> exists(String path) => _backend.exists(path);

  @override
  Future<bool> isDirectory(String path) => _backend.isDirectory(path);

  @override
  Future<bool> isFile(String path) => _backend.isFile(path);

  @override
  Future<List<String>> list([String directory = '/']) =>
      _backend.list(directory);

  @override
  Future<String> copy(String sourcePath, String targetPath) async {
    final bytes = await readBytes(sourcePath);
    await writeBytes(targetPath, bytes);
    return targetPath;
  }

  @override
  Future<int?> length(String path) async {
    final bytes = await readBytes(path);
    return bytes.length;
  }

  @override
  Future<void> createDirectory(String path) async {
    // On web (OPFS/IndexedDB), directories are created implicitly when writing files.
    // This is a no-op for web compatibility.
  }

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) async {
    try {
      // Create a blob from the image bytes
      final blob = html.Blob([imageBytes], 'image/png');
      final url = html.Url.createObjectUrlFromBlob(blob);

      // Create an anchor element and trigger download
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', fileName)
        ..style.display = 'none';

      html.document.body?.children.add(anchor);
      anchor.click();

      // Clean up
      html.document.body?.children.remove(anchor);
      html.Url.revokeObjectUrl(url);

      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  String get backendType => _backend is _OpfsBackend ? 'OPFS' : 'IndexedDB';

  /// Check if OPFS is supported (static)
  static bool get isOpfsSupported => _OpfsBackend.isSupported;

  @override
  bool get opfsSupported => _OpfsBackend.isSupported;

  /// List all files recursively with their sizes (with timeout and depth limit)
  @override
  Future<List<Map<String, dynamic>>> listRecursive([
    String directory = '/',
    int maxDepth = 3,
  ]) async {
    final result = <Map<String, dynamic>>[];
    try {
      await _listRecursiveHelper(
        directory,
        result,
        0,
        maxDepth,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      result.add({'path': 'Error', 'type': 'error', 'message': e.toString()});
    }
    return result;
  }

  Future<void> _listRecursiveHelper(
    String directory,
    List<Map<String, dynamic>> result,
    int currentDepth,
    int maxDepth,
  ) async {
    if (currentDepth >= maxDepth) return;

    List<String> entries;
    try {
      entries = await list(directory);
    } catch (e) {
      result.add({
        'path': directory,
        'type': 'error',
        'message': 'Failed to list: $e',
      });
      return;
    }

    if (entries.isEmpty && currentDepth == 0) {
      result.add({
        'path': directory,
        'type': 'info',
        'message': 'Directory is empty or does not exist',
      });
    }

    for (final entry in entries) {
      final fullPath = directory == '/' ? '/$entry' : '$directory/$entry';

      // Try to get file size (this also checks if it's a file)
      int? size;
      bool isFile = false;
      try {
        size = await length(fullPath);
        isFile = true;
      } catch (_) {
        // Not a file or can't read - might be a directory
      }

      if (isFile) {
        result.add({'path': fullPath, 'size': size, 'type': 'file'});
      } else {
        // Try as directory
        try {
          final subEntries = await list(fullPath);
          result.add({
            'path': fullPath,
            'type': 'directory',
            'count': subEntries.length,
          });
          await _listRecursiveHelper(
            fullPath,
            result,
            currentDepth + 1,
            maxDepth,
          );
        } catch (_) {
          // Neither file nor directory we can read
          result.add({'path': fullPath, 'type': 'unknown'});
        }
      }
    }
  }

  @override
  Future<Map<String, dynamic>> testOpfs() async {
    final testPath = '/cache/_opfs_test.txt';
    final testData = 'OPFS test ${DateTime.now().toIso8601String()}';
    final results = <String, dynamic>{
      'backendType': backendType,
      'isOpfsSupported': isOpfsSupported,
    };

    try {
      // Test write
      await writeString(testPath, testData);
      results['write'] = 'OK';

      // Test exists
      final fileExists = await exists(testPath);
      results['exists'] = fileExists;

      // Test read
      final readData = await readString(testPath);
      results['read'] = readData == testData ? 'OK' : 'Mismatch';
      results['readData'] = readData;

      // Test list
      final files = await list('/cache');
      results['list'] = files;

      // Cleanup
      await delete(testPath);
      results['delete'] = 'OK';
    } catch (e, stack) {
      results['error'] = e.toString();
      results['stack'] = stack.toString().split('\n').take(5).join('\n');
    }

    return results;
  }

  static Future<_FileSystemBackend> _selectBackend() async {
    if (_OpfsBackend.isSupported) {
      try {
        final backend = _OpfsBackend();
        await backend.init().timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('OPFS init timed out'),
        );
        return backend;
      } catch (e) {
        // OPFS failed, fall back to IndexedDB
      }
    }

    final backend = _IndexedDbBackend(dbName: 'better_keep_fs');
    await backend.init().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('IndexedDB init timed out'),
    );
    return backend;
  }
}

/// Factory used by conditional imports to create the web-backed file system.
Future<FileSystem> createFileSystem() => WebFileSystem.instance();

abstract class _FileSystemBackend {
  Future<void> init();
  Future<void> writeBytes(String path, Uint8List data, {bool append = false});
  Future<void> writeString(String path, String data, {bool append = false});
  Future<Uint8List> readBytes(String path);
  Future<String> readString(String path);
  Future<bool> delete(String path);
  Future<bool> exists(String path);
  Future<bool> isDirectory(String path);
  Future<bool> isFile(String path);
  Future<List<String>> list(String directory);
}

class _OpfsBackend implements _FileSystemBackend {
  dynamic _root;

  static bool get isSupported {
    final navigator = html.window.navigator;
    if (!js_util.hasProperty(navigator, 'storage')) return false;
    final storage = js_util.getProperty(navigator, 'storage');
    return storage != null && js_util.hasProperty(storage, 'getDirectory');
  }

  @override
  Future<void> init() async {
    final storage = js_util.getProperty(html.window.navigator, 'storage');
    _root = await _promise(js_util.callMethod(storage, 'getDirectory', []));

    // Test that createWritable is actually available (Safari doesn't support it)
    await _testCreateWritable();
  }

  /// Tests that createWritable works - throws if not supported (e.g., Safari)
  Future<void> _testCreateWritable() async {
    const testFileName = '.opfs_write_test';
    final options = js_util.jsify({'create': true});
    final fileHandle = await _promise(
      js_util.callMethod(_root, 'getFileHandle', [testFileName, options]),
    );

    // This will throw on Safari which doesn't support createWritable
    final writable = await _promise(
      js_util.callMethod(fileHandle, 'createWritable', []),
    );
    await _promise(js_util.callMethod(writable, 'write', [Uint8List(0)]));
    await _promise(js_util.callMethod(writable, 'close', []));

    // Clean up test file
    try {
      await _promise(js_util.callMethod(_root, 'removeEntry', [testFileName]));
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  @override
  Future<void> writeBytes(
    String path,
    Uint8List data, {
    bool append = false,
  }) async {
    final fileHandle = await _getFileHandle(path, create: true);
    if (fileHandle == null) {
      throw StateError('Unable to create file at $path');
    }

    if (append) {
      // For append mode, read existing content and combine
      try {
        final file = await _promise(
          js_util.callMethod(fileHandle, 'getFile', []),
        );
        final size = js_util.getProperty(file, 'size') as int;
        if (size > 0) {
          final buffer = await _promise(
            js_util.callMethod(file, 'arrayBuffer', []),
          );
          final existingBytes = _arrayBufferToUint8List(buffer);
          final combined = Uint8List(existingBytes.length + data.length);
          combined.setRange(0, existingBytes.length, existingBytes);
          combined.setRange(existingBytes.length, combined.length, data);
          data = combined;
        }
      } catch (_) {
        // File is new or empty, just write the data
      }
    }

    final writable = await _promise(
      js_util.callMethod(fileHandle, 'createWritable', []),
    );
    await _promise(js_util.callMethod(writable, 'write', [data]));
    await _promise(js_util.callMethod(writable, 'close', []));
  }

  @override
  Future<void> writeString(
    String path,
    String data, {
    bool append = false,
  }) async {
    return writeBytes(
      path,
      Uint8List.fromList(utf8.encode(data)),
      append: append,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final fileHandle = await _getFileHandle(path, create: false);
    if (fileHandle == null) throw "$path is not a file";

    final file = await _promise(js_util.callMethod(fileHandle, 'getFile', []));
    final buffer = await _promise(js_util.callMethod(file, 'arrayBuffer', []));
    return _arrayBufferToUint8List(buffer);
  }

  @override
  Future<String> readString(String path) async {
    final bytes = await readBytes(path);
    return utf8.decode(bytes);
  }

  @override
  Future<bool> delete(String path) async {
    final parts = _PathParts.from(path);
    final dir = await _resolveDirectory(parts.directories, create: false);
    if (dir == null) return false;
    try {
      await _promise(js_util.callMethod(dir, 'removeEntry', [parts.fileName]));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exists(String path) async {
    final handle = await _getFileHandle(path, create: false);
    return handle != null;
  }

  @override
  Future<bool> isDirectory(String path) async {
    final segments = _segments(path);
    final dirHandle = await _resolveDirectory(segments, create: false);
    return dirHandle != null;
  }

  @override
  Future<bool> isFile(String path) async {
    final fileHandle = await _getFileHandle(path, create: false);
    return fileHandle != null;
  }

  @override
  Future<List<String>> list(String directory) async {
    final segments = _segments(directory);
    final dirHandle = await _resolveDirectory(segments, create: false) ?? _root;
    if (dirHandle == null) return const [];

    final iterator = js_util.callMethod(dirHandle, 'entries', []);
    final results = <String>[];
    while (true) {
      final step = await _promise(js_util.callMethod(iterator, 'next', []));
      if (step == null) break;
      final done = js_util.getProperty(step, 'done') == true;
      if (done) break;
      final value = js_util.getProperty(step, 'value');
      final name =
          js_util.getProperty(value, '0') ?? js_util.getProperty(value, '1');
      if (name != null) {
        results.add(name.toString());
      }
    }
    return results;
  }

  Future<dynamic> _getFileHandle(String path, {required bool create}) async {
    final parts = _PathParts.from(path);
    final dirHandle = await _resolveDirectory(
      parts.directories,
      create: create,
    );
    if (dirHandle == null) return null;
    try {
      final options = js_util.jsify({'create': create});
      return await _promise(
        js_util.callMethod(dirHandle, 'getFileHandle', [
          parts.fileName,
          options,
        ]),
      );
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _resolveDirectory(
    List<String> segments, {
    required bool create,
  }) async {
    var current = _root;
    for (final segment in segments) {
      try {
        final options = js_util.jsify({'create': create});
        current = await _promise(
          js_util.callMethod(current, 'getDirectoryHandle', [segment, options]),
        );
      } catch (_) {
        return null;
      }
    }
    return current;
  }

  /// Converts a JavaScript ArrayBuffer to a Dart Uint8List.
  /// Handles both Dart ByteBuffer and JS ArrayBuffer types.
  Uint8List _arrayBufferToUint8List(dynamic buffer) {
    if (buffer is ByteBuffer) {
      return Uint8List.view(buffer);
    }
    // For JavaScript ArrayBuffer, use js_util to access the data
    final byteLength = js_util.getProperty(buffer, 'byteLength') as int;
    final uint8View = js_util.callConstructor(
      js_util.getProperty(html.window, 'Uint8Array'),
      [buffer],
    );
    final result = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      result[i] = js_util.getProperty(uint8View, i) as int;
    }
    return result;
  }
}

class _IndexedDbBackend implements _FileSystemBackend {
  _IndexedDbBackend({String? dbName}) : _dbName = dbName ?? 'opfs_fallback';

  final String _dbName;
  final String _storeName = 'files';
  idb.Database? _db;

  @override
  Future<void> init() async {
    final factory = html.window.indexedDB;
    if (factory == null) {
      throw UnsupportedError('IndexedDB is not available in this environment.');
    }

    _db = await factory.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (idb.VersionChangeEvent event) {
        final db = (event.target as idb.Request).result as idb.Database;
        if (db.objectStoreNames?.contains(_storeName) != true) {
          db.createObjectStore(_storeName);
        }
      },
    );
  }

  @override
  Future<void> writeBytes(
    String path,
    Uint8List data, {
    bool append = false,
  }) async {
    final txn = _db!.transaction(_storeName, 'readwrite');
    final store = txn.objectStore(_storeName);

    if (append) {
      final existing = await store.getObject(path);
      if (existing != null) {
        Uint8List existingBytes;
        if (existing is ByteBuffer) {
          existingBytes = Uint8List.view(existing);
        } else {
          existingBytes = Uint8List.fromList(existing as List<int>);
        }
        final combined = Uint8List(existingBytes.length + data.length);
        combined.setRange(0, existingBytes.length, existingBytes);
        combined.setRange(existingBytes.length, combined.length, data);
        data = combined;
      }
    }

    await store.put(data, path);
    await txn.completed;
  }

  @override
  Future<void> writeString(String path, String data, {bool append = false}) {
    return writeBytes(
      path,
      Uint8List.fromList(utf8.encode(data)),
      append: append,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final txn = _db!.transaction(_storeName, 'readonly');
    final store = txn.objectStore(_storeName);
    final value = await store.getObject(path);
    await txn.completed;
    if (value == null) throw "$path is not a file";
    if (value is ByteBuffer) return Uint8List.view(value);
    try {
      return Uint8List.fromList(value as List<int>);
    } catch (_) {
      throw "$path is not a file";
    }
  }

  @override
  Future<String> readString(String path) {
    final bytesFuture = readBytes(path);
    return bytesFuture.then((bytes) => utf8.decode(bytes));
  }

  @override
  Future<bool> delete(String path) async {
    final txn = _db!.transaction(_storeName, 'readwrite');
    final store = txn.objectStore(_storeName);
    await store.delete(path);
    await txn.completed;
    return true;
  }

  @override
  Future<bool> exists(String path) async {
    final txn = _db!.transaction(_storeName, 'readonly');
    final store = txn.objectStore(_storeName);
    final value = await store.getObject(path);
    await txn.completed;
    return value != null;
  }

  @override
  Future<bool> isDirectory(String path) async {
    /// In IndexedDB backend, directories are not explicitly stored.
    /// We consider a path to be a directory if there are any entries
    /// that start with the given path followed by a '/'.
    final dirPrefix = path.endsWith('/') ? path : '$path/';
    final txn = _db!.transaction(_storeName, 'readonly');
    final store = txn.objectStore(_storeName);
    final cursorStream = store.openCursor(autoAdvance: true);
    bool found = false;
    await for (final cursor in cursorStream) {
      if (cursor != null) {
        final key = cursor.key.toString();
        if (key.startsWith(dirPrefix)) {
          found = true;
          break; // Stop iteration early
        }
      }
    }
    await txn.completed;
    return found;
  }

  @override
  Future<bool> isFile(String path) async {
    /// A path is considered a file if it exists in the store.
    return exists(path);
  }

  @override
  Future<List<String>> list(String directory) async {
    final txn = _db!.transaction(_storeName, 'readonly');
    final store = txn.objectStore(_storeName);
    final List<String> keys = [];

    await store.openCursor(autoAdvance: true).forEach((cursor) {
      if (cursor != null) {
        keys.add(cursor.key.toString());
      }
    });

    await txn.completed;
    return keys;
  }
}

class _PathParts {
  _PathParts(this.directories, this.fileName);

  final List<String> directories;
  final String fileName;

  factory _PathParts.from(String input) {
    final segments = _segments(input);
    if (segments.isEmpty) {
      throw ArgumentError('Path must include at least one segment.');
    }
    final fileName = segments.removeLast();
    return _PathParts(segments, fileName);
  }
}

List<String> _segments(String path) {
  return path
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
}

Future<dynamic> _promise(dynamic jsPromise) {
  return js_util.promiseToFuture(jsPromise);
}
