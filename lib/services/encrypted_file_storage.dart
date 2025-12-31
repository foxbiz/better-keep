/// Encrypted file storage utilities.
///
/// Provides helper functions to read/write files with local data encryption.
/// This wraps the FileSystem operations to automatically encrypt/decrypt
/// attachment files when local data protection is enabled.
library;

import 'dart:typed_data';

import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';

/// Writes bytes to a file, optionally encrypting them based on local data
/// protection settings.
///
/// Use this for saving attachments (images, audio, sketches) to local storage.
Future<void> writeEncryptedBytes(String path, Uint8List data) async {
  final fs = await fileSystem();
  final encryption = LocalDataEncryption.instance;
  final encryptedData = await encryption.encryptBytes(data);
  await fs.writeBytes(path, encryptedData);
}

/// Reads bytes from a file, automatically decrypting if the file is encrypted.
///
/// Use this for loading attachments from local storage.
Future<Uint8List> readEncryptedBytes(String path) async {
  final fs = await fileSystem();
  final data = await fs.readBytes(path);
  final encryption = LocalDataEncryption.instance;
  return await encryption.decryptBytes(data);
}

/// Checks if a file at the given path is encrypted.
Future<bool> isFileEncrypted(String path) async {
  final fs = await fileSystem();
  if (!await fs.exists(path)) return false;
  final data = await fs.readBytes(path);
  return LocalDataEncryption.isBytesEncrypted(data);
}
