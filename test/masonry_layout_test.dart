import 'package:better_keep/components/animated_masonry_reorder_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MasonryLayoutEngine', () {
    test('uses the shortest column with a reading-order tie break', () {
      final layout = MasonryLayoutEngine.compute(
        width: 208,
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        textDirection: TextDirection.ltr,
        items: const [
          MasonryLayoutItem(id: 1, height: 100),
          MasonryLayoutItem(id: 2, height: 40),
          MasonryLayoutItem(id: 3, height: 40),
          MasonryLayoutItem(id: 4, height: 40),
        ],
      );

      expect(layout.rects[1], const Rect.fromLTWH(0, 0, 100, 100));
      expect(layout.rects[2], const Rect.fromLTWH(108, 0, 100, 40));
      expect(layout.rects[3], const Rect.fromLTWH(108, 48, 100, 40));
      expect(layout.rects[4], const Rect.fromLTWH(108, 96, 100, 40));
      expect(layout.extent, 136);
    });

    test('a tall insertion reflows multiple following cards', () {
      MasonryLayoutSnapshot layout(List<MasonryLayoutItem> items) {
        return MasonryLayoutEngine.compute(
          width: 208,
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          textDirection: TextDirection.ltr,
          items: items,
        );
      }

      const small = [
        MasonryLayoutItem(id: 2, height: 60),
        MasonryLayoutItem(id: 3, height: 60),
        MasonryLayoutItem(id: 4, height: 60),
        MasonryLayoutItem(id: 5, height: 60),
      ];
      final before = layout([
        const MasonryLayoutItem(id: 1, height: 180),
        ...small,
      ]);
      final after = layout([
        ...small.take(2),
        const MasonryLayoutItem(id: 1, height: 180),
        ...small.skip(2),
      ]);

      final movedFollowingCards = [
        2,
        3,
        4,
        5,
      ].where((id) => before.rects[id] != after.rects[id]).length;
      expect(movedFollowingCards, greaterThanOrEqualTo(3));
    });

    test('RTL mirrors physical columns while preserving logical tie order', () {
      final layout = MasonryLayoutEngine.compute(
        width: 208,
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        textDirection: TextDirection.rtl,
        items: const [
          MasonryLayoutItem(id: 1, height: 40),
          MasonryLayoutItem(id: 2, height: 40),
        ],
      );

      expect(layout.rects[1]!.left, 108);
      expect(layout.rects[2]!.left, 0);
    });

    test('list insertion slots follow every sequence boundary', () {
      final slots = MasonryLayoutEngine.computeInsertionSlots(
        width: 100,
        crossAxisCount: 1,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        textDirection: TextDirection.ltr,
        activeHeight: 60,
        items: const [
          MasonryLayoutItem(id: 2, height: 100),
          MasonryLayoutItem(id: 3, height: 40),
        ],
      );

      expect(slots.map((slot) => slot.rect), const [
        Rect.fromLTWH(0, 0, 100, 60),
        Rect.fromLTWH(0, 108, 100, 60),
        Rect.fromLTWH(0, 156, 100, 60),
      ]);
    });

    test('mixed-height insertion slots use prefix shortest columns', () {
      final slots = MasonryLayoutEngine.computeInsertionSlots(
        width: 208,
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        textDirection: TextDirection.ltr,
        activeHeight: 60,
        items: const [
          MasonryLayoutItem(id: 2, height: 100),
          MasonryLayoutItem(id: 3, height: 40),
          MasonryLayoutItem(id: 4, height: 40),
        ],
      );

      expect(slots[0].rect, const Rect.fromLTWH(0, 0, 100, 60));
      expect(slots[1].rect, const Rect.fromLTWH(108, 0, 100, 60));
      expect(slots[2].rect, const Rect.fromLTWH(108, 48, 100, 60));
      expect(slots[3].rect, const Rect.fromLTWH(108, 96, 100, 60));
    });

    test('insertion slots mirror in RTL', () {
      final slots = MasonryLayoutEngine.computeInsertionSlots(
        width: 208,
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        textDirection: TextDirection.rtl,
        activeHeight: 60,
        items: const [MasonryLayoutItem(id: 2, height: 100)],
      );

      expect(slots[0].rect.left, 108);
      expect(slots[1].rect.left, 0);
    });

    test('slots stay stable when only the active preview index changes', () {
      const items = [
        MasonryLayoutItem(id: 1, height: 180),
        MasonryLayoutItem(id: 2, height: 60),
        MasonryLayoutItem(id: 3, height: 80),
        MasonryLayoutItem(id: 4, height: 100),
      ];

      List<Rect> slotsFor(List<MasonryLayoutItem> sequence) {
        return MasonryLayoutEngine.computeInsertionSlots(
          width: 208,
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          textDirection: TextDirection.ltr,
          activeHeight: 180,
          items: sequence.where((item) => item.id != 1),
        ).map((slot) => slot.rect).toList();
      }

      expect(
        slotsFor(items),
        slotsFor([items[1], items[2], items[0], items[3]]),
      );
    });

    test('nearest slot requires a twelve-pixel distance advantage', () {
      const slots = [
        MasonryInsertionSlot(
          insertionIndex: 0,
          rect: Rect.fromLTWH(0, 0, 100, 60),
        ),
        MasonryInsertionSlot(
          insertionIndex: 1,
          rect: Rect.fromLTWH(0, 68, 100, 60),
        ),
      ];

      MasonryInsertionSlot? resolve(double centerY) {
        return MasonryLayoutEngine.nearestInsertionSlot(
          slots: slots,
          draggedRect: Rect.fromCenter(
            center: Offset(50, centerY),
            width: 100,
            height: 60,
          ),
          previousInsertionIndex: 0,
        );
      }

      expect(resolve(69)?.insertionIndex, 0);
      expect(resolve(71)?.insertionIndex, 1);
    });
  });

  group('NoteReorderController', () {
    test('reorders optimistically and restores the original sequence', () {
      final controller = NoteReorderController()
        ..begin(ids: [1, 2, 3, 4], draggedId: 1);

      expect(controller.hover(targetId: 3, placeAfter: true), isTrue);
      expect(controller.previewIds, [2, 3, 1, 4]);
      expect(controller.changed, isTrue);
      expect(controller.cancel(), [1, 2, 3, 4]);
      expect(controller.active, isFalse);
    });

    test('accepts a stable insertion index without repeated movement', () {
      final controller = NoteReorderController()
        ..begin(ids: [1, 2, 3, 4], draggedId: 1);
      const resolution = MasonryDropResolution(
        insertionIndex: 2,
        targetId: 3,
        placeAfter: true,
        slotRect: Rect.fromLTWH(0, 0, 100, 100),
      );

      expect(controller.accept(resolution), isTrue);
      expect(controller.previewIds, [2, 3, 1, 4]);
      expect(controller.currentInsertionIndex, 2);
      expect(controller.accept(resolution), isFalse);
      expect(controller.previewIds, [2, 3, 1, 4]);
    });

    test('auto-scroll candidates only move with the scroll direction', () {
      bool allows(int candidate, double velocity) {
        return NoteReorderController.allowsInsertionDuringAutoScroll(
          currentInsertionIndex: 3,
          candidateInsertionIndex: candidate,
          scrollVelocity: velocity,
        );
      }

      expect(allows(4, 200), isTrue);
      expect(allows(2, 200), isFalse);
      expect(allows(2, -200), isTrue);
      expect(allows(4, -200), isFalse);
      expect(allows(2, 0), isTrue);
    });
  });

  test('note sections preserve the order inside pinned and other groups', () {
    final sections = NoteSectionPartition.from([
      1,
      2,
      3,
      4,
      5,
    ], isPinned: (id) => id.isOdd);

    expect(sections.pinned, [1, 3, 5]);
    expect(sections.others, [2, 4]);
    expect(sections.hasBoth, isTrue);
  });
}
