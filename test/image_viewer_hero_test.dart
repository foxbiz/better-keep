import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/pages/image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('calculateImageViewerFrameSize', () {
    test('contains landscape, portrait, and square ratios', () {
      const viewport = Size(800, 600);

      expect(
        calculateImageViewerFrameSize(viewport, 16 / 9),
        const Size(800, 450),
      );
      expect(
        calculateImageViewerFrameSize(viewport, 9 / 16),
        const Size(337.5, 600),
      );
      expect(calculateImageViewerFrameSize(viewport, 1), const Size(600, 600));
    });

    test('invalid ratios and bounds produce finite non-zero frames', () {
      for (final ratio in <double>[0, -1, double.nan, double.infinity]) {
        final size = calculateImageViewerFrameSize(const Size(800, 600), ratio);
        expect(size, const Size(600, 600));
      }

      final invalidBounds = calculateImageViewerFrameSize(
        const Size(double.infinity, 0),
        2,
      );
      expect(invalidBounds.width.isFinite, isTrue);
      expect(invalidBounds.height.isFinite, isTrue);
      expect(invalidBounds.width, greaterThan(0));
      expect(invalidBounds.height, greaterThan(0));
    });
  });

  testWidgets('pending destination image keeps stable non-zero Hero geometry', (
    tester,
  ) async {
    const heroTag = 'pending-image-hero';
    final image = _image(
      src: '/definitely-missing-image-viewer-source.png',
      aspectRatio: '16:9',
    );

    await tester.pumpWidget(
      _localizedApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: GestureDetector(
                key: const Key('open-image-viewer'),
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImageViewer(
                      note: Note(id: 42),
                      image: image,
                      heroTag: heroTag,
                    ),
                  ),
                ),
                child: const Hero(
                  tag: heroTag,
                  child: SizedBox(width: 160, height: 90),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-image-viewer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));

    final duringHandoff = tester.getSize(find.byKey(imageViewerHeroFrameKey));
    expect(duringHandoff.width, greaterThan(0));
    expect(duringHandoff.height, greaterThan(0));

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final afterHandoff = tester.getSize(find.byKey(imageViewerHeroFrameKey));
    expect(afterHandoff.width, greaterThan(0));
    expect(afterHandoff.height, greaterThan(0));
    expect(afterHandoff.width / afterHandoff.height, closeTo(16 / 9, 0.001));
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('decoded image retains the reserved Hero frame', (tester) async {
    final image = _image(
      src:
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      aspectRatio: '1:1',
    );

    await tester.pumpWidget(
      _localizedApp(
        home: ImageViewer(note: Note(id: 7), image: image),
      ),
    );
    await tester.pump();
    final beforeDecode = tester.getSize(find.byKey(imageViewerHeroFrameKey));

    await tester.pumpAndSettle();
    final afterDecode = tester.getSize(find.byKey(imageViewerHeroFrameKey));

    expect(beforeDecode.width, greaterThan(0));
    expect(beforeDecode, afterDecode);
    expect(afterDecode.width / afterDecode.height, closeTo(1, 0.001));
    expect(find.byType(Image), findsOneWidget);
  });
}

MaterialApp _localizedApp({required Widget home}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

NoteImage _image({required String src, required String aspectRatio}) =>
    NoteImage(
      src: src,
      size: 1,
      index: 0,
      aspectRatio: aspectRatio,
      lastModified: '2026-07-20T00:00:00.000Z',
    );
