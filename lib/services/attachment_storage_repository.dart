import 'dart:typed_data';

import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/storage_object_locator.dart';
import 'package:firebase_storage/firebase_storage.dart';

class AttachmentStorageRepository {
  AttachmentStorageRepository({
    FirebaseStorage Function()? storage,
    bool Function()? emulatorMode,
  }) : _storage = storage ?? (() => FirebaseBackend.storage),
       _emulatorMode =
           emulatorMode ?? (() => FirebaseBackend.usesStorageEmulator);

  final FirebaseStorage Function() _storage;
  final bool Function() _emulatorMode;

  StorageObjectLocator parse(String locator) {
    final storage = _storage();
    return StorageObjectLocator.parse(
      locator,
      configuredBucket: storage.bucket,
      emulatorMode: _emulatorMode(),
    );
  }

  Reference reference(String locator) {
    final storage = _storage();
    return StorageObjectLocator.parse(
      locator,
      configuredBucket: storage.bucket,
      emulatorMode: _emulatorMode(),
    ).resolve(storage);
  }

  Future<Uint8List?> download(String locator) => reference(locator).getData();

  Future<FullMetadata> metadata(String locator) =>
      reference(locator).getMetadata();
}
