import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

@immutable
class MasonryLayoutItem {
  const MasonryLayoutItem({required this.id, required this.height});

  final int id;
  final double height;
}

@immutable
class MasonryLayoutSnapshot {
  const MasonryLayoutSnapshot({required this.rects, required this.extent});

  final Map<int, Rect> rects;
  final double extent;
}

@immutable
class MasonryInsertionSlot {
  const MasonryInsertionSlot({
    required this.insertionIndex,
    required this.rect,
  });

  final int insertionIndex;
  final Rect rect;
}

/// Deterministic shortest-column geometry shared by rendering and unit tests.
class MasonryLayoutEngine {
  const MasonryLayoutEngine._();

  static double _itemWidth({
    required double width,
    required int crossAxisCount,
    required double crossAxisSpacing,
  }) {
    final usableWidth = math.max(
      0.0,
      width - crossAxisSpacing * (crossAxisCount - 1),
    );
    return usableWidth / crossAxisCount;
  }

  static int _shortestColumn(List<double> columnExtents) {
    var logicalColumn = 0;
    for (var column = 1; column < columnExtents.length; column++) {
      if (columnExtents[column] < columnExtents[logicalColumn]) {
        logicalColumn = column;
      }
    }
    return logicalColumn;
  }

  static Rect _rectFor({
    required int logicalColumn,
    required List<double> columnExtents,
    required int crossAxisCount,
    required double itemWidth,
    required double crossAxisSpacing,
    required double height,
    required TextDirection textDirection,
  }) {
    final physicalColumn = textDirection == TextDirection.rtl
        ? crossAxisCount - logicalColumn - 1
        : logicalColumn;
    return Rect.fromLTWH(
      physicalColumn * (itemWidth + crossAxisSpacing),
      columnExtents[logicalColumn],
      itemWidth,
      height,
    );
  }

  static MasonryLayoutSnapshot compute({
    required double width,
    required int crossAxisCount,
    required double mainAxisSpacing,
    required double crossAxisSpacing,
    required TextDirection textDirection,
    required Iterable<MasonryLayoutItem> items,
  }) {
    assert(crossAxisCount > 0);
    assert(width >= 0);
    assert(mainAxisSpacing >= 0);
    assert(crossAxisSpacing >= 0);

    final itemWidth = _itemWidth(
      width: width,
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: crossAxisSpacing,
    );
    final columnExtents = List<double>.filled(crossAxisCount, 0);
    final rects = <int, Rect>{};

    for (final item in items) {
      final logicalColumn = _shortestColumn(columnExtents);
      final rect = _rectFor(
        logicalColumn: logicalColumn,
        columnExtents: columnExtents,
        crossAxisCount: crossAxisCount,
        itemWidth: itemWidth,
        crossAxisSpacing: crossAxisSpacing,
        height: item.height,
        textDirection: textDirection,
      );
      rects[item.id] = rect;
      columnExtents[logicalColumn] = rect.bottom + mainAxisSpacing;
    }

    final populatedExtent = columnExtents.isEmpty
        ? 0.0
        : columnExtents.reduce(math.max);
    return MasonryLayoutSnapshot(
      rects: Map.unmodifiable(rects),
      extent: math.max(0, populatedExtent - mainAxisSpacing),
    );
  }

  /// Computes every position at which [activeHeight] can enter [items].
  ///
  /// An insertion position only depends on the prefix before it, so all slots
  /// can be generated in one pass without repeatedly simulating full layouts.
  static List<MasonryInsertionSlot> computeInsertionSlots({
    required double width,
    required int crossAxisCount,
    required double mainAxisSpacing,
    required double crossAxisSpacing,
    required TextDirection textDirection,
    required double activeHeight,
    required Iterable<MasonryLayoutItem> items,
  }) {
    assert(crossAxisCount > 0);
    assert(width >= 0);
    assert(mainAxisSpacing >= 0);
    assert(crossAxisSpacing >= 0);
    assert(activeHeight >= 0);

    final sequence = List<MasonryLayoutItem>.of(items);
    final itemWidth = _itemWidth(
      width: width,
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: crossAxisSpacing,
    );
    final columnExtents = List<double>.filled(crossAxisCount, 0);
    final slots = <MasonryInsertionSlot>[];

    for (
      var insertionIndex = 0;
      insertionIndex <= sequence.length;
      insertionIndex++
    ) {
      final activeColumn = _shortestColumn(columnExtents);
      slots.add(
        MasonryInsertionSlot(
          insertionIndex: insertionIndex,
          rect: _rectFor(
            logicalColumn: activeColumn,
            columnExtents: columnExtents,
            crossAxisCount: crossAxisCount,
            itemWidth: itemWidth,
            crossAxisSpacing: crossAxisSpacing,
            height: activeHeight,
            textDirection: textDirection,
          ),
        ),
      );
      if (insertionIndex == sequence.length) break;

      final item = sequence[insertionIndex];
      final itemColumn = _shortestColumn(columnExtents);
      final itemRect = _rectFor(
        logicalColumn: itemColumn,
        columnExtents: columnExtents,
        crossAxisCount: crossAxisCount,
        itemWidth: itemWidth,
        crossAxisSpacing: crossAxisSpacing,
        height: item.height,
        textDirection: textDirection,
      );
      columnExtents[itemColumn] = itemRect.bottom + mainAxisSpacing;
    }

    return List.unmodifiable(slots);
  }

  static MasonryInsertionSlot? nearestInsertionSlot({
    required Iterable<MasonryInsertionSlot> slots,
    required Rect draggedRect,
    int? previousInsertionIndex,
    double switchAdvantage = 12,
  }) {
    final candidates = slots is List<MasonryInsertionSlot>
        ? slots
        : List<MasonryInsertionSlot>.of(slots);
    if (candidates.isEmpty) return null;

    var selectedSlot = candidates.first;
    var selectedDistance =
        (selectedSlot.rect.center - draggedRect.center).distance;
    for (final slot in candidates.skip(1)) {
      final distance = (slot.rect.center - draggedRect.center).distance;
      if (distance < selectedDistance) {
        selectedSlot = slot;
        selectedDistance = distance;
      }
    }

    if (previousInsertionIndex == null ||
        previousInsertionIndex == selectedSlot.insertionIndex) {
      return selectedSlot;
    }

    MasonryInsertionSlot? previousSlot;
    for (final slot in candidates) {
      if (slot.insertionIndex == previousInsertionIndex) {
        previousSlot = slot;
        break;
      }
    }
    if (previousSlot == null) return selectedSlot;

    final previousDistance =
        (previousSlot.rect.center - draggedRect.center).distance;
    return selectedDistance + switchAdvantage >= previousDistance
        ? previousSlot
        : selectedSlot;
  }
}

@immutable
class NoteSectionPartition<T> {
  NoteSectionPartition._({
    required Iterable<T> pinned,
    required Iterable<T> others,
  }) : pinned = List.unmodifiable(pinned),
       others = List.unmodifiable(others);

  factory NoteSectionPartition.from(
    Iterable<T> items, {
    required bool Function(T item) isPinned,
  }) {
    final pinned = <T>[];
    final others = <T>[];
    for (final item in items) {
      (isPinned(item) ? pinned : others).add(item);
    }
    return NoteSectionPartition._(pinned: pinned, others: others);
  }

  final List<T> pinned;
  final List<T> others;

  bool get hasBoth => pinned.isNotEmpty && others.isNotEmpty;
}

@immutable
class MasonryDropResolution {
  const MasonryDropResolution({
    required this.insertionIndex,
    required this.targetId,
    required this.placeAfter,
    required this.slotRect,
  });

  /// Index in the section after the dragged note has been removed.
  final int insertionIndex;
  final int targetId;
  final bool placeAfter;
  final Rect slotRect;
}

/// Read-only bridge used by the gesture coordinator to query live card bounds.
class MasonryLayoutController {
  _RenderAnimatedMasonryLayout? _renderObject;

  Rect? get globalBounds => _renderObject?.globalBounds;

  Rect? globalRectFor(int id) => _renderObject?.globalRectFor(id);

  bool containsGlobalPosition(Offset position) =>
      _renderObject?.containsGlobalPosition(position) ?? false;

  void updateDragPosition(Offset? position) {
    _renderObject?.dragGlobalPosition = position;
  }

  MasonryDropResolution? resolveInsertion({
    required Offset globalPosition,
    required int excludingId,
    MasonryDropResolution? previousResolution,
  }) => _renderObject?.resolveInsertion(
    globalPosition: globalPosition,
    excludingId: excludingId,
    previousResolution: previousResolution,
  );

  @visibleForTesting
  Rect? targetGlobalRectFor(int id) => _renderObject?.targetGlobalRectFor(id);

  @visibleForTesting
  int get debugAnimationRestartCount =>
      _renderObject?.debugAnimationRestartCount ?? 0;

  void _attach(_RenderAnimatedMasonryLayout renderObject) {
    _renderObject = renderObject;
  }

  void _detach(_RenderAnimatedMasonryLayout renderObject) {
    if (identical(_renderObject, renderObject)) _renderObject = null;
  }
}

/// Owns one section's optimistic ID sequence without touching persistence.
class NoteReorderController {
  List<int> _originalIds = const [];
  List<int> _previewIds = const [];

  int? draggedId;
  int? targetId;
  bool? placeAfter;
  int? currentInsertionIndex;
  MasonryDropResolution? dropResolution;

  bool get active => draggedId != null;
  List<int> get previewIds => List.unmodifiable(_previewIds);
  List<int> get originalIds => List.unmodifiable(_originalIds);
  bool get changed => !listEquals(_originalIds, _previewIds);

  void begin({required Iterable<int> ids, required int draggedId}) {
    final sequence = List<int>.of(ids);
    if (!sequence.contains(draggedId)) {
      throw ArgumentError.value(draggedId, 'draggedId', 'Missing from section');
    }
    _originalIds = sequence;
    _previewIds = List.of(sequence);
    this.draggedId = draggedId;
    targetId = null;
    placeAfter = null;
    currentInsertionIndex = sequence.indexOf(draggedId);
    dropResolution = null;
  }

  bool hover({required int targetId, required bool placeAfter}) {
    final dragged = draggedId;
    if (dragged == null || dragged == targetId) return false;
    final draggedIndex = _previewIds.indexOf(dragged);
    final targetIndexBeforeRemoval = _previewIds.indexOf(targetId);
    if (draggedIndex < 0 || targetIndexBeforeRemoval < 0) return false;

    final withoutDragged = List<int>.of(_previewIds)..removeAt(draggedIndex);
    final targetIndex = withoutDragged.indexOf(targetId);
    final insertionIndex = targetIndex + (placeAfter ? 1 : 0);
    final next = List<int>.of(withoutDragged)..insert(insertionIndex, dragged);
    this.targetId = targetId;
    this.placeAfter = placeAfter;
    currentInsertionIndex = insertionIndex;
    if (listEquals(next, _previewIds)) return false;
    _previewIds = next;
    return true;
  }

  bool accept(MasonryDropResolution resolution) {
    final dragged = draggedId;
    if (dragged == null) return false;
    final draggedIndex = _previewIds.indexOf(dragged);
    if (draggedIndex < 0) return false;

    final next = List<int>.of(_previewIds)..removeAt(draggedIndex);
    final insertionIndex = resolution.insertionIndex.clamp(0, next.length);
    next.insert(insertionIndex, dragged);

    targetId = resolution.targetId;
    placeAfter = resolution.placeAfter;
    currentInsertionIndex = insertionIndex;
    dropResolution = resolution;
    if (listEquals(next, _previewIds)) return false;
    _previewIds = next;
    return true;
  }

  List<int> cancel() {
    final result = List<int>.of(_originalIds);
    clear();
    return result;
  }

  void clear() {
    _originalIds = const [];
    _previewIds = const [];
    draggedId = null;
    targetId = null;
    placeAfter = null;
    currentInsertionIndex = null;
    dropResolution = null;
  }

  static bool allowsInsertionDuringAutoScroll({
    required int? currentInsertionIndex,
    required int candidateInsertionIndex,
    required double scrollVelocity,
  }) {
    if (currentInsertionIndex == null || scrollVelocity == 0) return true;
    if (scrollVelocity > 0) {
      return candidateInsertionIndex >= currentInsertionIndex;
    }
    return candidateInsertionIndex <= currentInsertionIndex;
  }
}

class AnimatedMasonryReorderLayout extends StatefulWidget {
  const AnimatedMasonryReorderLayout({
    super.key,
    required this.controller,
    required this.crossAxisCount,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required this.children,
    this.activeId,
    this.dragGlobalPosition,
    this.dragAnchor = Offset.zero,
    this.placeholderColor = const Color(0x14000000),
    this.animationDuration = const Duration(milliseconds: 180),
    this.animationCurve = Curves.easeOutCubic,
  });

  final MasonryLayoutController controller;
  final int crossAxisCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final List<Widget> children;
  final int? activeId;
  final Offset? dragGlobalPosition;
  final Offset dragAnchor;
  final Color placeholderColor;
  final Duration animationDuration;
  final Curve animationCurve;

  @override
  State<AnimatedMasonryReorderLayout> createState() =>
      _AnimatedMasonryReorderLayoutState();
}

class _AnimatedMasonryReorderLayoutState
    extends State<AnimatedMasonryReorderLayout>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final duration = disableAnimations
        ? Duration.zero
        : widget.animationDuration;
    final layout = _AnimatedMasonryRenderWidget(
      controller: widget.controller,
      vsync: this,
      crossAxisCount: widget.crossAxisCount,
      mainAxisSpacing: widget.mainAxisSpacing,
      crossAxisSpacing: widget.crossAxisSpacing,
      textDirection: Directionality.of(context),
      activeId: widget.activeId,
      dragGlobalPosition: widget.dragGlobalPosition,
      dragAnchor: widget.dragAnchor,
      placeholderColor: widget.placeholderColor,
      animationDuration: duration,
      animationCurve: widget.animationCurve,
      children: widget.children,
    );
    if (disableAnimations) return layout;
    return AnimatedSize(
      duration: duration,
      curve: widget.animationCurve,
      clipBehavior: Clip.none,
      child: layout,
    );
  }
}

class MasonryReorderItem extends ParentDataWidget<_MasonryParentData> {
  const MasonryReorderItem({super.key, required this.id, required super.child});

  final int id;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as _MasonryParentData;
    if (parentData.id == id) return;
    parentData.id = id;
    final parent = renderObject.parent;
    if (parent is RenderObject) parent.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => AnimatedMasonryReorderLayout;
}

class _AnimatedMasonryRenderWidget extends MultiChildRenderObjectWidget {
  const _AnimatedMasonryRenderWidget({
    required this.controller,
    required this.vsync,
    required this.crossAxisCount,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required this.textDirection,
    required this.activeId,
    required this.dragGlobalPosition,
    required this.dragAnchor,
    required this.placeholderColor,
    required this.animationDuration,
    required this.animationCurve,
    required super.children,
  });

  final MasonryLayoutController controller;
  final TickerProvider vsync;
  final int crossAxisCount;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final TextDirection textDirection;
  final int? activeId;
  final Offset? dragGlobalPosition;
  final Offset dragAnchor;
  final Color placeholderColor;
  final Duration animationDuration;
  final Curve animationCurve;

  @override
  _RenderAnimatedMasonryLayout createRenderObject(BuildContext context) {
    return _RenderAnimatedMasonryLayout(
      controller: controller,
      vsync: vsync,
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      textDirection: textDirection,
      activeId: activeId,
      dragGlobalPosition: dragGlobalPosition,
      dragAnchor: dragAnchor,
      placeholderColor: placeholderColor,
      animationDuration: animationDuration,
      animationCurve: animationCurve,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnimatedMasonryLayout renderObject,
  ) {
    renderObject
      ..layoutController = controller
      ..vsync = vsync
      ..crossAxisCount = crossAxisCount
      ..mainAxisSpacing = mainAxisSpacing
      ..crossAxisSpacing = crossAxisSpacing
      ..textDirection = textDirection
      ..activeId = activeId
      ..dragGlobalPosition = dragGlobalPosition
      ..dragAnchor = dragAnchor
      ..placeholderColor = placeholderColor
      ..animationDuration = animationDuration
      ..animationCurve = animationCurve;
  }
}

class _MasonryParentData extends ContainerBoxParentData<RenderBox> {
  int? id;
  Offset fromOffset = Offset.zero;
  Offset targetOffset = Offset.zero;
  bool hasPosition = false;
}

class _RenderAnimatedMasonryLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MasonryParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MasonryParentData> {
  _RenderAnimatedMasonryLayout({
    required MasonryLayoutController controller,
    required TickerProvider vsync,
    required this._crossAxisCount,
    required this._mainAxisSpacing,
    required this._crossAxisSpacing,
    required this._textDirection,
    required this._activeId,
    required this._dragGlobalPosition,
    required this._dragAnchor,
    required this._placeholderColor,
    required Duration animationDuration,
    required this._animationCurve,
  }) : _layoutController = controller,
       _vsync = vsync,
       _animationDuration = animationDuration {
    _positionController = AnimationController(
      vsync: vsync,
      duration: animationDuration,
      value: 1,
    )..addListener(_handleAnimationTick);
    _layoutController._attach(this);
  }

  late final AnimationController _positionController;
  MasonryLayoutController _layoutController;
  TickerProvider _vsync;
  int _crossAxisCount;
  double _mainAxisSpacing;
  double _crossAxisSpacing;
  TextDirection _textDirection;
  int? _activeId;
  Offset? _dragGlobalPosition;
  Offset _dragAnchor;
  Color _placeholderColor;
  Duration _animationDuration;
  Curve _animationCurve;
  double? _dragExtentFloor;
  List<MasonryInsertionSlot> _insertionSlots = const [];
  List<int> _nonActiveIds = const [];

  @visibleForTesting
  int debugAnimationRestartCount = 0;

  set layoutController(MasonryLayoutController value) {
    if (identical(value, _layoutController)) return;
    _layoutController._detach(this);
    _layoutController = value;
    _layoutController._attach(this);
  }

  set vsync(TickerProvider value) {
    if (identical(value, _vsync)) return;
    _vsync = value;
    _positionController.resync(value);
  }

  set crossAxisCount(int value) {
    if (value == _crossAxisCount) return;
    _crossAxisCount = value;
    markNeedsLayout();
  }

  set mainAxisSpacing(double value) {
    if (value == _mainAxisSpacing) return;
    _mainAxisSpacing = value;
    markNeedsLayout();
  }

  set crossAxisSpacing(double value) {
    if (value == _crossAxisSpacing) return;
    _crossAxisSpacing = value;
    markNeedsLayout();
  }

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  set activeId(int? value) {
    if (value == _activeId) return;
    if (_activeId == null && value != null && hasSize) {
      _dragExtentFloor = size.height;
    } else if (value == null) {
      _dragExtentFloor = null;
    }
    _activeId = value;
    markNeedsLayout();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  set dragGlobalPosition(Offset? value) {
    if (value == _dragGlobalPosition) return;
    _dragGlobalPosition = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  set dragAnchor(Offset value) {
    if (value == _dragAnchor) return;
    _dragAnchor = value;
    markNeedsPaint();
  }

  set placeholderColor(Color value) {
    if (value == _placeholderColor) return;
    _placeholderColor = value;
    markNeedsPaint();
  }

  set animationDuration(Duration value) {
    if (value == _animationDuration) return;
    _animationDuration = value;
    _positionController.duration = value;
  }

  set animationCurve(Curve value) {
    if (value == _animationCurve) return;
    _animationCurve = value;
    markNeedsPaint();
  }

  void _handleAnimationTick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MasonryParentData) {
      child.parentData = _MasonryParentData();
    }
  }

  double get _animationValue {
    if (!_positionController.isAnimating) return 1;
    return _animationCurve.transform(_positionController.value);
  }

  Offset _visualOffset(_MasonryParentData parentData) {
    if (!parentData.hasPosition) return parentData.targetOffset;
    return Offset.lerp(
      parentData.fromOffset,
      parentData.targetOffset,
      _animationValue,
    )!;
  }

  RenderBox? _childForId(int? id) {
    if (id == null) return null;
    RenderBox? child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _MasonryParentData;
      if (parentData.id == id) return child;
      child = parentData.nextSibling;
    }
    return null;
  }

  Offset _paintOffsetFor(RenderBox child) {
    final parentData = child.parentData! as _MasonryParentData;
    if (parentData.id == _activeId && _dragGlobalPosition != null) {
      return globalToLocal(_dragGlobalPosition!) - _dragAnchor;
    }
    return _visualOffset(parentData);
  }

  @override
  void performLayout() {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    final columnCount = math.max(1, _crossAxisCount);
    final itemWidth = math.max(
      0.0,
      (width - _crossAxisSpacing * (columnCount - 1)) / columnCount,
    );
    final items = <MasonryLayoutItem>[];
    final children = <RenderBox>[];

    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(
        BoxConstraints.tightFor(width: itemWidth),
        parentUsesSize: true,
      );
      final parentData = child.parentData! as _MasonryParentData;
      final id = parentData.id;
      if (id != null) {
        items.add(MasonryLayoutItem(id: id, height: child.size.height));
        children.add(child);
      }
      child = parentData.nextSibling;
    }

    final geometry = MasonryLayoutEngine.compute(
      width: width,
      crossAxisCount: columnCount,
      mainAxisSpacing: _mainAxisSpacing,
      crossAxisSpacing: _crossAxisSpacing,
      textDirection: _textDirection,
      items: items,
    );

    MasonryLayoutItem? activeItem;
    for (final item in items) {
      if (item.id == _activeId) {
        activeItem = item;
        break;
      }
    }
    if (activeItem == null) {
      _insertionSlots = const [];
      _nonActiveIds = const [];
    } else {
      final nonActiveItems = [
        for (final item in items)
          if (item.id != _activeId) item,
      ];
      _nonActiveIds = List.unmodifiable(nonActiveItems.map((item) => item.id));
      _insertionSlots = MasonryLayoutEngine.computeInsertionSlots(
        width: width,
        crossAxisCount: columnCount,
        mainAxisSpacing: _mainAxisSpacing,
        crossAxisSpacing: _crossAxisSpacing,
        textDirection: _textDirection,
        activeHeight: activeItem.height,
        items: nonActiveItems,
      );
    }

    var targetsChanged = false;
    final oldVisualOffsets = <RenderBox, Offset>{};
    for (final renderChild in children) {
      final parentData = renderChild.parentData! as _MasonryParentData;
      oldVisualOffsets[renderChild] = _visualOffset(parentData);
      final target = geometry.rects[parentData.id]!.topLeft;
      if (!parentData.hasPosition ||
          (parentData.targetOffset - target).distanceSquared > 0.01) {
        targetsChanged = true;
      }
    }

    for (final renderChild in children) {
      final parentData = renderChild.parentData! as _MasonryParentData;
      final target = geometry.rects[parentData.id]!.topLeft;
      parentData
        ..fromOffset = parentData.hasPosition
            ? oldVisualOffsets[renderChild]!
            : target
        ..targetOffset = target
        ..offset = target
        ..hasPosition = true;
    }

    var reportedExtent = geometry.extent;
    if (_activeId != null) {
      _dragExtentFloor = math.max(_dragExtentFloor ?? 0, geometry.extent);
      reportedExtent = _dragExtentFloor!;
    }
    size = constraints.constrain(Size(width, reportedExtent));
    if (targetsChanged) {
      if (_animationDuration == Duration.zero) {
        _positionController.stop();
        _positionController.value = 1;
      } else {
        debugAnimationRestartCount++;
        _positionController.forward(from: 0);
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final activeChild = _childForId(_activeId);
    if (activeChild != null) {
      final parentData = activeChild.parentData! as _MasonryParentData;
      final slotRect = (_visualOffset(parentData) + offset) & activeChild.size;
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(slotRect, const Radius.circular(12)),
        Paint()..color = _placeholderColor,
      );
    }

    RenderBox? child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _MasonryParentData;
      if (!identical(child, activeChild)) {
        context.paintChild(child, offset + _paintOffsetFor(child));
      }
      child = parentData.nextSibling;
    }
    if (activeChild != null) {
      context.paintChild(activeChild, offset + _paintOffsetFor(activeChild));
    }
  }

  bool _hitTestChild(
    BoxHitTestResult result,
    RenderBox child,
    Offset position,
  ) {
    return result.addWithPaintOffset(
      offset: _paintOffsetFor(child),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final activeChild = _childForId(_activeId);
    if (activeChild != null && _hitTestChild(result, activeChild, position)) {
      return true;
    }

    RenderBox? child = lastChild;
    while (child != null) {
      final parentData = child.parentData! as _MasonryParentData;
      if (!identical(child, activeChild) &&
          _hitTestChild(result, child, position)) {
        return true;
      }
      child = parentData.previousSibling;
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(
      _paintOffsetFor(child).dx,
      _paintOffsetFor(child).dy,
      0,
      1,
    );
  }

  Rect? globalRectFor(int id) {
    final child = _childForId(id);
    if (child == null || !attached) return null;
    final localRect = _paintOffsetFor(child) & child.size;
    return MatrixUtils.transformRect(getTransformTo(null), localRect);
  }

  Rect? targetGlobalRectFor(int id) {
    final child = _childForId(id);
    if (child == null || !attached) return null;
    final parentData = child.parentData! as _MasonryParentData;
    final localRect = parentData.targetOffset & child.size;
    return MatrixUtils.transformRect(getTransformTo(null), localRect);
  }

  bool containsGlobalPosition(Offset position) {
    return globalBounds?.contains(position) ?? false;
  }

  Rect? get globalBounds {
    if (!attached || !hasSize) return null;
    return MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);
  }

  MasonryDropResolution? resolveInsertion({
    required Offset globalPosition,
    required int excludingId,
    MasonryDropResolution? previousResolution,
  }) {
    if (!containsGlobalPosition(globalPosition)) return null;
    final localPointer = globalToLocal(globalPosition);
    final activeChild = _childForId(excludingId);
    if (activeChild == null ||
        _insertionSlots.isEmpty ||
        _nonActiveIds.isEmpty) {
      return null;
    }

    final draggedRect = (localPointer - _dragAnchor) & activeChild.size;
    final selectedSlot = MasonryLayoutEngine.nearestInsertionSlot(
      slots: _insertionSlots,
      draggedRect: draggedRect,
      previousInsertionIndex: previousResolution?.insertionIndex,
    )!;

    final insertionIndex = selectedSlot.insertionIndex;
    final placeAfter = insertionIndex > 0;
    final targetId = placeAfter
        ? _nonActiveIds[insertionIndex - 1]
        : _nonActiveIds.first;
    return MasonryDropResolution(
      insertionIndex: insertionIndex,
      targetId: targetId,
      placeAfter: placeAfter,
      slotRect: selectedSlot.rect,
    );
  }

  @override
  void dispose() {
    _layoutController._detach(this);
    _positionController
      ..removeListener(_handleAnimationTick)
      ..dispose();
    super.dispose();
  }
}
