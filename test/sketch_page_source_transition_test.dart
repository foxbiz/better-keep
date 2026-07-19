import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SketchPageSourceController', () {
    test('delete-next-page blocks drawing until its source is hydrated', () {
      final controller = SketchPageSourceController();
      final deletedSketch = SketchData(
        strokes: [_stroke('1,1,0.5;2,2,0.5')],
        strokesFilePath: '/deleted.json',
        strokesHydrated: true,
      );
      final nextSketch = SketchData(strokesFilePath: '/next.json');

      controller.activate(deletedSketch);
      expect(controller.isStrokeSourceReady, isTrue);

      final nextActivation = controller.activate(nextSketch);
      expect(controller.isStrokeSourceReady, isFalse);

      expect(controller.markHydratedSourceReady(nextActivation), isTrue);
      expect(controller.isStrokeSourceReady, isTrue);
    });

    test(
      'unexpected edits prevent hydration from replacing current strokes',
      () {
        final controller = SketchPageSourceController();
        final sketch = SketchData(strokesFilePath: '/loading.json');
        final activation = controller.activate(sketch);

        controller.recordStrokeEdit();

        expect(controller.canApplyHydratedSource(activation), isFalse);
        expect(controller.markHydratedSourceReady(activation), isFalse);
        expect(controller.isStrokeSourceReady, isFalse);
      },
    );

    test(
      'adding a blank page while loading makes it ready and rejects old result',
      () {
        final controller = SketchPageSourceController();
        final loadingSketch = SketchData(strokesFilePath: '/loading.json');
        final loadingActivation = controller.activate(loadingSketch);
        expect(controller.isStrokeSourceReady, isFalse);

        final blankSketch = SketchData();
        final blankActivation = controller.activate(blankSketch);

        expect(controller.isCurrent(blankActivation), isTrue);
        expect(controller.isStrokeSourceReady, isTrue);
        expect(controller.markHydratedSourceReady(loadingActivation), isFalse);
        expect(controller.isStrokeSourceReady, isTrue);
      },
    );

    test(
      'returning to the same sketch rejects its first activation result',
      () {
        final controller = SketchPageSourceController();
        final sketch = SketchData(strokesFilePath: '/same.json');
        final other = SketchData();

        final firstActivation = controller.activate(sketch);
        controller.activate(other);
        final latestActivation = controller.activate(sketch);

        expect(controller.isCurrent(firstActivation), isFalse);
        expect(controller.markHydratedSourceReady(firstActivation), isFalse);
        expect(controller.isStrokeSourceReady, isFalse);
        expect(controller.markHydratedSourceReady(latestActivation), isTrue);
        expect(controller.isStrokeSourceReady, isTrue);
      },
    );

    test(
      'hydrated file-backed and file-free sketches are immediately ready',
      () {
        final controller = SketchPageSourceController();
        final hydrated = SketchData(
          strokesFilePath: '/hydrated.json',
          strokesHydrated: true,
        );

        controller.activate(hydrated);
        expect(controller.isStrokeSourceReady, isTrue);

        controller.activate(SketchData());
        expect(controller.isStrokeSourceReady, isTrue);
      },
    );
  });

  group('SketchSaveGenerationController', () {
    test('deletion permanently invalidates every captured save', () {
      final controller = SketchSaveGenerationController();
      final sketch = SketchData();
      final captured = controller.capture(sketch);

      expect(controller.isCurrent(captured), isTrue);
      controller.tombstone(sketch);

      expect(controller.isDeleted(sketch), isTrue);
      expect(controller.isCurrent(captured), isFalse);
      expect(controller.isCurrent(controller.capture(sketch)), isFalse);
    });

    test('deleting one page does not cancel another page save', () {
      final controller = SketchSaveGenerationController();
      final deleted = SketchData();
      final retained = SketchData();
      final deletedSave = controller.capture(deleted);
      final retainedSave = controller.capture(retained);

      controller.tombstone(deleted);

      expect(controller.isCurrent(deletedSave), isFalse);
      expect(controller.isCurrent(retainedSave), isTrue);
    });

    test('failed deletion restores editing without reviving stale saves', () {
      final controller = SketchSaveGenerationController();
      final sketch = SketchData();
      final stale = controller.capture(sketch);

      controller.tombstone(sketch);
      controller.restore(sketch);
      final retry = controller.capture(sketch);

      expect(controller.isDeleted(sketch), isFalse);
      expect(controller.isCurrent(stale), isFalse);
      expect(controller.isCurrent(retry), isTrue);
    });
  });
}

SketchStroke _stroke(String points) => SketchStroke(
  points: points,
  color: const Color(0xFF000000),
  size: 4,
  tool: SketchTool.pen,
);
