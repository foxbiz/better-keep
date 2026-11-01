import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../async_keyed_serializer.dart';

abstract interface class StorageAccessCache {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> value);
  Future<void> clear();
}

/// Native keychain/keystore only. Web sessions never touch persistent storage.
/// Operations on the same key are serialized across replacement session objects,
/// so a retiring session cannot leave a late write behind after its clear.
class SecureStorageAccessCache implements StorageAccessCache {
  SecureStorageAccessCache({
    required String namespace,
    required String uid,
    required String deviceId,
    required String libraryId,
    required String provider,
    required int generation,
    required this.isCurrent,
    FlutterSecureStorage? storage,
    this.persistent = !kIsWeb,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock,
             ),
           ),
       _key =
           '$namespace.${sha256.convert(utf8.encode(jsonEncode([uid, deviceId, libraryId, provider, generation])))}';

  final FlutterSecureStorage _storage;
  final String _key;
  final bool persistent;
  final bool Function() isCurrent;
  static final _operations = AsyncKeyedSerializer<String>();

  @override
  Future<Map<String, dynamic>?> read() async {
    if (!persistent || kIsWeb) return null;
    return _operations.run(_key, () async {
      if (!isCurrent()) return null;
      final value = await _storage.read(key: _key);
      if (!isCurrent() || value == null) return null;
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    });
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (!persistent || kIsWeb) return;
    final encoded = jsonEncode(value);
    await _operations.run(_key, () async {
      if (!isCurrent()) return;
      await _storage.write(key: _key, value: encoded);
      if (!isCurrent()) await _storage.delete(key: _key);
    });
  }

  @override
  Future<void> clear() async {
    if (!persistent || kIsWeb) return;
    await _operations.run(_key, () => _storage.delete(key: _key));
  }
}
