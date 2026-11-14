import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a section below the cache stays unmounted until scrolled into view',
    (tester) async {
      final mounted = <int>{};
      final scroll = ScrollController();
      final layout = MasonryLayoutController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        _grid(scroll, layout, mounted, leadingSpace: 2000),
      );
      await tester.pumpAndSettle();
      expect(mounted, isEmpty);
      scroll.jumpTo(2000);
      await tester.pumpAndSettle();
      expect(mounted, contains(0));
      expect(mounted.length, inInclusiveRange(1, 40));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'large masonry mounts a bounded window and releases scrolled cards',
    (tester) async {
      final mounted = <int>{};
      final scroll = ScrollController();
      final layout = MasonryLayoutController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_grid(scroll, layout, mounted));
      await tester.pumpAndSettle();
      expect(mounted.length, inInclusiveRange(1, 40));
      expect(mounted, contains(0));
      expect(mounted, isNot(contains(999)));
      final firstRect = layout.targetGlobalRectFor(0);

      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(mounted, contains(999));
      expect(mounted, isNot(contains(0)));
      expect(mounted.length, inInclusiveRange(1, 40));

      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(layout.targetGlobalRectFor(0), firstRect);
      expect(mounted, contains(0));
      expect(mounted, isNot(contains(999)));
      expect(mounted.length, inInclusiveRange(1, 40));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(mounted, isEmpty);
    },
  );

  testWidgets(
    'active drag survives scrolling and reorder beyond its original window',
    (tester) async {
      final mounted = <int>{};
      final scroll = ScrollController();
      final layout = MasonryLayoutController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_grid(scroll, layout, mounted, active: 0));
      await tester.pumpAndSettle();
      scroll.jumpTo(10000);
      await tester.pumpAndSettle();
      expect(mounted, contains(0));
      expect(mounted.length, lessThan(40));
      const pointer = Offset(200, 200);
      layout.updateDragPosition(pointer);
      await tester.pump();
      expect(layout.globalRectFor(0)!.topLeft, pointer);
      final resolution = layout.resolveInsertion(
        globalPosition: pointer,
        excludingId: 0,
      );
      expect(resolution, isNotNull);
      expect(resolution!.insertionIndex, greaterThan(20));
      final ids = List.generate(1000, (i) => i)..remove(0);
      ids.insert(resolution.insertionIndex, 0);
      await tester.pumpWidget(
        _grid(scroll, layout, mounted, active: 0, ids: ids),
      );
      await tester.pumpAndSettle();
      expect(mounted, contains(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_grid(scroll, layout, mounted, ids: ids));
      await tester.pumpAndSettle();
      expect(mounted.length, lessThan(40));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(mounted, isEmpty);
    },
  );

  testWidgets(
    'resize and RTL remeasure visible cards without mounting the library',
    (tester) async {
      final mounted = <int>{};
      final scroll = ScrollController();
      final layout = MasonryLayoutController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(_grid(scroll, layout, mounted));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _grid(scroll, layout, mounted, columns: 2, rtl: true),
      );
      await tester.pumpAndSettle();
      expect(
        layout.targetGlobalRectFor(0)!.left,
        greaterThan(layout.targetGlobalRectFor(1)!.left),
      );
      expect(mounted.length, inInclusiveRange(1, 40));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(mounted, contains(999));
      expect(mounted.length, inInclusiveRange(1, 40));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Widget _grid(
  ScrollController scroll,
  MasonryLayoutController layout,
  Set<int> mounted, {
  int? active,
  List<int>? ids,
  double leadingSpace = 0,
  int columns = 3,
  bool rtl = false,
}) => MaterialApp(
  home: Directionality(
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    child: Scaffold(
      body: CustomScrollView(
        controller: scroll,
        slivers: [
          if (leadingSpace > 0)
            SliverToBoxAdapter(child: SizedBox(height: leadingSpace)),
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: AnimatedMasonryReorderLayout(
                controller: layout,
                crossAxisCount: columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                activeId: active,
                cacheBounds: masonryCacheBounds(constraints),
                children: [
                  for (final id in ids ?? List.generate(1000, (i) => i))
                    MasonryReorderItem.lazy(
                      key: ValueKey(id),
                      id: id,
                      builder: (_) => _Probe(id, mounted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  ),
);

class _Probe extends StatefulWidget {
  const _Probe(this.id, this.mounted);
  final int id;
  final Set<int> mounted;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.mounted.add(widget.id);
  }

  @override
  void dispose() {
    widget.mounted.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 80 + (widget.id % 7) * 31.0,
    child: Text('Card ${widget.id}'),
  );
}
