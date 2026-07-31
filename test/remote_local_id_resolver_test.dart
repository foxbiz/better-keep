import 'package:better_keep/services/remote_local_id_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<int> resolve({
    int? tracked,
    int? stable,
    int? reserved,
    int? suggested,
    Set<int> unavailable = const {},
  }) {
    return resolveRemoteLocalId(
      trackedLocalId: tracked,
      stableNoteLocalId: stable,
      reservedLocalId: reserved,
      suggestedLocalId: suggested,
      isAvailable: (candidate) async => !unavailable.contains(candidate),
      allocateCandidate: () => 1000,
    );
  }

  test('existing remote track and note mappings are authoritative', () async {
    expect(
      await resolve(
        tracked: 11,
        stable: 12,
        reserved: 13,
        suggested: 14,
        unavailable: {11, 12, 13, 14},
      ),
      11,
    );
    expect(
      await resolve(
        stable: 12,
        reserved: 13,
        suggested: 14,
        unavailable: {12, 13, 14},
      ),
      12,
    );
  });

  test(
    'durable ledger reservation is preferred after failed persistence',
    () async {
      expect(await resolve(reserved: 42, suggested: 99), 42);
    },
  );

  test(
    'suggested ID collisions allocate the first available local ID',
    () async {
      expect(await resolve(suggested: 42, unavailable: {42, 1000, 1001}), 1002);
    },
  );

  test('another active reservation makes an ID unavailable', () async {
    expect(await resolve(reserved: 77, suggested: 88, unavailable: {77}), 88);
  });
}
