import 'dart:typed_data';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes the decrypted incoming locked state before attachments', () {
    expect(NoteSyncService.isIncomingNoteLocked(true), isTrue);
    expect(NoteSyncService.isIncomingNoteLocked(1), isTrue);
    expect(NoteSyncService.isIncomingNoteLocked(false), isFalse);
    expect(NoteSyncService.isIncomingNoteLocked(0), isFalse);
    expect(NoteSyncService.isIncomingNoteLocked(null), isFalse);
  });

  test('removes all local presentation fields from remote JSON', () {
    final imageJson = NoteAttachment.image(
      NoteImage(
        src: '/local/image.jpg',
        size: 1,
        index: 0,
        aspectRatio: '1:1',
        lastModified: '',
        blurredThumbnail: 'local-image-thumbnail',
      ),
    ).toJson();
    final sketchJson = NoteAttachment.sketch(
      SketchData(
        strokesFilePath: '/local/strokes.json',
        previewImage: '/local/preview.png',
        blurredThumbnail: 'local-sketch-thumbnail',
      ),
    ).toJson();

    NoteSyncService.removeLocalAttachmentPresentationFromRemoteJson(imageJson);
    NoteSyncService.removeLocalAttachmentPresentationFromRemoteJson(sketchJson);

    expect(imageJson['data'], isNot(contains('blurredThumbnail')));
    expect(sketchJson['data'], isNot(contains('blurredThumbnail')));
    expect(sketchJson['data'], isNot(contains('previewImage')));
  });

  test('discards presentation fields received from older clients', () {
    final image = NoteImage(
      src: '/local/image.jpg',
      size: 1,
      index: 0,
      aspectRatio: '1:1',
      lastModified: '',
      blurredThumbnail: 'remote-image-thumbnail',
    );
    final sketch = SketchData(
      previewImage: 'https://example.com/preview.png',
      blurredThumbnail: 'remote-sketch-thumbnail',
    );

    NoteSyncService.discardRemoteAttachmentPresentation(
      NoteAttachment.image(image),
    );
    NoteSyncService.discardRemoteAttachmentPresentation(
      NoteAttachment.sketch(sketch),
    );

    expect(image.blurredThumbnail, isNull);
    expect(sketch.previewImage, isNull);
    expect(sketch.blurredThumbnail, isNull);
  });

  test('classifies PIN protection before the E2EE heuristic', () async {
    final plaintext = Uint8List.fromList(List<int>.generate(80, (i) => i));
    final pinProtected = await encryptBytesWithPassword(plaintext, '2468');
    final e2eeWrapped = await FileEncryption.encryptBytes(
      pinProtected,
      Uint8List.fromList(List<int>.filled(32, 7)),
    );

    expect(
      classifyAttachmentCiphertext(pinProtected),
      AttachmentCiphertextKind.passwordProtected,
    );
    expect(
      classifyAttachmentCiphertext(e2eeWrapped),
      AttachmentCiphertextKind.e2ee,
    );
    expect(
      classifyAttachmentCiphertext(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
      ),
      AttachmentCiphertextKind.plaintext,
    );
  });

  test('last-good sketch preview requires the same tracked stroke source', () {
    final incoming = SketchData(
      backgroundImage: 'https://example.com/background.jpg',
      strokesFilePath: '/new/strokes.json',
      strokesContentHash: 'same-hash',
      aspectRatio: 4 / 3,
    );
    final previous = NoteAttachment.sketch(
      SketchData(
        backgroundImage: '/old/background.jpg',
        strokesFilePath: '/old/strokes.json',
        strokesContentHash: 'same-hash',
        previewImage: '/old/preview.jpg',
        blurredThumbnail: 'blurred',
        aspectRatio: 4 / 3,
      ),
    );

    expect(
      NoteSyncService.canRetainLastGoodSketchPreview(
        incoming: incoming,
        previousAttachment: previous,
        incomingStrokesRemotePath: 'https://example.com/strokes.json',
        trackedStrokesRemotePath: 'https://example.com/strokes.json',
        previewExists: true,
      ),
      isTrue,
    );
    expect(
      NoteSyncService.canRetainLastGoodSketchPreview(
        incoming: incoming,
        previousAttachment: previous,
        incomingStrokesRemotePath: 'https://example.com/strokes.json',
        trackedStrokesRemotePath: 'https://example.com/other.json',
        previewExists: true,
      ),
      isFalse,
    );

    expect(incoming.backgroundImage, 'https://example.com/background.jpg');
    expect(incoming.aspectRatio, 4 / 3);
  });
}
