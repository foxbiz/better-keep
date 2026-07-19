import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readAudioFilePrefix(String filePath, int length) async {
  final file = await File(filePath).open();
  try {
    // Await before entering finally. Returning the Future directly lets the
    // close operation race the still-pending read on Android.
    return await file.read(length);
  } finally {
    await file.close();
  }
}
