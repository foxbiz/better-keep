import 'dart:ui' as ui;

import 'package:better_keep/components/note_attachments_carousel.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  for (final viewport in [const Size(400, 566), const Size(1000, 700)]) {
    testWidgets('sketch Hero lands beneath the controls at $viewport', (
      tester,
    ) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final previewPath =
          'build/sketch-hero-${DateTime.now().microsecondsSinceEpoch}.png';
      final sketch = SketchData(
        previewImage: previewPath,
        aspectRatio: kSketchA4Size.aspectRatio,
        strokes: [
          SketchStroke(
            points: '100,100,0.5;600,800,0.5;',
            color: Colors.blue,
            size: 12,
          ),
        ],
      );
      await tester.runAsync(() async {
        final bytes = await SketchRenderer.renderPng(
          strokes: sketch.strokes,
          sourceCanvasSize: kSketchA4Size,
          backgroundColor: sketch.backgroundColor,
          pagePattern: sketch.pagePattern,
          isImageBased: false,
        );
        final fs = await fileSystem();
        await fs.writeBytes(previewPath, bytes);
        UniversalImageCache.instance.put(previewPath, previewPath, bytes);
        addTearDown(() => fs.delete(previewPath));
      });
      addTearDown(UniversalImageCache.instance.clear);
      final note = Note(attachments: [NoteAttachment.sketch(sketch)]);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('sketch-transition-frame'),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(child: NoteAttachmentsCarousel(note: note)),
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 50; frame++) {
        if (tester.widget<RawImage>(find.byType(RawImage)).image != null) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await tester.pumpAndSettle();
      final thumbnail = tester.getRect(find.byType(UniversalImage));
      await tester.tap(find.byType(UniversalImage));
      await tester.pump();
      final route =
          ModalRoute.of(
                tester.element(find.byType(SketchPage, skipOffstage: false)),
              )!
              as PageRoute;
      await tester.pump(
        route.transitionDuration - const Duration(milliseconds: 1),
      );
      final flightEnd = tester.getRect(find.byType(UniversalImage));
      final controls = [
        find.byType(BackButton),
        find.byIcon(Icons.more_vert),
        find.byKey(const Key('sketch_page_toolbar')),
      ];
      final duringFlight = await _controlInk(tester, controls);
      await tester.pumpAndSettle();
      final afterFlight = await _controlInk(tester, controls);
      for (var i = 0; i < controls.length; i++) {
        expect(controls[i], findsOneWidget);
        expect(afterFlight[i], greaterThan(0));
        expect(
          duringFlight[i],
          greaterThanOrEqualTo(afterFlight[i] * 0.9),
          reason: 'Control $i must remain visible above the flying sketch',
        );
      }
      final canvas = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is SketchPainter,
      );
      final landed = tester.getRect(canvas);
      expect(flightEnd.left, closeTo(landed.left, 0.5));
      expect(flightEnd.top, closeTo(landed.top, 0.5));
      expect(flightEnd.width, closeTo(landed.width, 0.5));
      expect(flightEnd.height, closeTo(landed.height, 0.5));

      // Overlay controls still update and leave menus above them.
      final moveTool = find.widgetWithIcon(IconButton, Icons.open_with_rounded);
      await tester.tap(moveTool);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(moveTool).isSelected, isTrue);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(
        find.byType(PopupMenuItem<String>).hitTestable(),
        findsNWidgets(2),
      );
      Navigator.of(tester.element(find.byType(SketchPage))).pop();
      await tester.pumpAndSettle();

      // Zoom still belongs to the canvas after the Hero hands it back.
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value =
          viewer.transformationController!.value.clone()
            ..scaleByDouble(1.2, 1.2, 1.2, 1);
      await tester.pump();
      expect(tester.getRect(canvas).width, closeTo(landed.width * 1.2, 0.5));
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final returning = await _controlInk(tester, controls);
      for (var i = 0; i < controls.length; i++) {
        expect(
          returning[i],
          greaterThanOrEqualTo(afterFlight[i] * 0.9),
          reason: 'Control $i must remain above the returning sketch',
        );
      }
      await tester.pumpAndSettle();
      for (final control in controls) {
        expect(control, findsNothing);
      }
      expect(tester.getRect(find.byType(UniversalImage)), thumbnail);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

Future<List<int>> _controlInk(
  WidgetTester tester,
  List<Finder> controls,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('sketch-transition-frame')),
  );
  final rectangles = controls.map(tester.getRect).toList();
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final counts = <int>[];
    for (final rect in rectangles) {
      var count = 0;
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          final pixel = (y * image.width + x) * 4;
          if (bytes.getUint8(pixel) < 200 &&
              bytes.getUint8(pixel + 1) < 200 &&
              bytes.getUint8(pixel + 2) < 200) {
            count++;
          }
        }
      }
      counts.add(count);
    }
    image.dispose();
    return counts;
  }))!;
}
