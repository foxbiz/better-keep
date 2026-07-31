import 'dart:io';

import 'package:better_keep/services/firebase_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(FirebaseBackend.resetForTesting);

  test('Firebase services are unavailable before backend selection', () {
    FirebaseBackend.resetForTesting();

    expect(() => FirebaseBackend.active, throwsStateError);
    expect(() => FirebaseBackend.auth, throwsStateError);
    expect(() => FirebaseBackend.firestore, throwsStateError);
    expect(() => FirebaseBackend.storage, throwsStateError);
    expect(() => FirebaseBackend.functions(), throwsStateError);
  });

  test('emulator app names are deterministic and host-specific', () {
    final first = FirebaseBackend.emulatorAppNameFor('192.168.1.25');
    final repeated = FirebaseBackend.emulatorAppNameFor('192.168.1.25');
    final anotherHost = FirebaseBackend.emulatorAppNameFor('127.0.0.1');

    expect(first, repeated);
    expect(first, startsWith('better-keep-emulator-'));
    expect(first, isNot(anotherHost));
  });

  test('Live keeps legacy local names while Emulator is isolated', () {
    expect(FirebaseLocalDataScope.live.databaseName, 'better_keep.db');
    expect(FirebaseLocalDataScope.live.preferenceKey('user_uid'), 'user_uid');
    expect(
      FirebaseLocalDataScope.live.secureStorageKey('e2ee_device_id'),
      'e2ee_device_id',
    );

    expect(
      FirebaseLocalDataScope.emulator.databaseName,
      'better_keep_emulator.db',
    );
    expect(
      FirebaseLocalDataScope.emulator.preferenceKey('user_uid'),
      'firebase_emulator.user_uid',
    );
    expect(
      FirebaseLocalDataScope.emulator.secureStorageKey('e2ee_device_id'),
      'firebase_emulator.e2ee_device_id',
    );
    expect(
      FirebaseLocalDataScope.live.secureStorageKey('betterkeep.oauth.pending.'),
      'betterkeep.oauth.pending.',
    );
    expect(
      FirebaseLocalDataScope.emulator.secureStorageKey(
        'betterkeep.oauth.pending.',
      ),
      'firebase_emulator.betterkeep.oauth.pending.',
    );
    expect(
      FirebaseLocalDataScope.emulator.fileDirectoryName,
      'firebase_emulator',
    );
  });

  test(
    'production code obtains Firebase service instances only from backend',
    () {
      final violations = <String>[];
      final forbidden = RegExp(
        r'\bFirebase(?:Auth|Functions|Firestore|Storage)\.'
        r'(?:instance|instanceFor)\b|\bFirebase\.app\(',
      );

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('firebase_backend.dart')) continue;

        final lines = entity.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final line = lines[index].trimLeft();
          if (line.startsWith('//') || line.startsWith('*')) continue;
          if (forbidden.hasMatch(line)) {
            violations.add(
              '${entity.path}:${index + 1}: ${lines[index].trim()}',
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Route Firebase through FirebaseBackend:\n'
            '${violations.join('\n')}',
      );
    },
  );
}
