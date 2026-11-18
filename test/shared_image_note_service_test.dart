import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/services/intent_handler_service.dart';
import 'package:better_keep/services/shared_image_note_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sources;
  late _ImageImportHarness harness;

  setUp(() async {
    sources = await Directory.systemTemp.createTemp('shared_image_note_test');
    harness = _ImageImportHarness();
  });

  tearDown(() async => sources.delete(recursive: true));

  Future<SharedMediaFile> source(
    String name, {
    SharedMediaType type = SharedMediaType.image,
    String? mimeType,
    List<int> bytes = const [1, 2, 3],
  }) async {
    final file = File('${sources.path}/$name');
    await file.writeAsBytes(bytes);
    return SharedMediaFile(path: file.path, type: type, mimeType: mimeType);
  }

  test('single image is saved with an owned copy and image metadata', () async {
    final image = await source('photo.png');
    final note = await harness.service.create([image]);

    expect(harness.saved, [note]);
    expect(note.labels, Label.sharedFileLabelName);
    expect(note.images.single.src, '/documents/image-1.jpg');
    expect(note.images.single.src, isNot(image.path));
    expect(note.images.single.aspectRatio, '1200:800');
    expect(note.images.single.size, 3);
    expect(jsonDecode(note.content!), [
      {'insert': '\n'},
    ]);
    expect(harness.files.values.single, [1, 2, 3]);
    expect(harness.cleaned, isEmpty);
    expect(await File(image.path).readAsBytes(), [1, 2, 3]);
  });

  test('intent handler groups images and ignores deep links', () async {
    final images = [
      await source('photo.png'),
      await source(
        'no-extension',
        type: SharedMediaType.file,
        mimeType: 'image/jpeg',
      ),
      await source('PHOTO.WEBP', type: SharedMediaType.file),
    ];
    final opened = <Note>[];
    final handler = IntentHandlerService(
      imageNotes: harness.service,
      openImageNote: opened.add,
    );
    await handler.handleSharedFiles([
      ...images,
      SharedMediaFile(
        path: 'https://example.com/photo.jpg',
        type: SharedMediaType.image,
      ),
    ]);

    expect(harness.saved, hasLength(1));
    expect(opened, [harness.saved.single]);
    expect(harness.saved.single.images.map((image) => image.index), [0, 1, 2]);
    expect(harness.files, hasLength(3));
    expect(harness.cleaned, isEmpty);
  });

  test('repeated source paths are rejected before any copy is saved', () async {
    final image = await source('image.jpg');
    await expectLater(
      harness.service.create([image, image]),
      throwsFormatException,
    );
    expect(harness.compressions, 0);
    expect(harness.files, isEmpty);
    expect(harness.saved, isEmpty);
    expect(await File(image.path).readAsBytes(), [1, 2, 3]);
  });

  test('matching filenames with distinct source paths remain valid', () async {
    await Directory('${sources.path}/first').create();
    await Directory('${sources.path}/second').create();
    final first = await source('first/image.jpg', bytes: [1]);
    final second = await source('second/image.jpg', bytes: [2]);
    final note = await harness.service.create([first, second]);
    expect(note.images, hasLength(2));
    expect(harness.files.values, [
      [1],
      [2],
    ]);
  });

  test('image-like text and unsupported media are not image imports', () {
    for (final type in [
      SharedMediaType.text,
      SharedMediaType.url,
      SharedMediaType.video,
    ]) {
      expect(
        SharedImageNoteService.isImage(
          SharedMediaFile(path: 'photo.jpg', type: type),
        ),
        isFalse,
      );
    }
    expect(
      SharedImageNoteService.isImage(
        SharedMediaFile(
          path: 'document.pdf',
          type: SharedMediaType.file,
          mimeType: 'application/pdf',
        ),
      ),
      isFalse,
    );
  });

  test(
    'overlapping shares wait for the previous batch, including failures',
    () async {
      final firstStarted = Completer<void>();
      final release = Completer<void>();
      var saves = 0;
      final service = SharedImageNoteService(
        preparation: harness.service.preparation,
        inspectDimensions: harness.service.inspectDimensions,
        sharedFileLabel: harness.service.sharedFileLabel,
        saveNote: (note) async {
          saves++;
          if (saves == 1) {
            firstStarted.complete();
            await release.future;
            throw StateError('First batch failed');
          }
          harness.saved.add(note);
          return 1;
        },
      );
      final handler = IntentHandlerService(imageNotes: service);
      final firstImage = await source('first.jpg');
      final secondImage = await source('second.jpg');
      final first = handler.handleSharedFiles([firstImage]);
      await firstStarted.future;
      final second = handler.handleSharedFiles([secondImage]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(harness.compressions, 1);
        expect(saves, 1);
      } finally {
        release.complete();
        await Future.wait([first, second]);
        handler.dispose();
      }
      expect(harness.saved, hasLength(1));
      expect(harness.files.keys, ['/documents/image-2.jpg']);
      expect(harness.cleaned, ['/documents/image-1.jpg']);
    },
  );

  test(
    'a corrupt image rolls back the batch and preserves source files',
    () async {
      final good = await source('good.jpg');
      final bad = await source('bad.jpg', bytes: []);
      await expectLater(
        harness.service.create([good, bad]),
        throwsA(
          isA<SharedImageImportException>().having(
            (e) => e.fileName,
            'fileName',
            'bad.jpg',
          ),
        ),
      );

      expect(harness.saved, isEmpty);
      expect(harness.files, isEmpty);
      expect(harness.cleaned, ['/documents/image-1.jpg']);
      expect(await File(good.path).exists(), isTrue);
      expect(await File(bad.path).exists(), isTrue);
    },
  );

  test(
    'missing source releases images already prepared without saving',
    () async {
      final good = await source('good.jpg');
      await expectLater(
        harness.service.create([
          good,
          SharedMediaFile(
            path: '${sources.path}/missing.jpg',
            type: SharedMediaType.image,
          ),
        ]),
        throwsA(
          isA<SharedImageImportException>().having(
            (e) => e.fileName,
            'fileName',
            'missing.jpg',
          ),
        ),
      );
      expect(harness.saved, isEmpty);
      expect(harness.files, isEmpty);
    },
  );

  for (final throwsOnSave in [false, true]) {
    test(
      'save ${throwsOnSave ? 'exception' : 'failure'} releases every prepared copy',
      () async {
        harness.failSave = true;
        harness.throwOnSave = throwsOnSave;
        final images = [await source('a.jpg'), await source('b.jpg')];
        await expectLater(harness.service.create(images), throwsStateError);
        expect(harness.files, isEmpty);
        expect(harness.cleaned, hasLength(2));
        expect(harness.saved, isEmpty);
        for (final image in images) {
          expect(await File(image.path).exists(), isTrue);
        }
      },
    );
  }

  test(
    'oversized source is rejected before preparation and names the file',
    () async {
      final image = await source('large.jpg');
      final handle = await File(image.path).open(mode: FileMode.write);
      await handle.truncate(SharedImageNoteService.maxSourceBytes + 1);
      await handle.close();
      await expectLater(
        harness.service.create([image]),
        throwsA(
          isA<SharedImageImportException>().having(
            (e) => e.fileName,
            'fileName',
            'large.jpg',
          ),
        ),
      );
      expect(harness.nextId, 0);
      expect(harness.compressions, 0);
      expect(harness.saved, isEmpty);
      expect(
        await File(image.path).length(),
        SharedImageNoteService.maxSourceBytes + 1,
      );
    },
  );

  test(
    'a 48 MP image is rejected before compression and preserves its source',
    () async {
      final image = await source('camera-original.heic');
      harness.sourceDimensions = const ImageAttachmentDimensions(
        width: 8000,
        height: 6000,
      );
      await expectLater(
        harness.service.create([image]),
        throwsA(
          isA<SharedImageImportException>().having(
            (e) => e.fileName,
            'fileName',
            'camera-original.heic',
          ),
        ),
      );
      expect(harness.nextId, 0);
      expect(harness.compressions, 0);
      expect(harness.saved, isEmpty);
      expect(await File(image.path).readAsBytes(), [1, 2, 3]);
    },
  );

  test('the 24 MP boundary is accepted', () async {
    harness.sourceDimensions = const ImageAttachmentDimensions(
      width: 6000,
      height: 4000,
    );
    await harness.service.create([await source('photo.jpg')]);
    expect(harness.saved, hasLength(1));
  });

  test('platform metadata inspection accepts an encoded PNG without a frame decode', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
    );
    final image = await source('pixel.png', bytes: png);
    final service = SharedImageNoteService(
      preparation: harness.service.preparation,
      sharedFileLabel: harness.service.sharedFileLabel,
      saveNote: harness.service.saveNote,
    );
    await service.create([image]);
    expect(harness.saved, hasLength(1));
  });

  test('oversized PNG metadata is rejected before any compression', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
    );
    // A valid IHDR with a 48 MP extent; raster data is intentionally tiny.
    final header = ByteData.sublistView(png);
    header.setUint32(16, 8000);
    header.setUint32(20, 6000);
    header.setUint32(29, getCrc32(png.sublist(12, 29)));
    final image = await source('oversized.png', bytes: png);
    final service = SharedImageNoteService(
      preparation: harness.service.preparation,
      sharedFileLabel: harness.service.sharedFileLabel,
      saveNote: harness.service.saveNote,
    );
    await expectLater(
      service.create([image]),
      throwsA(
        isA<SharedImageImportException>().having(
          (e) => e.cause.toString(),
          'cause',
          contains('24 megapixel'),
        ),
      ),
    );
    expect(harness.compressions, 0);
    expect(harness.saved, isEmpty);
  });

  test('file URI sources are copied successfully', () async {
    final image = await source('photo with spaces.png');
    await harness.service.create([
      SharedMediaFile(
        path: File(image.path).uri.toString(),
        type: SharedMediaType.image,
      ),
    ]);
    expect(harness.saved, hasLength(1));
  });
}

class _ImageImportHarness {
  final files = <String, Uint8List>{};
  final cleaned = <String>[];
  final saved = <Note>[];
  bool failSave = false;
  bool throwOnSave = false;
  int nextId = 0;
  int compressions = 0;
  ImageAttachmentDimensions sourceDimensions = const ImageAttachmentDimensions(
    width: 1200,
    height: 800,
  );

  late final service = SharedImageNoteService(
    inspectDimensions: (_) async => sourceDimensions,
    preparation: ImageAttachmentPreparationService(
      ImageAttachmentPreparationOperations(
        compress:
            (
              bytes, {
              required quality,
              required minWidth,
              required minHeight,
            }) async {
              compressions++;
              return bytes;
            },
        decode: (bytes) async {
          if (bytes.isEmpty) throw const FormatException('Invalid image');
          return const ImageAttachmentDimensions(width: 1200, height: 800);
        },
        generateThumbnail: (_) async => null,
        documentDirectory: () async => '/documents',
        write: (path, bytes) async {
          files[path] = bytes;
        },
        cleanup: (path) async {
          cleaned.add(path);
          files.remove(path);
        },
        newId: () => 'image-${++nextId}',
      ),
    ),
    sharedFileLabel: () async => Label.sharedFileLabelName,
    saveNote: (note) async {
      if (throwOnSave) throw StateError('Injected save exception');
      if (failSave) return -1;
      saved.add(note);
      return 1;
    },
  );
}
