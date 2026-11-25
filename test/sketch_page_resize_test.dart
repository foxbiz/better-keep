import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _insets = EdgeInsets.only(right: 84, bottom: 34);
const _folded = Size(466, 678);
const _open = Size(951, 669);

void main() {
  setUp(() => debugIsIPhoneDuoOverride = true);
  tearDown(() => debugIsIPhoneDuoOverride = null);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  final canvas = find.byWidgetPredicate(
    (widget) => widget is CustomPaint && widget.painter is SketchPainter,
  );

  void resize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    const padding = FakeViewPadding(right: 84, bottom: 34);
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
  }

  Future<void> open(WidgetTester tester, Size size) async {
    resize(tester, size);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SketchPage(note: Note(), sketch: SketchData()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect safeArea(Size size) => _insets.deflateRect(Offset.zero & size);

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  for (final (from, to) in [(_folded, _open), (_open, _folded)]) {
    testWidgets('untouched canvas refits from $from to $to', (tester) async {
      await open(tester, from);
      for (final size in [from, to]) {
        resize(tester, size);
        await tester.pumpAndSettle();
        final rect = tester.getRect(canvas);
        final area = safeArea(size);
        expect(rect.center.dx, closeTo(area.center.dx, 0.5));
        expect(rect.center.dy, closeTo(area.center.dy, 0.5));
        expect(rect.left, greaterThanOrEqualTo(area.left));
        expect(rect.right, lessThanOrEqualTo(area.right));
        expect(rect.bottom, lessThanOrEqualTo(area.bottom));
      }
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('zoomed canvas keeps its scale and centre from $from to $to', (
      tester,
    ) async {
      await open(tester, from);
      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      controller.value = controller.value.clone()
        ..scaleByDouble(1.5, 1.5, 1.5, 1);
      await tester.pump();
      final scale = controller.value.getMaxScaleOnAxis();
      final point = controller.toScene(safeArea(from).center);

      resize(tester, to);
      await tester.pumpAndSettle();
      expect(controller.value.getMaxScaleOnAxis(), closeTo(scale, 0.001));
      final moved = controller.toScene(safeArea(to).center);
      expect(moved.dx, closeTo(point.dx, 0.5));
      expect(moved.dy, closeTo(point.dy, 0.5));
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  }
}
