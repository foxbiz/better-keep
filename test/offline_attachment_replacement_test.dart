import 'dart:async';
import 'dart:io';

import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/attachment_storage_repository.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/offline_firebase.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database database;
  late Directory directory;
  late File original;
  late FileSyncTrack track;
  late _Storage storage;
  const remote = 'gs://offline-test.invalid/notes/attachment.bin';
  final originalBytes = Uint8List.fromList([1, 2, 3]);
  final replacementBytes = Uint8List.fromList([4, 5, 6]);
  final note = Note(id: 101);

  setUp(() async {
    OfflineFirebase().configure();
    directory = await Directory.systemTemp.createTemp('offline-attachment-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppState.db = database;
    await FileSyncTrack.createTable(database);
    original = File('${directory.path}/downloaded.bin');
    await original.writeAsBytes(originalBytes);
    track = FileSyncTrack(
      noteId: 101,
      localPath: original.path,
      remotePath: remote,
      contentHash: FileSyncTrack.computeHash(originalBytes),
    );
    await track.save();
    storage = _Storage();
    NoteSyncService.attachmentStorageOverride = storage;
  });
  tearDown(() async {
    NoteSyncService.attachmentStorageOverride = null;
    await database.close();
    await directory.delete(recursive: true);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    FirebaseBackend.resetForTesting();
  });

  Future<FileDownloadResult> replace() =>
      NoteSyncService().downloadFileForTesting(
        remote,
        note,
        expectedContentHash: FileSyncTrack.computeHash(replacementBytes),
      );

  test(
    'failed replacement preserves downloaded bytes and the old tracking row',
    () async {
      storage.downloadResponse = () =>
          Future.error(TimeoutException('offline'));
      await expectLater(replace(), throwsA(isA<TimeoutException>()));
      expect(await original.readAsBytes(), originalBytes);
      final retained = await FileSyncTrack.getByRemotePath(remote);
      expect(retained?.id, track.id);
      expect(retained?.localPath, original.path);
      expect(retained?.contentHash, track.contentHash);
    },
  );

  test(
    'uncommitted replacement retains its mapping and removes staged bytes',
    () async {
      storage.downloadResponse = () async => replacementBytes;
      final result = await replace();
      expect(result.isSuccess, isTrue);
      expect(await File(result.localPath!).exists(), isFalse);
      expect(await original.readAsBytes(), originalBytes);
      final replacement = await FileSyncTrack.getByRemotePath(remote);
      expect(replacement?.id, track.id);
      expect(replacement?.localPath, original.path);
      expect(await FileSyncTrack.get(noteId: 101), hasLength(1));
    },
  );

  test(
    'late download from a superseded session cannot replace the mapping',
    () async {
      var current = true;
      final response = Completer<Uint8List?>();
      final started = Completer<void>();
      storage.downloadResponse = () {
        started.complete();
        return response.future;
      };
      final operation = runCloudOperation(() => current, replace);
      await started.future;
      current = false;
      response.complete(replacementBytes);
      await expectLater(operation, throwsA(isA<CloudOperationCancelled>()));
      expect(
        (await FileSyncTrack.getByRemotePath(remote))?.localPath,
        original.path,
      );
      expect(await original.readAsBytes(), originalBytes);
    },
  );
}

class _Storage extends AttachmentStorageRepository {
  Future<Uint8List?> Function()? downloadResponse;
  @override
  StorageObjectLocator parse(String locator) => StorageObjectLocator.parse(
    locator,
    configuredBucket: 'offline-test.invalid',
    emulatorMode: false,
  );
  @override
  Future<Uint8List?> download(String locator) => downloadResponse!();
}
