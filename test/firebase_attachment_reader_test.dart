import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/external_sync/firebase_attachment_reader.dart';
import 'package:better_keep/services/external_sync/sync_replica_engine.dart';
import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  const source = 'gs://test-bucket/users/user/notes/note/file.png';
  late _Storage storage;
  late Uint8List key;
  late FirebaseAttachmentReader reader;
  late Database db;
  Object? localError;
  var current = true;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await FileSyncTrack.createTable(db);
    localError = null;
    current = true;
    key = Uint8List.fromList(List.filled(32, 7));
    storage = _Storage();
    reader = FirebaseAttachmentReader(
      uid: 'user',
      database: db,
      storage: storage,
      readLocal: (_) async {
        if (localError != null) throw localError!;
        return Uint8List.fromList([9]);
      },
      readKey: () => key,
      isCurrent: () => current,
    );
  });
  tearDown(() => db.close());

  Future<void> track({String? hash, String remote = source}) => db
      .insert('file_sync_track', {
        'note_id': 1,
        'local_path': '/app/file.png',
        'remote_path': remote,
        'content_hash': hash,
      })
      .then((_) {});

  test('missing local source recovers verified PIN bytes without rewriting the mapping', () async {
    final pin = Uint8List.fromList([69, 78, 67, 80, ...List.filled(60, 5)]);
    await track(hash: FileSyncTrack.computeHash(pin));
    final before = await db.query('file_sync_track');
    localError = const SyncAttachmentMissing('/app/file.png');
    storage.bytes = await FileEncryption.encryptBytes(pin, key);
    expect(await reader.read('/old-container/file.png'), pin);
    expect(await db.query('file_sync_track'), before);
  });

  test('changed remote bytes never replace a missing mapped source', () async {
    await track(hash: FileSyncTrack.computeHash(Uint8List.fromList([1])));
    localError = const SyncAttachmentMissing('/app/file.png');
    storage.bytes = Uint8List.fromList([2]);
    await expectLater(reader.read('/app/file.png'), throwsFormatException);
  });

  test(
    'unverified or conflicting mappings stay pending without a download',
    () async {
      localError = const SyncAttachmentMissing('/app/file.png');
      await track();
      await expectLater(
        reader.read('/app/file.png'),
        throwsA(isA<SyncAttachmentMissing>()),
      );
      await track(hash: FileSyncTrack.computeHash(Uint8List.fromList([1])));
      await expectLater(
        reader.read('/app/file.png'),
        throwsA(isA<SyncAttachmentMissing>()),
      );
      expect(storage.downloads, 0);
    },
  );

  test(
    'a mapping cannot bypass local protection or account ownership',
    () async {
      await track(
        hash: FileSyncTrack.computeHash(Uint8List.fromList([1])),
        remote: 'gs://test-bucket/users/other/notes/n/file.png',
      );
      localError = const FormatException('Cannot decrypt local file');
      await expectLater(reader.read('/app/file.png'), throwsFormatException);
      localError = const SyncAttachmentMissing('/app/file.png');
      await expectLater(reader.read('/app/file.png'), throwsFormatException);
      expect(storage.downloads, 0);
    },
  );

  test('removes account encryption while retaining opaque PIN bytes', () async {
    final pin = Uint8List.fromList([69, 78, 67, 80, ...List.filled(60, 5)]);
    storage.bytes = await FileEncryption.encryptBytes(pin, key);
    expect(await reader.read(source), pin);
    expect(key, List.filled(32, 7)); // The borrowed UMK is never zeroed.
    storage.bytes = pin;
    expect(await reader.read(source), pin);
  });

  test('a media-like random nonce must still be decrypted', () async {
    final plaintext = Uint8List.fromList([1, 2, 3, 4]);
    final nonce = [137, 80, 78, 71, ...List.filled(20, 0)];
    final box = await Xchacha20.poly1305Aead().encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    storage.bytes = Uint8List.fromList(box.concatenation());
    expect(FileEncryption.looksEncrypted(storage.bytes!), false);
    expect(await reader.read(source), plaintext);
  });

  test('legacy plaintext and local files remain readable', () async {
    storage.bytes = Uint8List.fromList([
      137,
      80,
      78,
      71,
      ...List.filled(60, 1),
    ]);
    expect(await reader.read(source), storage.bytes);
    expect(await reader.read('/app/file.png'), [9]);
    expect(storage.downloads, 1);
  });

  test(
    'rejects other accounts, buckets and arbitrary hosts before downloading',
    () async {
      for (final url in [
        'gs://test-bucket/users/other/notes/n/file.png',
        'gs://other-bucket/users/user/notes/n/file.png',
        'https://other.invalid/v0/b/test-bucket/o/users%2Fuser%2Fnotes%2Fn%2Ffile.png',
      ]) {
        await expectLater(reader.read(url), throwsA(isA<Exception>()));
      }
      expect(storage.downloads, 0);
    },
  );

  test(
    'missing sources and failed authentication cannot become portable bytes',
    () async {
      await expectLater(reader.read(source), throwsFormatException);
      storage.bytes = Uint8List(0);
      await expectLater(reader.read(source), throwsFormatException);
      storage.bytes = await FileEncryption.encryptBytes(
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList(List.filled(32, 8)),
      );
      await expectLater(reader.read(source), throwsA(isA<Exception>()));
    },
  );

  test('session replacement rejects a download already in flight', () async {
    final pending = Completer<Uint8List?>();
    storage.pending = pending.future;
    final result = reader.read(source);
    final assertion = expectLater(result, throwsA(isA<SyncReplicaCancelled>()));
    current = false;
    pending.complete(Uint8List.fromList([1, 2, 3]));
    await assertion;
    await expectLater(
      reader.read(source),
      throwsA(isA<SyncReplicaCancelled>()),
    );
    expect(storage.downloads, 1);
  });
}

class _Storage extends AttachmentStorageRepository {
  Uint8List? bytes;
  Future<Uint8List?>? pending;
  int downloads = 0;
  @override
  StorageObjectLocator parse(String locator) => StorageObjectLocator.parse(
    locator,
    configuredBucket: 'test-bucket',
    emulatorMode: false,
  );
  @override
  Future<Uint8List?> download(String locator) async {
    downloads++;
    if (pending != null) return await pending;
    return bytes;
  }
}
