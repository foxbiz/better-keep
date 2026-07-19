import 'dart:typed_data';

import 'audio_file_prefix_reader_stub.dart'
    if (dart.library.io) 'audio_file_prefix_reader_io.dart'
    as impl;

Future<Uint8List> readAudioFilePrefix(String filePath, int length) =>
    impl.readAudioFilePrefix(filePath, length);
