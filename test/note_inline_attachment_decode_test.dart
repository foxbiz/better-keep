import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads base64 inline attachment bytes exactly', () async {
    final expected = Uint8List.fromList([0, 1, 2, 127, 128, 255]);
    final source =
        'data:application/octet-stream;base64,'
        '${base64Encode(expected)}';

    expect(await Note().readAttachmentForSession(source), expected);
  });

  test('reads percent-encoded inline attachment as UTF-8', () async {
    const value = 'Sketch ✓ 日本語';
    final source = 'data:text/plain,${Uri.encodeComponent(value)}';

    expect(await Note().readAttachmentForSession(source), utf8.encode(value));
  });

  test('rejects malformed inline attachment data', () async {
    await expectLater(
      Note().readAttachmentForSession('data:text/plain;base64,%%%'),
      throwsA(isA<NoteUnlockException>()),
    );
  });
}
