import 'dart:io';

import 'package:better_keep/services/audio_file_prefix_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finishes reading before closing the file handle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'better_keep_audio_prefix_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/recording.wav');
    await file.writeAsBytes([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]);

    for (var i = 0; i < 20; i++) {
      expect(await readAudioFilePrefix(file.path, 4), [0x52, 0x49, 0x46, 0x46]);
    }
  });
}
