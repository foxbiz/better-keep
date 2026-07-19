import 'dart:typed_data';

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authenticated image decode leaves the canonical ENCP bytes intact',
    () async {
      final plaintext = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
      final protected = await encryptBytesWithPassword(plaintext, '2468');
      final canonical = Uint8List.fromList(protected);
      Uint8List? decoderInput;

      final resolved = await UniversalImage.prepareImageBytes(
        protected,
        passwordProtectedDecoder: (bytes) async {
          decoderInput = Uint8List.fromList(bytes);
          return decryptBytesWithPassword(bytes, '2468');
        },
      );

      expect(decoderInput, protected);
      expect(resolved, plaintext);
      expect(protected, canonical);
      expect(isBytesPasswordEncrypted(protected), isTrue);
    },
  );

  test(
    'protected image bytes fail before reaching Flutter without a session',
    () async {
      final protected = await encryptBytesWithPassword(
        Uint8List.fromList([1, 2, 3]),
        '2468',
      );

      await expectLater(
        UniversalImage.prepareImageBytes(protected),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('plaintext image bytes do not invoke the protected decoder', () async {
    final plaintext = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

    final resolved = await UniversalImage.prepareImageBytes(
      plaintext,
      passwordProtectedDecoder: (_) async =>
          throw StateError('decoder must not be called'),
    );

    expect(resolved, plaintext);
  });
}
