import 'dart:convert';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

enum SketchTool { pen, eraser }

/// Page pattern types for sketch backgrounds
/// These are rendered dynamically and not saved as part of the sketch image
enum PagePattern {
  blank,
  singleLine,
  doubleLine,
  grid,
  dotGrid;

  String get displayName => switch (this) {
    PagePattern.blank => 'Blank',
    PagePattern.singleLine => 'Lined',
    PagePattern.doubleLine => 'Double Lined',
    PagePattern.grid => 'Grid',
    PagePattern.dotGrid => 'Dot Grid',
  };

  IconData get icon => switch (this) {
    PagePattern.blank => Icons.note_outlined,
    PagePattern.singleLine => Icons.horizontal_rule,
    PagePattern.doubleLine => Icons.dehaze,
    PagePattern.grid => Icons.grid_4x4,
    PagePattern.dotGrid => Icons.grid_on_outlined,
  };
}

class SketchStroke {
  String points;
  final Color color;
  final double size;
  final SketchTool tool;

  SketchStroke({
    required this.points,
    required this.color,
    required this.size,
    this.tool = SketchTool.pen,
  });

  static List<PointVector> parsePoints(String pointsStr) {
    final List<PointVector> vectorPoints = [];
    if (pointsStr.isEmpty) return vectorPoints;

    // Use StringBuffer for better performance with large point sets
    final buffer = StringBuffer();
    final vector = <double>[0, 0, 0];
    int needle = 0;

    for (var i = 0; i < pointsStr.length; ++i) {
      final char = pointsStr[i];

      if (char == ';') {
        vector[needle] = double.parse(buffer.toString());
        vectorPoints.add(PointVector(vector[0], vector[1], vector[2]));
        needle = 0;
        buffer.clear();
        vector[0] = 0;
        vector[1] = 0;
        vector[2] = 0;
        continue;
      }

      if (char == ',') {
        vector[needle] = double.parse(buffer.toString());
        buffer.clear();
        ++needle;
        continue;
      }

      buffer.write(char);
    }
    return vectorPoints;
  }

  factory SketchStroke.parse(String data) {
    final List<String> meta = [
      '', // tool
      '', // color
      '', // size
    ];
    int i = 0;
    int needle = 0;

    for (; i < data.length; ++i) {
      var char = data[i];

      if (char == ':') {
        if (++needle == meta.length) {
          break;
        }
        continue;
      }

      meta[needle] += char;
    }
    return SketchStroke(
      points: data.substring(i + 1),
      tool: SketchTool.values.firstWhere(
        (e) => e.name == meta[0],
        orElse: () => SketchTool.pen,
      ),
      color: Color(int.parse(meta[1])),
      size: double.parse(meta[2]),
    );
  }

  @override
  String toString() {
    return '${tool.name}:${color.toARGB32()}:${size.toStringAsFixed(1)}:$points';
  }
}

class SketchData {
  List<SketchStroke> strokes;
  double aspectRatio;
  Color backgroundColor;
  String? previewImage;
  String? backgroundImage;
  PagePattern pagePattern;

  SketchData({
    this.previewImage,
    this.backgroundImage,
    this.aspectRatio = 1.0,
    this.strokes = const [],
    this.backgroundColor = Colors.white,
    this.pagePattern = PagePattern.blank,
  });

  Map<String, dynamic> toJson() => {
    'strokes': strokes.map((s) => s.toString()).toList(),
    'bgColor': backgroundColor.toARGB32(),
    'previewImage': previewImage,
    'backgroundImage': backgroundImage,
    'aspectRatio': aspectRatio,
    'pagePattern': pagePattern.name,
  };

  factory SketchData.fromJson(Map<String, dynamic> json) {
    try {
      return SketchData(
        strokes: (json['strokes'] as List)
            .map((e) => SketchStroke.parse(e))
            .toList(),
        backgroundImage: json['backgroundImage'] as String?,
        backgroundColor: Color(json['bgColor'] as int? ?? 0xFFFFFFFF),
        previewImage: json['previewImage'] as String?,
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble() ?? 1.0,
        pagePattern: PagePattern.values.firstWhere(
          (e) => e.name == json['pagePattern'],
          orElse: () => PagePattern.blank,
        ),
      );
    } catch (e) {
      AppLogger.error('Error parsing sketch data', e);
      return SketchData();
    }
  }

  String toRawJson() => json.encode(toJson());

  factory SketchData.fromRawJson(String str) =>
      SketchData.fromJson(json.decode(str));
}
