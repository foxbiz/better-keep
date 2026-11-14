import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/srp/srp6_client.dart';
import 'package:pointycastle/srp/srp6_server.dart';
import 'package:pointycastle/srp/srp6_standard_groups.dart';
import 'package:pointycastle/srp/srp6_verifier_generator.dart';

Uint8List bytes(String x) => Uint8List.fromList(x.codeUnits);
SecureRandom rng() => FortunaRandom()
  ..seed(
    KeyParameter(
      Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      ),
    ),
  );
void main() {
  final group = SRP6StandardGroups.rfc5054_3072;
  final salt = Uint8List.fromList(List.generate(32, (i) => i));
  (SRP6Client, SRP6Server) peers({
    String code = '01234567',
    String identity = 'request-a',
  }) {
    final verifier = SRP6VerifierGenerator(
      group: group,
      digest: SHA256Digest(),
    ).generateVerifier(salt, bytes('request-a'), bytes('01234567'));
    final client = SRP6Client(
      group: group,
      digest: SHA256Digest(),
      random: rng(),
    );
    final server = SRP6Server(
      group: group,
      v: verifier,
      digest: SHA256Digest(),
      random: rng(),
    );
    final a = client.generateClientCredentials(
      salt,
      bytes(identity),
      bytes(code),
    )!;
    final b = server.generateServerCredentials()!;
    client.calculateSecret(b);
    server.calculateSecret(a);
    return (client, server);
  }

  test('3072/SHA256 mutual evidence and session keys agree', () {
    final (client, server) = peers();
    expect(
      server.verifyClientEvidenceMessage(
        client.calculateClientEvidenceMessage()!,
      ),
      true,
    );
    expect(
      client.verifyServerEvidenceMessage(
        server.calculateServerEvidenceMessage()!,
      ),
      true,
    );
    expect(client.calculateSessionKey(), server.calculateSessionKey());
  });
  test('wrong code fails evidence', () {
    final (client, server) = peers(code: '01234568');
    expect(
      server.verifyClientEvidenceMessage(
        client.calculateClientEvidenceMessage()!,
      ),
      false,
    );
    expect(() => server.calculateServerEvidenceMessage(), throwsException);
  });
  test('substituted request identity fails evidence', () {
    final (client, server) = peers(identity: 'request-b');
    expect(
      server.verifyClientEvidenceMessage(
        client.calculateClientEvidenceMessage()!,
      ),
      false,
    );
  });
  test('forged server evidence cannot produce client session key', () {
    final (client, server) = peers();
    expect(
      server.verifyClientEvidenceMessage(
        client.calculateClientEvidenceMessage()!,
      ),
      true,
    );
    expect(client.verifyServerEvidenceMessage(BigInt.one), false);
    expect(() => client.calculateSessionKey(), throwsException);
  });
  test('zero and group modulus public values are rejected', () {
    for (final invalid in [BigInt.zero, group.N]) {
      final (client, server) = peers();
      expect(() => client.calculateSecret(invalid), throwsException);
      expect(() => server.calculateSecret(invalid), throwsException);
    }
  });
}
