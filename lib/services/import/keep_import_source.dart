import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';

import 'keep_import_source_stub.dart'
    if (dart.library.io) 'keep_import_source_io.dart'
    as platform;

Future<Uint8List> readKeepArchiveFile(String filePath) =>
    platform.readKeepArchiveFile(filePath);

Future<List<KeepArchiveEntry>> readKeepDirectory(
  String directoryPath, {
  KeepImportOptions options = const KeepImportOptions(),
  KeepImportCancellationToken? cancellationToken,
}) => platform.readKeepDirectory(
  directoryPath,
  options: options,
  cancellationToken: cancellationToken,
);
