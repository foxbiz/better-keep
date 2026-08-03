import 'package:better_keep/services/firebase_backend.dart';
import 'package:web/web.dart' as web;

String get _prefix => FirebaseBackend.localDataScope.secureStorageKey(
  'betterkeep.oauth.pending.',
);

Future<void> writeOAuthTransaction(String id, String value) async {
  web.window.sessionStorage.setItem('$_prefix$id', value);
}

Future<String?> readOAuthTransaction(String id) async {
  return web.window.sessionStorage.getItem('$_prefix$id');
}

Future<void> removeOAuthTransaction(String id) async {
  web.window.sessionStorage.removeItem('$_prefix$id');
}

Future<List<String>> listOAuthTransactionIds() async {
  final storage = web.window.sessionStorage;
  final ids = <String>[];
  for (var index = 0; index < storage.length; index += 1) {
    final key = storage.key(index);
    if (key != null && key.startsWith(_prefix)) {
      ids.add(key.substring(_prefix.length));
    }
  }
  return ids;
}
