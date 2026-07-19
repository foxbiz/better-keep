import 'dart:typed_data';

import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'compression failure never writes or schedules source cleanup',
    () async {
      final files = _FakeImagePreparationFiles()..failCompression = true;
      final service = ImageAttachmentPreparationService(files.operations);

      await expectLater(
        service.prepare(
          sourceBytes: Uint8List.fromList([1, 2, 3]),
          extension: '.jpg',
          generateBlurredThumbnail: true,
        ),
        throwsStateError,
      );

      expect(files.writeCalls, 0);
      expect(files.cleanupCalls, 0);
      expect(files.data, isEmpty);
    },
  );

  test('decode failure happens before the source file is written', () async {
    final files = _FakeImagePreparationFiles()..failDecode = true;
    final service = ImageAttachmentPreparationService(files.operations);

    await expectLater(
      service.prepare(
        sourceBytes: Uint8List.fromList([1, 2, 3]),
        extension: '.png',
        generateBlurredThumbnail: true,
      ),
      throwsStateError,
    );

    expect(files.writeCalls, 0);
    expect(files.thumbnailCalls, 0);
    expect(files.cleanupCalls, 0);
  });

  test('thumbnail failure happens before the source file is written', () async {
    final files = _FakeImagePreparationFiles()..failThumbnail = true;
    final service = ImageAttachmentPreparationService(files.operations);

    await expectLater(
      service.prepare(
        sourceBytes: Uint8List.fromList([1, 2, 3]),
        extension: '.jpg',
        generateBlurredThumbnail: true,
      ),
      throwsStateError,
    );

    expect(files.writeCalls, 0);
    expect(files.cleanupCalls, 0);
  });

  test('partial write failure releases the caller-owned source', () async {
    final files = _FakeImagePreparationFiles()..failAfterPartialWrite = true;
    final service = ImageAttachmentPreparationService(files.operations);

    await expectLater(
      service.prepare(
        sourceBytes: Uint8List.fromList([4, 5, 6]),
        extension: '.webp',
        generateBlurredThumbnail: true,
      ),
      throwsStateError,
    );

    expect(files.writeCalls, 1);
    expect(files.cleanupCalls, 1);
    expect(files.data, isEmpty);
  });

  test('successful preparation preserves metadata and releases once', () async {
    final files = _FakeImagePreparationFiles();
    final service = ImageAttachmentPreparationService(files.operations);

    final prepared = await service.prepare(
      sourceBytes: Uint8List.fromList([7, 8, 9]),
      extension: 'heic',
      generateBlurredThumbnail: true,
    );

    expect(prepared.path, '/docs/generated-1.heic');
    expect(prepared.dimensions.width, 1200);
    expect(prepared.dimensions.height, 800);
    expect(prepared.byteLength, 3);
    expect(prepared.blurredThumbnail, 'tiny-thumbnail');
    expect(files.data[prepared.path], [7, 8, 9]);

    await prepared.release();
    await prepared.release();
    expect(files.cleanupCalls, 1);
    expect(files.data, isEmpty);
  });

  test('thumbnail generation remains disabled for home image notes', () async {
    final files = _FakeImagePreparationFiles();
    final service = ImageAttachmentPreparationService(files.operations);

    final prepared = await service.prepare(
      sourceBytes: Uint8List.fromList([1, 2]),
      extension: '.jpg',
      generateBlurredThumbnail: false,
    );

    expect(prepared.blurredThumbnail, isNull);
    expect(files.thumbnailCalls, 0);
    await prepared.release();
  });
}

class _FakeImagePreparationFiles {
  final Map<String, Uint8List> data = {};
  bool failCompression = false;
  bool failDecode = false;
  bool failThumbnail = false;
  bool failAfterPartialWrite = false;
  int writeCalls = 0;
  int cleanupCalls = 0;
  int thumbnailCalls = 0;
  int _id = 0;

  late final ImageAttachmentPreparationOperations operations =
      ImageAttachmentPreparationOperations(
        compress:
            (
              bytes, {
              required quality,
              required minWidth,
              required minHeight,
            }) async {
              if (failCompression) {
                throw StateError('injected compression failure');
              }
              return Uint8List.fromList(bytes);
            },
        decode: (bytes) async {
          if (failDecode) throw StateError('injected decode failure');
          return const ImageAttachmentDimensions(width: 1200, height: 800);
        },
        generateThumbnail: (bytes) async {
          thumbnailCalls++;
          if (failThumbnail) {
            throw StateError('injected thumbnail failure');
          }
          return 'tiny-thumbnail';
        },
        documentDirectory: () async => '/docs',
        write: (filePath, bytes) async {
          writeCalls++;
          data[filePath] = Uint8List.fromList(bytes);
          if (failAfterPartialWrite) {
            throw StateError('injected partial write failure');
          }
        },
        cleanup: (sourcePath) async {
          cleanupCalls++;
          data.remove(sourcePath);
        },
        newId: () => 'generated-${++_id}',
      );
}
