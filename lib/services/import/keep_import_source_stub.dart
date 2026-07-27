import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';

Future<Uint8List> readKeepArchiveFile(String filePath) {
  throw UnsupportedError(
    'Reading a file path is unavailable on this platform. Provide in-memory bytes instead.',
  );
}

Future<List<KeepArchiveEntry>> readKeepDirectory(
  String directoryPath, {
  KeepImportOptions options = const KeepImportOptions(),
  KeepImportCancellationToken? cancellationToken,
}) {
  throw UnsupportedError(
    'Importing an extracted directory is unavailable on this platform.',
  );
}
