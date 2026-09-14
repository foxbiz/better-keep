import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restores approved keys using only local reads', () async {
    final calls = <String>[];
    expect(
      await readLocalEncryption(
        hasDeviceKeys: () async {
          calls.add('device-keys');
          return true;
        },
        readDeviceStatus: () async {
          calls.add('approval');
          return 'approved';
        },
        loadKey: () async {
          calls.add('load-key');
          return true;
        },
        isCurrent: () => true,
      ),
      LocalEncryptionState.ready,
    );
    expect(calls, ['approval', 'device-keys', 'load-key']);
  });

  test('missing, pending and revoked approval never load a key', () async {
    for (final status in [null, 'pending', 'revoked', 'needs_recovery']) {
      expect(
        await readLocalEncryption(
          hasDeviceKeys: () async => true,
          readDeviceStatus: () async => status,
          loadKey: () async => throw StateError('must not load'),
          isCurrent: () => true,
        ),
        isNot(LocalEncryptionState.ready),
      );
    }
    expect(
      await readLocalEncryption(
        hasDeviceKeys: () async => true,
        readDeviceStatus: () async => 'approved',
        loadKey: () async => false,
        isCurrent: () => true,
      ),
      isNot(LocalEncryptionState.ready),
    );
  });

  test(
    'account change during storage read cannot unlock another session',
    () async {
      var current = true;
      final result = readLocalEncryption(
        hasDeviceKeys: () async => true,
        readDeviceStatus: () async {
          current = false;
          return 'approved';
        },
        loadKey: () async => throw StateError('must not load'),
        isCurrent: () => current,
      );
      expect(await result, LocalEncryptionState.stale);
    },
  );

  test(
    'cache misses and pending writes are never authoritative revocation',
    () {
      for (final cached in [true, false]) {
        for (final pending in [true, false]) {
          expect(
            isAuthoritativeDeviceSnapshot(
              isFromCache: cached,
              hasPendingWrites: pending,
            ),
            !cached && !pending,
          );
        }
      }
    },
  );
}
