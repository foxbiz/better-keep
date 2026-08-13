import 'dart:typed_data';

import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/e2ee/note_encryption.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'background verification permits local access but requires a UMK for sync',
    () {
      expect(
        e2eeStatusCanAccessLocalNotes(E2EEStatus.verifyingInBackground),
        isTrue,
      );
      expect(
        e2eeStatusIsCryptoReady(
          E2EEStatus.verifyingInBackground,
          hasUMK: false,
        ),
        isFalse,
      );
      expect(
        e2eeStatusIsCryptoReady(E2EEStatus.verifyingInBackground, hasUMK: true),
        isTrue,
      );
      expect(
        e2eeStatusIsCryptoReady(E2EEStatus.pendingApproval, hasUMK: true),
        isFalse,
      );
    },
  );

  test('outgoing sync fails closed before writes when the UMK is absent', () {
    expect(
      () => requireSyncEncryptionKey(cryptoReady: false, umk: null),
      throwsA(isA<SyncEncryptionUnavailable>()),
    );
  });

  test(
    'loss or replacement of a captured UMK leaves outgoing work pending',
    () {
      final captured = Uint8List.fromList(List<int>.generate(32, (i) => i));

      expect(
        () => validateCapturedSyncEncryptionKey(
          cryptoReady: false,
          captured: captured,
          current: null,
        ),
        throwsA(isA<SyncEncryptionUnavailable>()),
      );
      expect(
        () => validateCapturedSyncEncryptionKey(
          cryptoReady: true,
          captured: captured,
          current: Uint8List(32),
        ),
        throwsA(isA<SyncEncryptionUnavailable>()),
      );
    },
  );

  test(
    'standard note encryption emits ciphertext without plaintext fields',
    () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final encrypted = await NoteEncryptionService.instance.encryptNoteWithKey(
        title: 'private title',
        content: 'private content',
        umk: key,
      );
      final payload = encrypted.toFirestore();

      expect(payload['e2ee_ciphertext'], isNotEmpty);
      expect(payload.containsValue('private title'), isFalse);
      expect(payload.containsValue('private content'), isFalse);
      expect(payload.containsKey('title'), isFalse);
      expect(payload.containsKey('content'), isFalse);
    },
  );
}
