import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncCipher cipher;
  setUp(
    () async => cipher = await SyncCipher.create(
      'user',
      Uint8List.fromList(List.filled(32, 1)),
    ),
  );
  tearDown(() => cipher.dispose());
  const credentials = {
    'refreshToken': 'private-refresh',
    'accountLabel': 'private@example.com',
  };
  Future<String> seal() => cipher.encryptCredentials(
    provider: 'google_drive',
    generation: 3,
    clientId: 'client',
    credentials: credentials,
  );
  test(
    'randomized ciphertext restores across devices using the same master key',
    () async {
      final first = await seal();
      final second = await seal();
      expect(first, isNot(second));
      expect(first, isNot(contains('private')));
      final otherDevice = await SyncCipher.create(
        'user',
        Uint8List.fromList(List.filled(32, 1)),
      );
      addTearDown(otherDevice.dispose);
      expect(
        await otherDevice.decryptCredentials(
          provider: 'google_drive',
          generation: 3,
          clientId: 'client',
          encrypted: first,
        ),
        credentials,
      );
    },
  );
  test(
    'rejects wrong provider, client, generation, user, key and tampering',
    () async {
      final encrypted = await seal();
      for (final context in [
        ('dropbox', 3, 'client'),
        ('google_drive', 4, 'client'),
        ('google_drive', 3, 'other'),
      ]) {
        await expectLater(
          cipher.decryptCredentials(
            provider: context.$1,
            generation: context.$2,
            clientId: context.$3,
            encrypted: encrypted,
          ),
          throwsA(anything),
        );
      }
      for (final context in [('other-user', 1), ('user', 2)]) {
        final wrong = await SyncCipher.create(
          context.$1,
          Uint8List.fromList(List.filled(32, context.$2)),
        );
        addTearDown(wrong.dispose);
        await expectLater(
          wrong.decryptCredentials(
            provider: 'google_drive',
            generation: 3,
            clientId: 'client',
            encrypted: encrypted,
          ),
          throwsA(anything),
        );
      }
      final bytes = base64Decode(encrypted);
      bytes[bytes.length - 1] ^= 1;
      await expectLater(
        cipher.decryptCredentials(
          provider: 'google_drive',
          generation: 3,
          clientId: 'client',
          encrypted: base64Encode(bytes),
        ),
        throwsA(anything),
      );
    },
  );
  test('credentials and capabilities cannot be interchanged; disposed keys cannot be used', () async {
    final capability = await cipher.encryptCapability(
      'google_drive',
      SyncCipher.newCapability(),
    );
    await expectLater(
      cipher.decryptCredentials(
        provider: 'google_drive',
        generation: 3,
        clientId: 'client',
        encrypted: capability,
      ),
      throwsA(anything),
    );
    cipher.dispose();
    await expectLater(seal(), throwsStateError);
  });
}
