import 'package:better_keep/services/connected_provider_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unlinks a Firebase-backed provider after clearing metadata', () async {
    final events = <String>[];

    await unlinkConnectedProvider(
      providerId: 'apple.com',
      firebaseProviderIds: const ['password', 'apple.com'],
      removeMetadata: () async {
        events.add('metadata');
      },
      clearCachedProvider: () {
        events.add('cache');
      },
      unlinkFirebaseProvider: (providerId) async {
        events.add('firebase:$providerId');
      },
    );

    expect(events, ['metadata', 'cache', 'firebase:apple.com']);
  });

  test('keeps Firestore-only providers out of Firebase unlinking', () async {
    final events = <String>[];

    await unlinkConnectedProvider(
      providerId: 'github.com',
      firebaseProviderIds: const ['password'],
      removeMetadata: () async {
        events.add('metadata');
      },
      clearCachedProvider: () {
        events.add('cache');
      },
      unlinkFirebaseProvider: (providerId) async {
        events.add('firebase:$providerId');
      },
    );

    expect(events, ['metadata', 'cache']);
  });

  test('does not unlink Firebase when metadata removal fails', () async {
    var cacheCleared = false;
    var firebaseUnlinked = false;

    await expectLater(
      unlinkConnectedProvider(
        providerId: 'apple.com',
        firebaseProviderIds: const ['apple.com'],
        removeMetadata: () async {
          throw StateError('metadata failed');
        },
        clearCachedProvider: () {
          cacheCleared = true;
        },
        unlinkFirebaseProvider: (_) async {
          firebaseUnlinked = true;
        },
      ),
      throwsStateError,
    );

    expect(cacheCleared, isFalse);
    expect(firebaseUnlinked, isFalse);
  });
}
