import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hydrates every current-format strokes-file field', () async {
    final sketch = SketchData(strokesFilePath: '/local/strokes.json');
    var reads = 0;

    final result = await SketchStrokesFileService.hydrate(
      sketch,
      pathExists: (_) async => true,
      readBytes: (_) async {
        reads++;
        return Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'strokes': ['pen:${Colors.red.toARGB32()}:5.0:1,2,0.5;'],
              'bgColor': Colors.blue.toARGB32(),
              'pagePattern': PagePattern.grid.name,
              'aspectRatio': 2.0,
            }),
          ),
        );
      },
    );

    expect(result, SketchStrokesLoadResult.loaded);
    expect(reads, 1);
    expect(sketch.strokes, hasLength(1));
    expect(sketch.strokes.single.color.toARGB32(), Colors.red.toARGB32());
    expect(sketch.backgroundColor.toARGB32(), Colors.blue.toARGB32());
    expect(sketch.pagePattern, PagePattern.grid);
    expect(sketch.aspectRatio, 2.0);
  });

  test('does not read a file when strokes are already hydrated', () async {
    final sketch = SketchData(
      strokesFilePath: '/local/strokes.json',
      strokes: [SketchStroke(points: '1,2,0.5;', color: Colors.black, size: 5)],
    );

    final result = await SketchStrokesFileService.hydrate(
      sketch,
      pathExists: (_) async => throw StateError('must not check the path'),
      readBytes: (_) async => throw StateError('must not read the file'),
    );

    expect(result, SketchStrokesLoadResult.alreadyLoaded);
  });

  test('keeps a previously verified empty source hydrated', () async {
    final sketch = SketchData(
      strokesFilePath: '/local/empty.json',
      strokesHydrated: true,
    );

    final result = await SketchStrokesFileService.hydrate(
      sketch,
      pathExists: (_) async => throw StateError('must not check the path'),
      readBytes: (_) async => throw StateError('must not read the file'),
    );

    expect(result, SketchStrokesLoadResult.empty);
    expect(result.isHydrated, isTrue);
  });

  test(
    'hydrates all decrypted sketches without short-circuiting failures',
    () async {
      final loaded = SketchData(strokesFilePath: '/local/loaded.json');
      final missing = SketchData(strokesFilePath: '/local/missing.json');
      final visited = <SketchData>[];

      final results = await SketchStrokesFileService.hydrateDecrypted(
        [loaded, missing],
        hydrateSketch: (sketch) async {
          visited.add(sketch);
          if (identical(sketch, loaded)) {
            sketch.strokes = [
              SketchStroke(points: '1,2,0.5;', color: Colors.black, size: 2),
            ];
            sketch.markStrokesHydrated();
            return SketchStrokesLoadResult.loaded;
          }
          return SketchStrokesLoadResult.unavailable;
        },
      );

      expect(visited, [loaded, missing]);
      expect(results[loaded], SketchStrokesLoadResult.loaded);
      expect(results[missing], SketchStrokesLoadResult.unavailable);
      expect(loaded.hasHydratedStrokeSource, isTrue);
      expect(missing.hasHydratedStrokeSource, isFalse);
    },
  );

  test('defers ENCP files before attempting UTF-8 or JSON decoding', () async {
    final sketch = SketchData(strokesFilePath: '/local/encrypted.json');

    final result = await SketchStrokesFileService.hydrate(
      sketch,
      pathExists: (_) async => true,
      // 0xff is deliberately invalid UTF-8. Detecting the ENCP header first
      // must keep this expected locked-file state out of the decoder.
      readBytes: (_) async =>
          Uint8List.fromList([0x45, 0x4e, 0x43, 0x50, 0xff]),
    );

    expect(result, SketchStrokesLoadResult.passwordProtected);
    expect(sketch.strokes, isEmpty);
  });

  test(
    'authenticated session hydrates ENCP strokes without rewriting the source',
    () async {
      final sketch = SketchData(strokesFilePath: '/local/protected.json');
      final plaintext = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': ['pen:${Colors.red.toARGB32()}:5.0:1,2,0.5;'],
            'bgColor': Colors.blue.toARGB32(),
            'pagePattern': PagePattern.grid.name,
            'aspectRatio': 1.5,
          }),
        ),
      );
      final protected = await encryptBytesWithPassword(plaintext, '2468');
      final canonical = Uint8List.fromList(protected);

      final result = await SketchStrokesFileService.hydrate(
        sketch,
        pathExists: (_) async => true,
        readBytes: (_) async => protected,
        passwordProtectedDecoder: (bytes) =>
            decryptBytesWithPassword(bytes, '2468'),
      );

      expect(result, SketchStrokesLoadResult.loaded);
      expect(sketch.strokes, hasLength(1));
      expect(sketch.backgroundColor.toARGB32(), Colors.blue.toARGB32());
      expect(sketch.pagePattern, PagePattern.grid);
      expect(sketch.aspectRatio, 1.5);
      expect(protected, canonical);
      expect(isBytesPasswordEncrypted(protected), isTrue);
    },
  );

  test('reports and preserves JSON-contained legacy ciphertext', () async {
    final sketch = SketchData(strokesFilePath: '/local/legacy.json');

    final result = await SketchStrokesFileService.hydrate(
      sketch,
      pathExists: (_) async => true,
      readBytes: (_) async => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': <String>[],
            'encryptedStrokes': 'existing-ciphertext',
            'bgColor': Colors.blue.toARGB32(),
          }),
        ),
      ),
    );

    expect(result, SketchStrokesLoadResult.legacyPasswordProtected);
    expect(sketch.encryptedStrokes, 'existing-ciphertext');
    expect(sketch.requiresLegacyMigration, isTrue);
    expect(sketch.hasHydratedStrokeSource, isFalse);
    expect(sketch.toJson()['encryptedStrokes'], 'existing-ciphertext');
  });

  test('reports remote, missing, empty, and invalid files safely', () async {
    expect(
      await SketchStrokesFileService.hydrate(
        SketchData(strokesFilePath: 'https://example.com/strokes.json'),
      ),
      SketchStrokesLoadResult.unavailable,
    );

    expect(
      await SketchStrokesFileService.hydrate(
        SketchData(strokesFilePath: '/missing.json'),
        pathExists: (_) async => false,
      ),
      SketchStrokesLoadResult.unavailable,
    );

    expect(
      await SketchStrokesFileService.hydrate(
        SketchData(strokesFilePath: '/empty.json'),
        pathExists: (_) async => true,
        readBytes: (_) async => Uint8List.fromList(
          utf8.encode(jsonEncode({'strokes': <String>[]})),
        ),
      ),
      SketchStrokesLoadResult.empty,
    );

    expect(
      await SketchStrokesFileService.hydrate(
        SketchData(strokesFilePath: '/invalid.json'),
        pathExists: (_) async => true,
        readBytes: (_) async => Uint8List.fromList(utf8.encode('not-json')),
      ),
      SketchStrokesLoadResult.invalid,
    );
  });
}
