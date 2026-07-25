import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('masonry reorder visual states', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harnessKey = GlobalKey<_GoldenHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: const ValueKey('golden_surface'),
              child: SizedBox(
                width: 420,
                height: 620,
                child: ColoredBox(
                  color: const Color(0xFFF8F6FA),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _GoldenHarness(key: harnessKey),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/masonry_idle.png'),
    );

    harnessKey.currentState!.lift();
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/masonry_lifted.png'),
    );

    harnessKey.currentState!.moveTallCard();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/masonry_mid_reflow.png'),
    );

    harnessKey.currentState!.showInvalidBoundary();
    await tester.pump();
    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/masonry_invalid_boundary.png'),
    );

    harnessKey.currentState!.settle();
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/masonry_settled.png'),
    );
  });
}

class _GoldenHarness extends StatefulWidget {
  const _GoldenHarness({super.key});

  @override
  State<_GoldenHarness> createState() => _GoldenHarnessState();
}

class _GoldenHarnessState extends State<_GoldenHarness> {
  final MasonryLayoutController _controller = MasonryLayoutController();
  List<int> _ids = [1, 2, 3, 4, 5, 6];
  int? _activeId;
  Offset? _dragPosition;
  Color _placeholderColor = const Color(0x226750A4);

  void lift() {
    setState(() {
      _activeId = 1;
      _dragPosition = const Offset(102, 78);
    });
  }

  void moveTallCard() {
    setState(() {
      _ids = [2, 3, 1, 4, 5, 6];
      _dragPosition = const Offset(246, 170);
    });
  }

  void showInvalidBoundary() {
    setState(() {
      _placeholderColor = const Color(0x44BA1A1A);
      _dragPosition = const Offset(246, 310);
    });
  }

  void settle() {
    setState(() {
      _activeId = null;
      _dragPosition = null;
      _placeholderColor = const Color(0x226750A4);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedMasonryReorderLayout(
      controller: _controller,
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      activeId: _activeId,
      dragGlobalPosition: _dragPosition,
      dragAnchor: const Offset(24, 24),
      placeholderColor: _placeholderColor,
      children: [
        for (final id in _ids)
          MasonryReorderItem(
            key: ValueKey(id),
            id: id,
            child: AnimatedScale(
              scale: id == _activeId ? 1.02 : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: Material(
                elevation: id == _activeId ? 6 : 1,
                shadowColor: Colors.black26,
                surfaceTintColor: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                color: _colors[id - 1],
                child: SizedBox(height: _heights[id - 1]),
              ),
            ),
          ),
      ],
    );
  }
}

const _heights = [190.0, 74.0, 112.0, 82.0, 126.0, 68.0];
const _colors = [
  Color(0xFFFFF0C7),
  Color(0xFFDDEEFF),
  Color(0xFFE8DDF8),
  Color(0xFFDFF3E4),
  Color(0xFFFFDDE5),
  Color(0xFFECE8DE),
];
