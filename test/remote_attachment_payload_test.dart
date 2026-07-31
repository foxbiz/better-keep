import 'package:better_keep/services/remote_attachment_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing attachment payload is legacy-compatible', () {
    expect(parseRemoteAttachmentPayload(null), isEmpty);
  });

  test('accepts native and JSON attachment lists', () {
    const attachment = {'id': 'attachment-1', 'type': 'image'};
    expect(parseRemoteAttachmentPayload([attachment]), [attachment]);
    expect(
      parseRemoteAttachmentPayload('[{"id":"attachment-1","type":"image"}]'),
      [attachment],
    );
  });

  test('parses every valid attachment before content processing', () {
    final attachments = parseRemoteNoteAttachments([
      {
        'type': 'audio',
        'data': {'src': 'gs://bucket/audio.m4a', 'length': 3},
      },
    ]);

    expect(attachments, hasLength(1));
    expect(attachments.single.recording?.src, 'gs://bucket/audio.m4a');
  });

  test('rejects structurally valid attachment maps with invalid fields', () {
    expect(
      () => parseRemoteNoteAttachments([
        {'type': 'unknown', 'data': <String, dynamic>{}},
      ]),
      throwsA(
        isA<RemoteAttachmentPayloadException>().having(
          (error) => error.code,
          'code',
          'invalid-attachment-entry',
        ),
      ),
    );
  });

  for (final value in <Object>[
    '{malformed',
    '{"id":"attachment-1"}',
    'null',
    [1],
  ]) {
    test('rejects invalid attachment payload $value', () {
      expect(
        () => parseRemoteAttachmentPayload(value),
        throwsA(isA<RemoteAttachmentPayloadException>()),
      );
    });
  }
}
