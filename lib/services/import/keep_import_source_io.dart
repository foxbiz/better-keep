import 'dart:io';
import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';

Future<Uint8List> readKeepArchiveFile(
  String filePath, {
  required int maxBytes,
  required KeepImportCancellationToken cancellationToken,
}) async {
  final bytes = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in File(filePath).openRead()) {
    cancellationToken.throwIfCancelled();
    received += chunk.length;
    if (received > maxBytes) {
      throw const KeepImportValidationException(
        'The selected ZIP exceeds the configured import limit.',
      );
    }
    bytes.add(chunk);
  }
  cancellationToken.throwIfCancelled();
  return bytes.takeBytes();
}
