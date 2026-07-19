import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structural keys disambiguate legacy integer hash collisions', () {
    final collision = _findLegacyHashCollision();
    final first = _stroke(collision.$1);
    final second = _stroke(collision.$2);
    expect(
      Object.hash(first.points, first.size, first.tool),
      Object.hash(second.points, second.size, second.tool),
    );

    final cache = SketchStrokeOutlineCache();
    final firstOutline = <Offset>[const Offset(1, 1)];
    final secondOutline = <Offset>[const Offset(2, 2)];

    expect(cache.getOrCreate(first, () => firstOutline), same(firstOutline));
    expect(cache.getOrCreate(second, () => secondOutline), same(secondOutline));
    expect(cache.length, 2);
  });

  test('cache reuses exact keys and keeps insertion-ordered size bound', () {
    final cache = SketchStrokeOutlineCache(maxEntries: 2);
    final first = _stroke('first');
    final second = _stroke('second');
    final third = _stroke('third');
    var firstBuilds = 0;

    List<Offset> buildFirst() {
      firstBuilds++;
      return <Offset>[Offset(firstBuilds.toDouble(), 0)];
    }

    final firstOutline = cache.getOrCreate(first, buildFirst);
    expect(cache.getOrCreate(first, buildFirst), same(firstOutline));
    expect(firstBuilds, 1);

    cache.getOrCreate(second, () => <Offset>[const Offset(2, 0)]);
    cache.getOrCreate(third, () => <Offset>[const Offset(3, 0)]);
    expect(cache.length, 2);

    expect(cache.getOrCreate(first, buildFirst), isNot(same(firstOutline)));
    expect(firstBuilds, 2);
    expect(cache.length, 2);
  });

  test('points, size, and tool each participate in the cache key', () {
    final cache = SketchStrokeOutlineCache();
    final strokes = <SketchStroke>[
      _stroke('same'),
      _stroke('different'),
      _stroke('same', size: 5),
      _stroke('same', tool: SketchTool.brush),
    ];

    for (var index = 0; index < strokes.length; index++) {
      cache.getOrCreate(
        strokes[index],
        () => <Offset>[Offset(index.toDouble(), 0)],
      );
    }

    expect(cache.length, strokes.length);
  });
}

(String, String) _findLegacyHashCollision() {
  final seen = <int, String>{};
  for (var index = 0; index < 200000; index++) {
    final points = 'points-$index';
    final hash = Object.hash(points, 4.0, SketchTool.pen);
    final previous = seen[hash];
    if (previous != null && previous != points) return (previous, points);
    seen[hash] = points;
  }
  throw StateError('Could not find a legacy stroke-cache hash collision');
}

SketchStroke _stroke(
  String points, {
  double size = 4,
  SketchTool tool = SketchTool.pen,
}) => SketchStroke(points: points, color: Colors.black, size: size, tool: tool);
