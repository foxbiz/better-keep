import 'dart:io';
import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:path/path.dart' as path;

Future<Uint8List> readKeepArchiveFile(String filePath) =>
    File(filePath).readAsBytes();

Future<List<KeepArchiveEntry>> readKeepDirectory(
  String directoryPath, {
  KeepImportOptions options = const KeepImportOptions(),
  KeepImportCancellationToken? cancellationToken,
}) async {
  final root = Directory(directoryPath);
  if (!await root.exists()) {
    throw const KeepImportValidationException(
      'The selected Google Keep directory no longer exists.',
    );
  }

  final entries = <KeepArchiveEntry>[];
  var totalBytes = 0;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    cancellationToken?.throwIfCancelled();
    if (entity is Link) {
      throw const KeepImportValidationException(
        'Symbolic links are not supported in an extracted Keep folder.',
      );
    }
    if (entity is! File) continue;
    if (entries.length >= options.maxFileCount) {
      throw KeepImportValidationException(
        'The folder contains more than ${options.maxFileCount} files.',
      );
    }

    final size = await entity.length();
    if (size > options.maxEntryBytes) {
      throw KeepImportValidationException(
        '${path.basename(entity.path)} is larger than the per-file safety limit.',
      );
    }
    totalBytes += size;
    if (totalBytes > options.maxUncompressedBytes) {
      throw const KeepImportValidationException(
        'The selected folder exceeds the import safety limit.',
      );
    }

    final relativePath = path
        .relative(entity.path, from: root.path)
        .replaceAll(path.separator, '/');
    if (relativePath == '..' || relativePath.startsWith('../')) {
      throw const KeepImportValidationException(
        'The selected folder contains an unsafe path.',
      );
    }
    entries.add(
      KeepArchiveEntry(path: relativePath, bytes: await entity.readAsBytes()),
    );
  }
  return entries;
}
