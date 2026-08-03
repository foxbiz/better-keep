import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'oauth_transaction_store_native.dart'
    if (dart.library.html) 'oauth_transaction_store_web.dart'
    as transaction_store;

const _transactionLifetime = Duration(minutes: 5);
final _transactionIdPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _verifierPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
const _providers = {'facebook', 'github', 'twitter'};
const _modes = {'signin', 'link'};

String _randomBase64Url(int length) {
  final random = Random.secure();
  final bytes = List<int>.generate(length, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

class OAuthTransaction {
  const OAuthTransaction({
    required this.id,
    required this.verifier,
    required this.provider,
    required this.mode,
    required this.createdAt,
  });

  factory OAuthTransaction.create({
    required String provider,
    required String mode,
  }) {
    return OAuthTransaction(
      id: _randomBase64Url(16),
      verifier: _randomBase64Url(32),
      provider: provider,
      mode: mode,
      createdAt: DateTime.now().toUtc(),
    );
  }

  factory OAuthTransaction.fromJson(Map<String, dynamic> json) {
    return OAuthTransaction(
      id: json['id'] as String,
      verifier: json['verifier'] as String,
      provider: json['provider'] as String,
      mode: json['mode'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }

  final String id;
  final String verifier;
  final String provider;
  final String mode;
  final DateTime createdAt;

  String get challenge => base64UrlEncode(
    sha256.convert(utf8.encode(verifier)).bytes,
  ).replaceAll('=', '');

  bool get isExpired =>
      DateTime.now().toUtc().difference(createdAt) >= _transactionLifetime;

  bool get isWellFormed =>
      _transactionIdPattern.hasMatch(id) &&
      _verifierPattern.hasMatch(verifier) &&
      _providers.contains(provider) &&
      _modes.contains(mode) &&
      !createdAt.isAfter(
        DateTime.now().toUtc().add(const Duration(seconds: 30)),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'verifier': verifier,
    'provider': provider,
    'mode': mode,
    'createdAt': createdAt.toIso8601String(),
  };
}

Future<OAuthTransaction> createOAuthTransaction({
  required String provider,
  required String mode,
}) async {
  await purgeExpiredOAuthTransactions();
  final transaction = OAuthTransaction.create(provider: provider, mode: mode);
  await transaction_store.writeOAuthTransaction(
    transaction.id,
    jsonEncode(transaction.toJson()),
  );
  return transaction;
}

Future<OAuthTransaction?> readOAuthTransaction(String id) async {
  final encoded = await transaction_store.readOAuthTransaction(id);
  if (encoded == null) return null;
  try {
    final transaction = OAuthTransaction.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
    if (transaction.id != id ||
        !transaction.isWellFormed ||
        transaction.isExpired) {
      await removeOAuthTransaction(id);
      return null;
    }
    return transaction;
  } catch (_) {
    await removeOAuthTransaction(id);
    return null;
  }
}

Future<void> removeOAuthTransaction(String id) =>
    transaction_store.removeOAuthTransaction(id);

/// Removes pending OAuth state only from the active Firebase environment.
///
/// Each platform store lists only the prefix derived from the committed
/// backend, so transactions owned by the inactive environment are preserved.
Future<void> clearActiveOAuthTransactions() async {
  final ids = await transaction_store.listOAuthTransactionIds();
  await Future.wait(ids.map(transaction_store.removeOAuthTransaction));
}

Future<void> purgeExpiredOAuthTransactions() async {
  final ids = await transaction_store.listOAuthTransactionIds();
  await Future.wait(ids.map(readOAuthTransaction));
}
