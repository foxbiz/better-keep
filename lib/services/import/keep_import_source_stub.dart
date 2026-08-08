import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';

Future<Uint8List> readKeepArchiveFile(
  String filePath, {
  required int maxBytes,
  required KeepImportCancellationToken cancellationToken,
}) {
  throw UnsupportedError(
    'Reading a file path is unavailable on this platform. Provide in-memory bytes instead.',
  );
}
