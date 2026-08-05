import 'package:better_keep/services/firebase_backend.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _storage = FlutterSecureStorage();
String get _prefix => FirebaseBackend.localDataScope.secureStorageKey(
  'betterkeep.oauth.pending.',
);

Future<void> writeOAuthTransaction(String id, String value) {
  return _storage.write(key: '$_prefix$id', value: value);
}

Future<String?> readOAuthTransaction(String id) {
  return _storage.read(key: '$_prefix$id');
}

Future<void> removeOAuthTransaction(String id) {
  return _storage.delete(key: '$_prefix$id');
}

Future<List<String>> listOAuthTransactionIds() async {
  final values = await _storage.readAll();
  return values.keys
      .where((key) => key.startsWith(_prefix))
      .map((key) => key.substring(_prefix.length))
      .toList(growable: false);
}
