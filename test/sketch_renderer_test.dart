import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SketchRenderer', () {
    test('preserves aspect ratio when bounding large canvases', () {
      expect(
        SketchRenderer.boundedSize(const Size(4000, 2000)),
        const Size(1200, 600),
      );
      expect(
        SketchRenderer.boundedSize(const Size(1000, 2000)),
        const Size(600, 1200),
      );
    });

    test('uniformly bounds oversized raster dimensions', () {
      final landscape = SketchRenderer.boundedPixelSize(
        const Size(12000, 9000),
      );
      final portrait = SketchRenderer.boundedPixelSize(const Size(9000, 12000));

      expect(landscape, const Size(8192, 6144));
      expect(portrait, const Size(6144, 8192));
      expect(
        landscape.width / landscape.height,
        closeTo(12000 / 9000, 0.000001),
      );
      expect(portrait.width / portrait.height, closeTo(9000 / 12000, 0.000001));
    });

    test('keeps safe raster sizes and falls back for invalid sizes', () {
      expect(
        SketchRenderer.boundedPixelSize(const Size(4000, 3000)),
        const Size(4000, 3000),
      );
      expect(SketchRenderer.boundedPixelSize(Size.zero), kSketchA4Size);
      expect(
        SketchRenderer.boundedPixelSize(const Size(-1, 100)),
        kSketchA4Size,
      );
      expect(
        SketchRenderer.boundedPixelSize(const Size(double.infinity, 100)),
        kSketchA4Size,
      );
    });

    test('scales native image coordinates with the background', () async {
      final background = await _solidImage(400, 200, Colors.blue);
      try {
        final bytes = await SketchRenderer.renderPng(
          strokes: [
            SketchStroke(
              points: '285,100,0.5;300,100,0.5;315,100,0.5;',
              color: Colors.red,
              size: 24,
            ),
          ],
          sourceCanvasSize: const Size(400, 200),
          outputSize: const Size(200, 100),
          backgroundColor: Colors.transparent,
          pagePattern: PagePattern.blank,
          isImageBased: true,
          backgroundImage: background,
        );

        final rendered = await _decode(bytes);
        try {
          expect(rendered.width, 200);
          expect(rendered.height, 100);
          final pixels = await rendered.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          expect(pixels, isNotNull);

          final untouched = _pixel(pixels!, rendered.width, 50, 50);
          expect(untouched.b, greaterThan(0.8));
          expect(untouched.r, lessThan(0.2));

          // x=300 in the 400px source must land at x=150 in the 200px preview.
          final stroke = _pixel(pixels, rendered.width, 150, 50);
          expect(stroke.r, greaterThan(0.7));
          expect(stroke.b, lessThan(0.4));
        } finally {
          rendered.dispose();
        }
      } finally {
        background.dispose();
      }
    });

    test('renders every drawing tool through the shared painter', () async {
      final strokes = <SketchStroke>[
        for (final (index, tool) in SketchTool.values.indexed)
          SketchStroke(
            points:
                '10,${15 + index * 15},0.5;50,${15 + index * 15},0.5;90,${15 + index * 15},0.5;',
            color: Colors.black,
            size: 8,
            tool: tool,
          ),
      ];

      final bytes = await SketchRenderer.renderPng(
        strokes: strokes,
        sourceCanvasSize: const Size(100, 100),
        outputSize: const Size(100, 100),
        backgroundColor: Colors.white,
        pagePattern: PagePattern.grid,
        isImageBased: false,
      );
      final rendered = await _decode(bytes);
      try {
        expect(rendered.width, 100);
        expect(rendered.height, 100);
        expect(bytes, isNotEmpty);
      } finally {
        rendered.dispose();
      }
    });
  });

  test('sketch sync JSON schema remains unchanged', () {
    final sketch = SketchData(
      strokesFilePath: '/local/strokes.json',
      backgroundImage: '/local/photo.jpg',
      aspectRatio: 2,
      strokes: [SketchStroke(points: '1,2,0.5;', color: Colors.black, size: 5)],
    );

    expect(
      sketch.toJson().keys,
      unorderedEquals([
        'strokesFilePath',
        'aspectRatio',
        'previewImage',
        'backgroundImage',
      ]),
    );
    expect(
      sketch.toStrokesFileJson().keys,
      unorderedEquals(['strokes', 'bgColor', 'pagePattern', 'aspectRatio']),
    );
  });

  group('SketchPreviewRepairService', () {
    test('skips an already completed repair version', () async {
      var repaired = false;
      var marked = false;
      final ran = await SketchPreviewRepairService.runVersionedRepair(
        storedVersion: SketchPreviewRepairService.currentVersion,
        repair: () async => repaired = true,
        markComplete: (_) async => marked = true,
      );
      expect(ran, isFalse);
      expect(repaired, isFalse);
      expect(marked, isFalse);
    });

    test('marks the version only after repair completes', () async {
      final events = <String>[];
      final ran = await SketchPreviewRepairService.runVersionedRepair(
        storedVersion: 0,
        repair: () async => events.add('repair'),
        markComplete: (version) async => events.add('mark:$version'),
      );
      expect(ran, isTrue);
      expect(events, [
        'repair',
        'mark:${SketchPreviewRepairService.currentVersion}',
      ]);
    });

    test('does not mark an interrupted repair', () async {
      var marked = false;
      await expectLater(
        SketchPreviewRepairService.runVersionedRepair(
          storedVersion: 0,
          repair: () async => throw StateError('interrupted'),
          markComplete: (_) async => marked = true,
        ),
        throwsStateError,
      );
      expect(marked, isFalse);
    });
  });
}

Future<ui.Image> _solidImage(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Color _pixel(ByteData bytes, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(offset + 3),
    bytes.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
  );
}
