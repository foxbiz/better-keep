import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readKeepArchiveFile(String filePath) =>
    File(filePath).readAsBytes();
