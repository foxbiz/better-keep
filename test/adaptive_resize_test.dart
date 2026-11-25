import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Folded and open sizes of a foldable phone, in logical pixels.
const _folded = Size(466, 678);
const _open = Size(951, 669);

void _resize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

void main() {
  setUp(() => debugIsIPhoneDuoOverride = true);
  tearDown(() => debugIsIPhoneDuoOverride = null);

  for (final (from, to) in [(_folded, _open), (_open, _folded)]) {
    testWidgets('open popup stays by its button from $from to $to', (
      tester,
    ) async {
      _resize(tester, from);
      addTearDown(tester.view.reset);
      final controller = AdaptivePopupController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: AdaptivePopupMenu(
                controller: controller,
                items: (_) => const [
                  AdaptiveMenuItem(icon: Icons.image, label: 'Image'),
                ],
                child: const SizedBox(
                  key: Key('button'),
                  width: 48,
                  height: 48,
                ),
              ),
            ),
          ),
        ),
      );
      controller.open();
      await tester.pumpAndSettle();
      _resize(tester, to);
      await tester.pumpAndSettle();

      final popup = tester.getRect(
        find
            .ancestor(of: find.text('Image'), matching: find.byType(ClipRRect))
            .first,
      );
      final button = tester.getRect(find.byKey(const Key('button')));
      expect(popup.left, greaterThanOrEqualTo(0));
      expect(popup.right, lessThanOrEqualTo(to.width));
      expect(popup.top, greaterThanOrEqualTo(0));
      expect(popup.bottom, closeTo(button.top - 8, 1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [_folded, _open]) {
    testWidgets('popup in a SafeArea clears a side status area at $size', (
      tester,
    ) async {
      _resize(tester, size);
      const padding = FakeViewPadding(right: 84);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      addTearDown(tester.view.reset);
      final controller = AdaptivePopupController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: AdaptivePopupMenu(
                  controller: controller,
                  items: (_) => const [
                    AdaptiveMenuItem(icon: Icons.image, label: 'Image'),
                  ],
                  child: const SizedBox(width: 48, height: 48),
                ),
              ),
            ),
          ),
        ),
      );
      controller.open();
      await tester.pumpAndSettle();
      final popup = tester.getRect(
        find
            .ancestor(of: find.text('Image'), matching: find.byType(ClipRRect))
            .first,
      );
      expect(popup.right, lessThanOrEqualTo(size.width - 84));
    });
  }

  testWidgets('toolbar toggle follows overflow after a resize', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    _resize(tester, _open);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AdaptiveToolbar(
              key: const Key('toolbar'),
              parentColor: Colors.white,
              children: [
                for (var i = 0; i < 14; i++) const SizedBox(width: 48),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);

    _resize(tester, _folded);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);

    _resize(tester, _open);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
