import 'package:better_keep/components/animated_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AnimatedMenuIcon holds its last frame when motion is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _motionHost(
        disableAnimations: true,
        child: const AnimatedMenuIcon(
          icon: AnimatedIcons.menu_close,
          repeat: true,
          duration: Duration(milliseconds: 100),
        ),
      ),
    );

    expect(
      tester.widget<AnimatedIcon>(find.byType(AnimatedIcon)).progress.value,
      1,
    );

    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<AnimatedIcon>(find.byType(AnimatedIcon)).progress.value,
      1,
    );
  });

  testWidgets('AnimatedMenuIcon jumps live to its last frame', (tester) async {
    const icon = AnimatedMenuIcon(
      icon: AnimatedIcons.menu_close,
      repeat: true,
      duration: Duration(milliseconds: 400),
    );

    await tester.pumpWidget(_motionHost(disableAnimations: false, child: icon));
    await tester.pump(const Duration(milliseconds: 100));

    final progressBeforeDisabling = tester
        .widget<AnimatedIcon>(find.byType(AnimatedIcon))
        .progress
        .value;
    expect(progressBeforeDisabling, greaterThan(0));
    expect(progressBeforeDisabling, lessThan(1));

    await tester.pumpWidget(_motionHost(disableAnimations: true, child: icon));
    await tester.pump();

    expect(
      tester.widget<AnimatedIcon>(find.byType(AnimatedIcon)).progress.value,
      1,
    );
  });

  testWidgets('IconTransitionAnimation shows only its destination frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      _motionHost(
        disableAnimations: true,
        child: const IconTransitionAnimation(
          fromIcon: Icons.add,
          toIcon: Icons.check,
          repeat: true,
          duration: Duration(milliseconds: 100),
        ),
      ),
    );

    expect(_opacityForIcon(tester, Icons.add), 0);
    expect(_opacityForIcon(tester, Icons.check), 1);

    await tester.pump(const Duration(seconds: 1));
    expect(_opacityForIcon(tester, Icons.add), 0);
    expect(_opacityForIcon(tester, Icons.check), 1);
  });
}

Widget _motionHost({required bool disableAnimations, required Widget child}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

double _opacityForIcon(WidgetTester tester, IconData icon) {
  final opacity = find.ancestor(
    of: find.byIcon(icon),
    matching: find.byType(Opacity),
  );
  return tester.widget<Opacity>(opacity).opacity;
}
