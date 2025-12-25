// Platform-selecting entry point for file system access.
//
// This exposes a single factory [fileSystem] that yields a [FileSystem]
// backed by a web implementation (OPFS with IndexedDB fallback) on web and a
// dart:io-backed implementation on other platforms. Unsupported platforms throw
// [UnsupportedError].

import 'file_system_base.dart';
import 'file_system_stub.dart'
    if (dart.library.html) 'web_file_system.dart'
    if (dart.library.io) 'file_system_io.dart'
    as impl;

export 'file_system_base.dart';

/// Obtain the platform-appropriate [FileSystem] implementation.
Future<FileSystem> fileSystem() => impl.createFileSystem();
