import 'package:better_keep/services/oauth_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OAuth transaction uses correctly sized random correlation values', () {
    final first = OAuthTransaction.create(provider: 'github', mode: 'signin');
    final second = OAuthTransaction.create(provider: 'github', mode: 'signin');

    expect(first.id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(first.verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(first.challenge, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(first.id, isNot(second.id));
    expect(first.verifier, isNot(second.verifier));
  });

  test('OAuth transaction round-trips without exposing derived state', () {
    final transaction = OAuthTransaction.create(
      provider: 'twitter',
      mode: 'link',
    );
    final decoded = OAuthTransaction.fromJson(transaction.toJson());

    expect(decoded.id, transaction.id);
    expect(decoded.verifier, transaction.verifier);
    expect(decoded.provider, 'twitter');
    expect(decoded.mode, 'link');
    expect(decoded.challenge, transaction.challenge);
    expect(decoded.isExpired, isFalse);
  });

  test('expired OAuth transactions are rejected by their lifetime policy', () {
    final transaction = OAuthTransaction(
      id: List.filled(22, 'a').join(),
      verifier: List.filled(43, 'b').join(),
      provider: 'github',
      mode: 'signin',
      createdAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6)),
    );

    expect(transaction.isExpired, isTrue);
  });

  test('stored transaction fields are validated before redemption', () {
    final valid = OAuthTransaction.create(provider: 'github', mode: 'signin');
    expect(valid.isWellFormed, isTrue);
    expect(
      OAuthTransaction(
        id: 'invalid',
        verifier: valid.verifier,
        provider: valid.provider,
        mode: valid.mode,
        createdAt: valid.createdAt,
      ).isWellFormed,
      isFalse,
    );
    expect(
      OAuthTransaction(
        id: valid.id,
        verifier: valid.verifier,
        provider: 'google',
        mode: valid.mode,
        createdAt: valid.createdAt,
      ).isWellFormed,
      isFalse,
    );
  });
}
