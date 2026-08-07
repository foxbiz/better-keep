import 'dart:typed_data';

import 'keep_import_source_stub.dart'
    if (dart.library.io) 'keep_import_source_io.dart'
    as platform;

Future<Uint8List> readKeepArchiveFile(String filePath) =>
    platform.readKeepArchiveFile(filePath);
